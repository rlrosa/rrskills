#!/usr/bin/env bash
# ack.sh <session-dir> <name> <mailbox>
#
# Record that the current contents of <session>/members/<name>/<mailbox> have
# been read.  It writes the file's exact revision (mtime in ns, size, sha256)
# to <mailbox>.ack next to the file.
#
# The broker clears a pending wake only while the mailbox still matches the
# recorded revision, so:
#   - acknowledging a final report removes the pending wake without posting
#     another task, and
#   - a file that is rewritten after the ack no longer matches it, so a stale
#     ack can never suppress a newer revision.
#
# Workflow (see BROKER.md): the member acks `in` (and `in-addendum` when it
# has one) right after reading them; the thinker acks a member's `out` right
# after reading it.  A wake that is not acknowledged is re-nudged, then the
# stall is reported.
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

[ -d "$SESSION" ] || { echo "ack: no such session dir: $SESSION" >&2; exit 1; }
SESSION=$(cd "$SESSION" && pwd)
prl_assert_session_owner "$SESSION" || exit 4

case "$NAME" in
  *[!A-Za-z0-9_-]*)
    echo "ack: member name must be letters, digits, dash or underscore (got '$NAME')" >&2
    exit 2
    ;;
esac
case "$MAILBOX" in
  in | in-addendum | out) ;;
  *)
    echo "ack: mailbox must be in, in-addendum or out (got '$MAILBOX')" >&2
    exit 2
    ;;
esac

FILE="$SESSION/members/$NAME/$MAILBOX"
[ -f "$FILE" ] || { echo "ack: no such mailbox: $FILE" >&2; exit 1; }
ACK_FILE="$FILE.ack"

# Compute the same revision triple the broker compares against:
# integer mtime in nanoseconds, size, sha256.  (stat's %.Y prints decimal
# seconds, which does not convert to integer nanoseconds losslessly, so the
# triple is computed the same way the broker does.)
python3 - "$FILE" "$ACK_FILE" <<'PY'
import hashlib
import os
import sys

file_path, ack_path = sys.argv[1], sys.argv[2]
stat_result = os.stat(file_path)
with open(file_path, "rb") as handle:
    digest = hashlib.sha256(handle.read()).hexdigest()
tmp_path = f"{ack_path}.tmp.{os.getpid()}"
with open(tmp_path, "w") as handle:
    handle.write(f"{stat_result.st_mtime_ns} {stat_result.st_size} {digest}\n")
os.replace(tmp_path, ack_path)
PY
python_status=$?
[ $python_status -eq 0 ] || { echo "ack: could not read $FILE" >&2; exit 1; }
echo "acked $NAME/$MAILBOX"