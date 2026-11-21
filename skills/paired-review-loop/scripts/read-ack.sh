#!/usr/bin/env bash
# read-ack.sh <session-dir> <name> <mailbox>
#
# Read a mailbox and record that exactly what was read has been read, in one
# operation.  The file is opened once; the revision (mtime in ns, size,
# sha256) is taken from that single open handle, recorded in <mailbox>.ack
# next to the file, and the content is printed to stdout — so the output is
# precisely what was acknowledged.
#
# Why one operation: acking "whatever is on disk now" is racy.  If report A
# is read, then atomically replaced by B, a separate ack step would record
# B's revision and B would be treated as read without being read.  Binding
# the revision to the snapshot that was read makes that impossible: an ack
# made while A was current can never match B, so B's wake re-arms instead of
# disappearing.
#
# The broker clears a pending wake only while the mailbox still matches the
# recorded revision, so:
#   - acknowledging a final report removes the pending wake without posting
#     another task, and
#   - a file rewritten after the read no longer matches it, so a stale ack
#     can never suppress a newer revision.
#
# Workflow (see BROKER.md): the member read-acks `in` (and `in-addendum`
# when it has one) right after being woken; the thinker read-acks a member's
# `out` right after it.  A wake that is not acknowledged is re-nudged, then
# the stall is reported.
#
# Exit 0 on success, 2 on bad usage, 1 when the mailbox does not exist.
set -u

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
  exit "${1:-0}"
}

[ $# -eq 3 ] || usage 2
SESSION="$1"
NAME="$2"
MAILBOX="$3"

[ -d "$SESSION" ] || { echo "read-ack: no such session dir: $SESSION" >&2; exit 1; }
SESSION=$(cd "$SESSION" && pwd)
prl_assert_session_owner "$SESSION" || exit 4

case "$NAME" in
  *[!A-Za-z0-9_-]*)
    echo "read-ack: member name must be letters, digits, dash or underscore (got '$NAME')" >&2
    exit 2
    ;;
esac
case "$MAILBOX" in
  in | in-addendum | out) ;;
  *)
    echo "read-ack: mailbox must be in, in-addendum or out (got '$MAILBOX')" >&2
    exit 2
    ;;
esac

FILE="$SESSION/members/$NAME/$MAILBOX"
[ -f "$FILE" ] || { echo "read-ack: no such mailbox: $FILE" >&2; exit 1; }
ACK_FILE="$FILE.ack"

# One open handle for stat and read, so the recorded revision is the
# revision of the content that is printed.  (A rewrite that swaps the file
# via rename while this runs is still read in full from the old inode; a
# non-atomic in-place rewrite can mix the two, in which case the recorded
# revision matches neither version and the wake stays pending — the
# conservative outcome.)
python3 - "$FILE" "$ACK_FILE" <<'PY'
import hashlib
import os
import sys

file_path, ack_path = sys.argv[1], sys.argv[2]
try:
    fd = os.open(file_path, os.O_RDONLY)
except OSError as error:
    print(f"read-ack: cannot open {file_path}: {error}", file=sys.stderr)
    sys.exit(1)
with os.fdopen(fd, "rb") as handle:
    stat_result = os.fstat(handle.fileno())
    data = handle.read()
digest = hashlib.sha256(data).hexdigest()
tmp_path = f"{ack_path}.tmp.{os.getpid()}"
with open(tmp_path, "w") as handle:
    handle.write(f"{stat_result.st_mtime_ns} {stat_result.st_size} {digest}\n")
os.replace(tmp_path, ack_path)
sys.stdout.buffer.write(data)
if data and not data.endswith(b"\n"):
    sys.stdout.write("\n")
print(f"[read-ack: acknowledged {file_path} rev {stat_result.st_mtime_ns} {stat_result.st_size} {digest[:12]}]")
PY
exit $?