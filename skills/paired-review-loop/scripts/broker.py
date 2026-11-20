#!/usr/bin/env python3
"""Opt-in tmux wake broker for a paired-review-loop session.

The mailbox files under <session>/members/ stay the source of truth.  This
process replaces the recurring watch.sh deadline with an immediate one-shot
tmux wake: when a mailbox changes it types a one-line pointer into the
recipient's registered pane, and when a send cannot be confirmed it keeps the
work pending with bounded retries instead of dropping it.

A wake is a pointer, never content: the message names the file to read.  A
wake is considered acknowledged only when the recipient's reply mailbox gets
a newer revision (a member's `out`, the thinker's next `in`), because typing
a message is not proof of reading.

Linux only: file changes are detected with inotify.  The broker never creates
panes, never restarts agents, and never touches a pane that is not registered
in the session's roster.tsv or session.env.

Run it through broker.sh, which owns the process lifecycle:

    scripts/broker.sh start --session /tmp/prl-demo
    scripts/broker.sh status --session /tmp/prl-demo
"""

from __future__ import annotations

import argparse
import ctypes
import ctypes.util
import hashlib
import json
import os
import select
import signal
import struct
import subprocess
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

# inotify is not in the Python standard library, so the two syscalls are
# bound through ctypes.  select() multiplexes the inotify fd with the loop's
# sleep; there is no hand-rolled event loop.
_libc = ctypes.CDLL(ctypes.util.find_library("c") or "libc.so.6", use_errno=True)
_libc.inotify_init1.argtypes = [ctypes.c_int]
_libc.inotify_init1.restype = ctypes.c_int
_libc.inotify_add_watch.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32]
_libc.inotify_add_watch.restype = ctypes.c_int

IN_CREATE = 0x00000100
IN_DELETE = 0x00000200
IN_MODIFY = 0x00000002
IN_MOVED_FROM = 0x00000400
IN_MOVED_TO = 0x00008000
IN_CLOSE_WRITE = 0x00000800
_WATCH_MASK = (
    IN_CREATE | IN_DELETE | IN_MODIFY | IN_MOVED_FROM | IN_MOVED_TO | IN_CLOSE_WRITE
)
# struct inotify_event: int wd; uint32_t mask, cookie, len; char name[].
_EVENT_HEADER = struct.Struct("<iIII")

# Mirrors PRL_SHELLS in scripts/lib.sh: a pane whose foreground command is one
# of these is a bare shell, and typing into it would run the wake as a command.
_SHELLS = {"bash", "zsh", "sh", "fish", "dash", "ksh", "tcsh", "csh"}

# A cursor this far right leaves the input box empty; further right means
# somebody (usually a placeholder that does not count) has typed.  Mirrors
# PRL_EMPTY_INPUT_COLUMNS in scripts/lib.sh.
_EMPTY_INPUT_MAX_COLUMN = 4

# Seconds between typing the pointer and pressing Enter, and between Enter and
# checking whether the pane reacted.  Mirrors PRL_SEND_DELAY / PRL_REACT_DELAY.
_SEND_DELAY_SECONDS = 0.3
_REACT_DELAY_SECONDS = 1.0
# Two captures this far apart tell a redrawing (working) pane from an idle one.
_BUSY_SAMPLE_SECONDS = 1.2

# inotify events are debounced this long before a scan, so a write that lands
# mid-scan is not lost.
_DEBOUNCE_SECONDS = 0.25
# Safety-net scan period in case an inotify event is missed (watched file
# replaced by rename, broker restarted mid-write).
_FALLBACK_SCAN_INTERVAL_SECONDS = 15.0

# A send that cannot be confirmed is retried with exponential backoff, up to
# this many attempts, after which the failure is reported to the counterpart
# and the work stays in the mailbox files.
_MAX_SEND_ATTEMPTS = 10
_RETRY_BASE_SECONDS = 2.0
_RETRY_CAP_SECONDS = 60.0
# A pane that is busy or has an occupied input line is deferred, not failed:
# it may be busy for longer than any retry budget, and the work is not lost.
# Deferrals back off to a cap so a long build does not hammer the pane.
_DEFERRAL_CAP_SECONDS = 30.0

# A delivered wake that is not acknowledged (reply mailbox not rewritten)
# within this long is re-nudged, up to MAX_RENUDGES times, after which the
# stall is reported to the counterpart.
_ACK_TIMEOUT_SECONDS = 600
_MAX_RENUDGES = 2

# A pane whose screen shows this marker has parked a codex /goal.  A plain
# wake cannot move it; the fix is 'roster.sh kick', which this broker does not
# perform.
_PARKED_GOAL_MARKER = "Goal stalled"

# Request files the broker honours, dropped in <session>/broker/requests/.
_REQUEST_PREFIX = "request-"

_MAILBOX_NAMES = ("in", "in-addendum", "out")


def _utc_timestamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def file_revision(path: Path) -> tuple[int, int, str] | None:
    """Return (mtime_ns, size, sha256) for a file, or None when absent.

    The full content hash, not just mtime, so a rewrite that keeps the same
    second is still detected, and a rename that swaps in a different file with
    the same size is.
    """
    try:
        stat_result = path.stat()
    except FileNotFoundError:
        return None
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return (stat_result.st_mtime_ns, stat_result.st_size, digest.hexdigest())


@dataclass
class WakeState:
    """One outstanding wake: work that is in a mailbox but not yet acknowledged.

    task_mtime_ns is the newest mailbox revision this wake represents.  A wake
    is acknowledged when the recipient's reply mailbox carries a newer mtime,
    and cleared at that point.
    """

    task_mtime_ns: int
    created_at: float = field(default_factory=time.time)
    # Last time the wake was delivered or re-nudged; the ack timer runs from
    # here, so re-nudges restart the window.
    last_delivery_at: float = field(default_factory=time.time)
    # Earliest time the next send attempt may run; deferrals and failed-send
    # backoffs push it out.
    next_attempt_at: float = field(default_factory=time.time)
    attempts: int = 0
    deferrals: int = 0
    renudges: int = 0
    delivered: bool = False
    # True once the terminal failure (gave up / unreached target / stalled)
    # has been told to the counterpart; set so it is told exactly once.
    reported: bool = False

    def to_dict(self) -> dict:
        return {
            "task_mtime_ns": self.task_mtime_ns,
            "created_at": self.created_at,
            "last_delivery_at": self.last_delivery_at,
            "next_attempt_at": self.next_attempt_at,
            "attempts": self.attempts,
            "deferrals": self.deferrals,
            "renudges": self.renudges,
            "delivered": self.delivered,
            "reported": self.reported,
        }

    @classmethod
    def from_dict(cls, payload: dict) -> "WakeState":
        return cls(**payload)


@dataclass
class AgentInstance:
    """A registered agent: which pane it is in and the identity of the process
    that owns that pane.

    start_id is "<pane_pid>:<proc-starttime>" — the pane's process and when it
    started, read from /proc.  It is stable for the life of the pane and
    changes if the pane's process is ever replaced, which is when re-
    registration must happen before anything is typed.
    """

    name: str  # "thinker" or the member's name
    pane: str
    agent_command: str  # first word of the roster's agent field; "" for thinker
    pane_pid: int | None = None
    start_id: str | None = None
    # registered | gone | exited | mismatch | restarted
    state: str = "registered"

    def to_dict(self) -> dict:
        return {
            "name": self.name,
            "pane": self.pane,
            "agent_command": self.agent_command,
            "pane_pid": self.pane_pid,
            "start_id": self.start_id,
            "state": self.state,
        }


@dataclass
class MemberState:
    name: str
    instance: AgentInstance | None
    revisions: dict[str, tuple[int, int, str] | None] = field(default_factory=dict)
    # Wake owed to the member (its in / in-addendum is newer than its out).
    member_wake: WakeState | None = None
    # Wake owed to the thinker (the member's out is newer than its in).
    thinker_wake: WakeState | None = None
    # Set after the counterpart has been told the member is parked, so the
    # notice goes out once; cleared when the pane is no longer parked.
    parked_notified: bool = False

    def mailbox_path(self, session_dir: Path, mailbox: str) -> Path:
        return session_dir / "members" / self.name / mailbox


def _process_start_id(pid: int) -> str | None:
    """Return "<pid>:<starttime>" for a running process, or None when it is
    gone.  starttime is /proc/<pid>/stat field 22, which never wraps, so two
    different processes can never share an identity."""
    try:
        with open(f"/proc/{pid}/stat", "rb") as handle:
            raw = handle.read().decode(errors="replace")
    except OSError:
        return None
    # The comm field (field 2) is wrapped in parentheses and may itself contain
    # spaces, so the numbered fields start after the last ')'.
    close_paren = raw.rfind(")")
    fields = raw[close_paren + 2 :].split()
    # starttime is field 22 overall; after dropping pid and comm it is index 19.
    if len(fields) < 20:
        return None
    return f"{pid}:{fields[19]}"


class WakeBroker:
    """Watches one session's mailbox files and delivers one-shot tmux wakes.

    A single process per session; broker.sh owns starting and stopping it.
    All state is kept in <session>/broker/state.json and reloaded on start,
    so a broker restart neither loses pending wakes nor re-wakes for work that
    was already acknowledged.
    """

    def __init__(
        self,
        session_dir: Path,
        socket_path: str,
        log_path: Path,
        state_path: Path,
        requests_dir: Path,
    ) -> None:
        self.session_dir = session_dir
        self.socket_path = socket_path
        self.log_path = log_path
        self.state_path = state_path
        self.requests_dir = requests_dir
        self.thinker: AgentInstance | None = None
        self.members: dict[str, MemberState] = {}
        self.started_at = time.time()
        self._stop = False
        self._dirty = False
        self._last_event_at = 0.0
        self._last_scan_at = 0.0
        self._no_thinker_warned = False
        self._inotify_fd = -1
        self._watched_paths: set[Path] = set()
        self._watch_descriptors: dict[int, Path] = {}

    # ------------------------------------------------------------------ log

    def log(self, message: str) -> None:
        # File only: broker.sh start redirects the process's stderr into this
        # same file, so printing as well would write every line twice.  If the
        # session directory has been deleted out from under the broker, the
        # log line goes to stderr rather than crashing the loop.
        line = f"{_utc_timestamp()} broker: {message}\n"
        try:
            with self.log_path.open("a") as handle:
                handle.write(line)
        except OSError:
            print(line, end="", file=sys.stderr, flush=True)

    # ----------------------------------------------------------------- tmux

    def _tmux(self, *args: str) -> str | None:
        """Run one tmux command against the session's server; None on failure.

        -S takes a full socket path, which is what this broker stores; -L would
        treat it as a name and look for it inside the default socket dir.
        """
        try:
            result = subprocess.run(
                ["tmux", "-S", self.socket_path, *args],
                capture_output=True,
                text=True,
                timeout=10,
            )
        except (OSError, subprocess.TimeoutExpired):
            return None
        if result.returncode != 0:
            return None
        return result.stdout

    def _pane_exists(self, pane: str) -> bool:
        listing = self._tmux("list-panes", "-a", "-F", "#{pane_id}")
        return listing is not None and pane in listing.splitlines()

    def _pane_format(self, pane: str, format: str) -> str:
        output = self._tmux("display-message", "-p", "-t", pane, format)
        return output.strip() if output else ""

    def _pane_capture(self, pane: str) -> str:
        return self._tmux("capture-pane", "-p", "-t", pane) or ""

    def _pane_is_busy(self, pane: str) -> bool:
        first_screen = self._pane_capture(pane)
        time.sleep(_BUSY_SAMPLE_SECONDS)
        return self._pane_capture(pane) != first_screen

    def _send_pointer(self, pane: str, message: str) -> bool:
        """Type one line into a pane and press Enter; True when the pane
        visibly reacted, which is as far as confirmation can honestly go."""
        screen_before = self._pane_capture(pane)
        if self._tmux("send-keys", "-t", pane, "-l", "--", message) is None:
            return False
        time.sleep(_SEND_DELAY_SECONDS)
        self._tmux("send-keys", "-t", pane, "Enter")
        time.sleep(_REACT_DELAY_SECONDS)
        return self._pane_capture(pane) != screen_before

    # ---------------------------------------------------------- registration

    def _register_instance(self, name: str, pane: str, agent_command: str) -> AgentInstance:
        pane_pid_raw = self._pane_format(pane, "#{pane_pid}")
        pane_pid = int(pane_pid_raw) if pane_pid_raw.isdigit() else None
        start_id = _process_start_id(pane_pid) if pane_pid is not None else None
        instance = AgentInstance(
            name=name,
            pane=pane,
            agent_command=agent_command,
            pane_pid=pane_pid,
            start_id=start_id,
        )
        if not self._pane_exists(pane):
            instance.state = "gone"
            self.log(f"{name}: pane {pane} does not exist; not registered")
        else:
            self.log(f"registered {name}: pane {pane} pid {pane_pid} start {start_id}")
        return instance

    def _read_roster(self) -> list[tuple[str, str, str]]:
        """Return (name, agent_command, pane) rows from roster.tsv."""
        roster_path = self.session_dir / "roster.tsv"
        if not roster_path.is_file():
            return []
        rows = []
        for line in roster_path.read_text().splitlines():
            if line.startswith("#") or not line.strip():
                continue
            fields = line.split("\t")
            if len(fields) >= 4:
                rows.append((fields[0], fields[2].split()[0] if fields[2] else "", fields[3]))
        return rows

    def _read_thinker_pane(self) -> str | None:
        env_path = self.session_dir / "session.env"
        if not env_path.is_file():
            return None
        for line in env_path.read_text().splitlines():
            if line.startswith("PRL_THINKER_PANE="):
                return line.split("=", 1)[1].strip().strip("'\"") or None
        return None

    def _sync_instances(self) -> None:
        """Re-derive the instance registry from the roster and session.env.

        The roster is the source of truth for who is on the team; this picks
        up a member added or re-registered (new pane) and drops one removed.
        """
        thinker_pane = self._read_thinker_pane()
        if thinker_pane:
            if self.thinker is None or self.thinker.pane != thinker_pane:
                self.thinker = self._register_instance("thinker", thinker_pane, "")
                self._no_thinker_warned = False

        roster_rows = self._read_roster()
        current_names = {name for name, _, _ in roster_rows}
        for name, agent_command, pane in roster_rows:
            member = self.members.get(name)
            if member is None:
                member = MemberState(name=name, instance=None)
                self.members[name] = member
                member.instance = self._register_instance(name, pane, agent_command)
            elif member.instance is None or member.instance.pane != pane:
                self.log(f"{name}: pane changed to {pane}; re-registering")
                member.instance = self._register_instance(name, pane, agent_command)
                member.parked_notified = False
        for name in list(self.members):
            if name not in current_names:
                self._deregister_member(name, "removed from the roster")

    def _deregister_member(self, name: str, reason: str) -> None:
        member = self.members.pop(name, None)
        if member is None:
            return
        self.log(f"deregistered {name}: {reason}")
        self._notify_counterpart(name, "member", f"{name} is no longer registered ({reason})")

    def _process_requests(self) -> None:
        for request_path in sorted(self.requests_dir.glob(f"{_REQUEST_PREFIX}*")):
            request_name = request_path.name[len(_REQUEST_PREFIX) :]
            if request_name.startswith("deregister-"):
                member_name = request_name[len("deregister-") :]
                if member_name in self.members:
                    self._deregister_member(member_name, "deregister requested")
                else:
                    self.log(f"request to deregister unknown member '{member_name}' ignored")
            else:
                self.log(f"unknown request file {request_path.name} ignored")
            request_path.unlink(missing_ok=True)

    # --------------------------------------------------------------- wakes

    def _mailbox_revision(self, member: MemberState, mailbox: str) -> tuple[int, int, str] | None:
        return file_revision(member.mailbox_path(self.session_dir, mailbox))

    def _update_revisions(self, member: MemberState) -> None:
        for mailbox in _MAILBOX_NAMES:
            revision = self._mailbox_revision(member, mailbox)
            previous = member.revisions.get(mailbox)
            if revision != previous:
                member.revisions[mailbox] = revision
                if revision is not None and revision[1] > 0:
                    self.log(f"{member.name}: {mailbox} updated (rev {revision[2][:12]})")

    def _reconcile_wakes(self, member: MemberState) -> None:
        """Create, coalesce, and acknowledge this member's two wakes.

        The rule is the one status.sh uses, made explicit: in (or
        in-addendum) newer than out means the member owes a reply, so the
        member is owed a wake; out newer than in means the thinker owes the
        next task, so the thinker is owed a wake.  The two cannot both hold,
        so at most one direction is pending per member.
        """
        in_revision = member.revisions.get("in")
        addendum_revision = member.revisions.get("in-addendum")
        out_revision = member.revisions.get("out")
        now = time.time()

        task_revisions = [
            revision
            for revision in (in_revision, addendum_revision)
            if revision is not None and revision[1] > 0
        ]
        task_mtime = max(revision[0] for revision in task_revisions) if task_revisions else None

        member_wake_needed = task_mtime is not None and (
            out_revision is None or out_revision[1] == 0 or out_revision[0] < task_mtime
        )
        if member_wake_needed:
            if member.member_wake is None:
                member.member_wake = WakeState(task_mtime_ns=task_mtime)
                self.log(f"{member.name}: pending wake to member (in newer than out)")
            elif task_mtime > member.member_wake.task_mtime_ns:
                # Newer work while a wake is outstanding: fold it in rather
                # than queue a second wake for the same pane.
                member.member_wake.task_mtime_ns = task_mtime
                member.member_wake.attempts = 0
                member.member_wake.delivered = False
                member.member_wake.reported = False
                member.member_wake.next_attempt_at = now
                self.log(f"{member.name}: newer task while a wake was pending; re-arming")
        elif member.member_wake is not None:
            self.log(f"{member.name}: task acknowledged (out is newer than in)")
            member.member_wake = None

        reply_revision = out_revision if out_revision and out_revision[1] > 0 else None
        if reply_revision is not None:
            thinker_wake_needed = task_mtime is None or reply_revision[0] > task_mtime
            if thinker_wake_needed:
                if member.thinker_wake is None:
                    member.thinker_wake = WakeState(task_mtime_ns=reply_revision[0])
                    self.log(f"{member.name}: pending wake to thinker (out newer than in)")
                elif reply_revision[0] > member.thinker_wake.task_mtime_ns:
                    member.thinker_wake.task_mtime_ns = reply_revision[0]
                    member.thinker_wake.attempts = 0
                    member.thinker_wake.delivered = False
                    member.thinker_wake.reported = False
                    member.thinker_wake.next_attempt_at = now
                    self.log(f"{member.name}: newer report while a wake was pending; re-arming")
            elif member.thinker_wake is not None:
                self.log(f"{member.name}: report acknowledged (in is newer than out)")
                member.thinker_wake = None
        elif member.thinker_wake is not None:
            self.log(f"{member.name}: report removed; dropping pending wake to thinker")
            member.thinker_wake = None

    def _wake_message(self, member: MemberState, direction: str) -> str:
        if direction == "thinker":
            return f"prl: {member.name} reported - read {member.mailbox_path(self.session_dir, 'out')}"
        out_revision = member.revisions.get("out")
        out_mtime = out_revision[0] if out_revision else 0
        changed_mailboxes = []
        for mailbox in ("in", "in-addendum"):
            revision = member.revisions.get(mailbox)
            if revision is not None and revision[1] > 0 and revision[0] > out_mtime:
                changed_mailboxes.append(member.mailbox_path(self.session_dir, mailbox))
        if not changed_mailboxes:
            changed_mailboxes.append(member.mailbox_path(self.session_dir, "in"))
        if len(changed_mailboxes) == 1 and changed_mailboxes[0].name == "in-addendum":
            return f"prl: new addendum - read {changed_mailboxes[0]}"
        return f"prl: your inbox was updated - read {' then '.join(str(p) for p in changed_mailboxes)}"

    def _validate_instance(self, instance: AgentInstance) -> tuple[str, str] | None:
        """Check a registered pane before anything is typed into it.

        Returns (kind, detail) when the pane must not receive a wake.  kinds:
        gone / exited / mismatch / restarted are terminal for the instance;
        parked is not — a parked pane can be resumed by hand and then woken.
        """
        if not self._pane_exists(instance.pane):
            return ("gone", f"pane {instance.pane} closed")
        foreground_command = self._pane_format(instance.pane, "#{pane_current_command}")
        if not foreground_command or foreground_command in _SHELLS:
            return ("exited", f"pane {instance.pane} is at a shell prompt")
        if instance.name != "thinker":
            pane_member_tag = self._pane_format(instance.pane, "#{@prl_member}")
            if pane_member_tag != instance.name:
                return (
                    "mismatch",
                    f"pane {instance.pane} is tagged '{pane_member_tag}', not '{instance.name}'",
                )
        live_start_id = None
        pane_pid_raw = self._pane_format(instance.pane, "#{pane_pid}")
        if pane_pid_raw.isdigit():
            live_start_id = _process_start_id(int(pane_pid_raw))
        if instance.start_id and live_start_id and live_start_id != instance.start_id:
            return (
                "restarted",
                f"pane {instance.pane} is running a different process ({instance.start_id} -> {live_start_id})",
            )
        # An idle pane's foreground command is the agent itself; the pane's
        # shell only takes the foreground once the agent has exited, which the
        # shell check above already catches.  A build the agent runs is a
        # child in the same process group, so it does not change this.
        if instance.agent_command and foreground_command != instance.agent_command:
            return (
                "mismatch",
                f"pane {instance.pane} is running '{foreground_command}', not '{instance.agent_command}'",
            )
        if _PARKED_GOAL_MARKER in self._pane_capture(instance.pane):
            return ("parked", f"pane {instance.pane} shows a parked goal")
        return None

    def _notify_counterpart(self, member_name: str, failed_direction: str, detail: str) -> None:
        """Tell the other side that a wake could not be delivered.

        failed_direction names the side that failed ("member" or "thinker");
        the notice goes the other way.  One best-effort send: if the
        counterpart is also unreachable the failure stays in the broker log
        and in broker.sh status, which is the visible record.
        """
        if failed_direction == "member":
            target = self.thinker
            if target is None:
                self.log(f"no thinker registered to tell about: {detail}")
                return
        else:
            member = self.members.get(member_name)
            target = member.instance if member is not None else None
            if target is None:
                self.log(f"{member_name} has no pane to tell about: {detail}")
                return
        if target.state != "registered" or not self._pane_exists(target.pane):
            self.log(f"counterpart {target.name} unreachable; failure stays in the log: {detail}")
            return
        message = f"prl: broker: {detail}"
        delivered = self._send_pointer(target.pane, message)
        self.log(f"notified {target.name} about {member_name}: {detail} ({'delivered' if delivered else 'unconfirmed'})")

    def _handle_pane_problem(
        self, member: MemberState, wake: WakeState, direction: str, instance: AgentInstance,
        kind: str, detail: str, now: float,
    ) -> None:
        """Apply a validation problem found before a send: park it, or
        deregister the instance and tell the counterpart."""
        if kind == "parked":
            # A plain wake cannot move a parked goal; 'roster.sh kick' can.
            # Tell the counterpart once and defer until the pane is no longer
            # parked — this broker does not resume it.
            if not member.parked_notified:
                member.parked_notified = True
                if direction == "member":
                    self._notify_counterpart(
                        member.name,
                        direction,
                        f"{member.name} is parked (Goal stalled); resume with "
                        f"'roster.sh kick {self.session_dir} {member.name}'",
                    )
                else:
                    self._notify_counterpart(
                        member.name,
                        direction,
                        "the thinker pane is parked (Goal stalled); resume it by hand",
                    )
            wake.last_delivery_at = now
            self.log(f"defer wake for {instance.name}: {detail}")
            return
        instance.state = kind
        self.log(f"deregistered {instance.name}: {detail}")
        if direction == "member":
            member.member_wake = None
            member.parked_notified = False
        else:
            member.thinker_wake = None
        self._notify_counterpart(
            member.name,
            direction,
            f"{instance.name} is unreachable ({detail}); the work is still in the mailbox files",
        )

    def _attempt_deliveries(self, member: MemberState) -> None:
        now = time.time()
        for wake, direction in ((member.member_wake, "member"), (member.thinker_wake, "thinker")):
            if wake is None or wake.reported:
                continue
            instance = member.instance if direction == "member" else self.thinker
            if instance is None:
                if direction == "thinker" and not self._no_thinker_warned:
                    self.log(f"{member.name}: report pending but no thinker pane is registered")
                    self._no_thinker_warned = True
                continue
            if instance.state != "registered":
                continue

            if wake.delivered:
                # The pointer is in the pane; now only the recipient's reply
                # can move this.  The pane is re-validated when the ack window
                # expires, not on every scan, so a working member's evidence
                # writes do not burn tmux calls.
                if now - wake.last_delivery_at <= _ACK_TIMEOUT_SECONDS:
                    continue
                problem = self._validate_instance(instance)
                if problem is not None:
                    self._handle_pane_problem(member, wake, direction, instance, *problem, now)
                    continue
                member.parked_notified = False
                if wake.renudges < _MAX_RENUDGES:
                    message = self._wake_message(member, direction)
                    self._send_pointer(instance.pane, message)
                    wake.renudges += 1
                    wake.last_delivery_at = now
                    self.log(f"re-nudged {instance.name} (no ack within {_ACK_TIMEOUT_SECONDS // 60}m)")
                else:
                    wake.reported = True
                    self._notify_counterpart(
                        member.name,
                        direction,
                        f"{instance.name} has not acknowledged its mailbox for "
                        f"{_ACK_TIMEOUT_SECONDS // 60}m after {wake.renudges} re-nudges; "
                        f"check pane {instance.pane}",
                    )
                continue

            if wake.next_attempt_at > now:
                continue

            problem = self._validate_instance(instance)
            if problem is not None:
                self._handle_pane_problem(member, wake, direction, instance, *problem, now)
                continue
            member.parked_notified = False

            cursor_column = self._pane_format(instance.pane, "#{cursor_x}")
            if cursor_column.isdigit() and int(cursor_column) > _EMPTY_INPUT_MAX_COLUMN:
                wake.deferrals += 1
                wake.next_attempt_at = now + min(
                    _DEFERRAL_CAP_SECONDS, _RETRY_BASE_SECONDS**wake.deferrals
                )
                self.log(f"defer wake for {instance.name}: input line occupied (cursor column {cursor_column})")
                continue
            if self._pane_is_busy(instance.pane):
                wake.deferrals += 1
                wake.next_attempt_at = now + min(
                    _DEFERRAL_CAP_SECONDS, _RETRY_BASE_SECONDS**wake.deferrals
                )
                self.log(f"defer wake for {instance.name}: pane is mid-turn")
                continue

            message = self._wake_message(member, direction)
            if self._send_pointer(instance.pane, message):
                wake.delivered = True
                wake.last_delivery_at = now
                self.log(f"wake {instance.name} <- {message} (delivered)")
            else:
                wake.attempts += 1
                if wake.attempts >= _MAX_SEND_ATTEMPTS:
                    wake.reported = True
                    self._notify_counterpart(
                        member.name,
                        direction,
                        f"could not deliver a wake to {instance.name} after {wake.attempts} "
                        f"attempts; the work is still in the mailbox files",
                    )
                    self.log(f"stopped trying to wake {instance.name} after {wake.attempts} attempts")
                else:
                    wake.next_attempt_at = now + min(
                        _RETRY_CAP_SECONDS, _RETRY_BASE_SECONDS * 2**wake.attempts
                    )
                    self.log(f"wake to {instance.name} unconfirmed (attempt {wake.attempts}); retrying")

    # ----------------------------------------------------------------- scan

    def scan(self) -> None:
        self._last_scan_at = time.time()
        self._sync_instances()
        self._process_requests()
        for member in list(self.members.values()):
            self._update_revisions(member)
            self._reconcile_wakes(member)
            self._attempt_deliveries(member)
        self._save_state()

    # -------------------------------------------------------------- inotify

    def _add_watch(self, path: Path) -> None:
        if path in self._watched_paths:
            return
        watch_descriptor = _libc.inotify_add_watch(
            self._inotify_fd, os.fsencode(path), _WATCH_MASK
        )
        if watch_descriptor < 0:
            errno = ctypes.get_errno()
            self.log(f"could not watch {path}: {os.strerror(errno)}")
            return
        self._watched_paths.add(path)
        self._watch_descriptors[watch_descriptor] = path

    def _is_watched_file(self, path: Path) -> bool:
        """Files worth watching: the roster, session.env, and anything inside
        a member's directory.  The broker's own state directory is excluded so
        writing state.json cannot trigger a rescan loop."""
        if self.state_path.parent in path.parents:
            return False
        return path.parent == self.session_dir or self.session_dir / "members" in path.parents

    def _add_initial_watches(self) -> None:
        self._add_watch(self.session_dir)
        for name in ("roster.tsv", "session.env"):
            candidate = self.session_dir / name
            if candidate.is_file():
                self._add_watch(candidate)
        members_dir = self.session_dir / "members"
        self._add_watch(members_dir)
        if members_dir.is_dir():
            for member_dir in sorted(members_dir.iterdir()):
                if member_dir.is_dir():
                    self._add_watch(member_dir)
                    for mailbox in _MAILBOX_NAMES:
                        mailbox_path = member_dir / mailbox
                        if mailbox_path.is_file():
                            self._add_watch(mailbox_path)
        self._add_watch(self.requests_dir)

    def _handle_inotify_event(self, watch_descriptor: int, mask: int, name: str) -> None:
        watched_path = self._watch_descriptors.get(watch_descriptor)
        if watched_path is None:
            return
        if name and mask & (IN_CREATE | IN_MOVED_TO):
            child = watched_path / name
            if child.is_dir():
                if self.state_path.parent not in child.parents and child != self.state_path.parent:
                    self._add_watch(child)
            elif self._is_watched_file(child):
                self._add_watch(child)

    def _drain_inotify(self) -> None:
        # The fd is non-blocking: once the queue is drained, read raises
        # BlockingIOError rather than stalling the loop until the next event.
        while True:
            try:
                data = os.read(self._inotify_fd, 65536)
            except BlockingIOError:
                return
            except OSError:
                return
            offset = 0
            while offset + _EVENT_HEADER.size <= len(data):
                watch_descriptor, mask, _cookie, name_length = _EVENT_HEADER.unpack_from(
                    data, offset
                )
                name = data[offset + _EVENT_HEADER.size : offset + _EVENT_HEADER.size + name_length]
                name = name.rstrip(b"\0").decode(errors="replace")
                offset += _EVENT_HEADER.size + name_length
                self._handle_inotify_event(watch_descriptor, mask, name)

    # --------------------------------------------------------------- state

    def _save_state(self) -> None:
        payload = {
            "session": str(self.session_dir),
            "socket": self.socket_path,
            "started_at": self.started_at,
            "thinker": self.thinker.to_dict() if self.thinker else None,
            "members": {
                name: {
                    "instance": member.instance.to_dict() if member.instance else None,
                    "revisions": member.revisions,
                    "member_wake": member.member_wake.to_dict() if member.member_wake else None,
                    "thinker_wake": member.thinker_wake.to_dict() if member.thinker_wake else None,
                }
                for name, member in self.members.items()
            },
        }
        # Revisions hold tuples, which JSON serializes as arrays; from_dict
        # turns them back.
        tmp_path = self.state_path.with_name(self.state_path.name + ".tmp")
        tmp_path.write_text(json.dumps(payload, indent=2))
        os.replace(tmp_path, self.state_path)

    def _load_state(self) -> None:
        """Restore mailbox revisions and pending wakes from a previous run.

        Instances are re-registered from the live roster, never restored: the
        panes may have moved while the broker was down, and the roster is the
        source of truth.
        """
        if not self.state_path.is_file():
            return
        try:
            payload = json.loads(self.state_path.read_text())
        except (OSError, json.JSONDecodeError) as error:
            self.log(f"could not read previous state ({error}); starting fresh")
            return
        for name, member_payload in payload.get("members", {}).items():
            member = MemberState(name=name, instance=None)
            member.revisions = {
                mailbox: tuple(revision) if revision is not None else None
                for mailbox, revision in member_payload.get("revisions", {}).items()
            }
            if member_payload.get("member_wake"):
                member.member_wake = WakeState.from_dict(member_payload["member_wake"])
            if member_payload.get("thinker_wake"):
                member.thinker_wake = WakeState.from_dict(member_payload["thinker_wake"])
            self.members[name] = member
        self.log("restored pending state from previous run")

    # ----------------------------------------------------------------- run

    def _handle_stop_signal(self, _signum, _frame) -> None:
        self._stop = True

    def _handle_rescan_signal(self, _signum, _frame) -> None:
        self._dirty = True
        self._last_event_at = time.time()

    def run(self) -> None:
        signal.signal(signal.SIGTERM, self._handle_stop_signal)
        signal.signal(signal.SIGINT, self._handle_stop_signal)
        signal.signal(signal.SIGUSR1, self._handle_rescan_signal)

        self._inotify_fd = _libc.inotify_init1(0)
        if self._inotify_fd < 0:
            raise RuntimeError("inotify_init1 failed")
        os.set_blocking(self._inotify_fd, False)

        self.requests_dir.mkdir(parents=True, exist_ok=True)
        self._add_initial_watches()
        self._load_state()

        if self._tmux("list-panes", "-a", "-F", "#{pane_id}") is None:
            self.log(f"WARNING: no tmux server reachable on {self.socket_path}; wakes will fail until one is")
        self.log(f"broker started (pid {os.getpid()}, session {self.session_dir}, socket {self.socket_path})")
        self.state_path.parent.mkdir(parents=True, exist_ok=True)
        self.state_path.with_name(self.state_path.name + ".pid").write_text(f"{os.getpid()}\n")

        self.scan()
        try:
            while not self._stop:
                ready, _, _ = select.select([self._inotify_fd], [], [], 0.5)
                if ready:
                    self._drain_inotify()
                    self._dirty = True
                    self._last_event_at = time.time()
                now = time.time()
                if self._dirty and now - self._last_event_at >= _DEBOUNCE_SECONDS:
                    self._dirty = False
                    self.scan()
                elif now - self._last_scan_at >= _FALLBACK_SCAN_INTERVAL_SECONDS:
                    self.scan()
        finally:
            self._save_state()
            os.close(self._inotify_fd)
            self.state_path.with_name(self.state_path.name + ".pid").unlink(missing_ok=True)
            self.log("broker stopped")


def command_run(args: argparse.Namespace) -> int:
    session_dir = Path(args.session).resolve()
    if not session_dir.is_dir():
        print(f"broker: no such session dir: {session_dir}", file=sys.stderr)
        return 1
    broker_dir = session_dir / "broker"
    pidfile = broker_dir / "state.json.pid"
    if pidfile.is_file():
        try:
            old_pid = int(pidfile.read_text().strip())
            if os.path.isdir(f"/proc/{old_pid}"):
                print(f"broker: already running (pid {old_pid}); stop it first", file=sys.stderr)
                return 1
        except ValueError:
            pass
    broker = WakeBroker(
        session_dir=session_dir,
        socket_path=args.socket,
        log_path=broker_dir / "broker.log",
        state_path=broker_dir / "state.json",
        requests_dir=broker_dir / "requests",
    )
    broker.run()
    return 0


def _format_wake(wake: dict | None) -> str:
    if wake is None:
        return "-"
    age_minutes = int((time.time() - wake["last_delivery_at"]) // 60)
    parts = [f"pending {age_minutes}m"]
    if wake["delivered"]:
        parts.append("delivered, awaiting ack")
    if wake["attempts"]:
        parts.append(f"{wake['attempts']} failed attempt(s)")
    if wake["deferrals"]:
        parts.append(f"{wake['deferrals']} deferral(s)")
    if wake["reported"]:
        parts.append("failure reported")
    return ", ".join(parts)


def command_status(args: argparse.Namespace) -> int:
    session_dir = Path(args.session).resolve()
    broker_dir = session_dir / "broker"
    pidfile = broker_dir / "state.json.pid"
    pid = None
    if pidfile.is_file():
        try:
            pid = int(pidfile.read_text().strip())
        except ValueError:
            pid = None
    running = pid is not None and os.path.isdir(f"/proc/{pid}")
    if running:
        print(f"broker: running (pid {pid})  session {session_dir}")
    else:
        print(f"broker: NOT RUNNING  session {session_dir}")

    state_path = broker_dir / "state.json"
    if not state_path.is_file():
        if not running:
            print("no broker state; nothing is pending")
        return 0 if running else 1
    try:
        payload = json.loads(state_path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        print(f"could not read broker state: {error}")
        return 1
    print(f"socket: {payload.get('socket')}")
    thinker = payload.get("thinker")
    if thinker:
        print(f"thinker: {thinker['state']} (pane {thinker['pane']}, start {thinker['start_id']})")
    else:
        print("thinker: not registered")
    for name, member_payload in sorted(payload.get("members", {}).items()):
        instance = member_payload.get("instance")
        instance_state = instance["state"] if instance else "not registered"
        print(
            f"{name}: instance {instance_state}  "
            f"wake->member {_format_wake(member_payload.get('member_wake'))}  "
            f"wake->thinker {_format_wake(member_payload.get('thinker_wake'))}"
        )
    return 0 if running else 1


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Opt-in tmux wake broker for a paired-review-loop session."
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    run_parser = subparsers.add_parser("run", help="run the broker (used by broker.sh)")
    run_parser.add_argument("--session", required=True, help="PRL session directory")
    run_parser.add_argument(
        "--socket",
        required=True,
        help="tmux socket of the server holding the session's panes",
    )
    run_parser.set_defaults(func=command_run)
    status_parser = subparsers.add_parser("status", help="show broker state")
    status_parser.add_argument("--session", required=True, help="PRL session directory")
    status_parser.set_defaults(func=command_status)
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())