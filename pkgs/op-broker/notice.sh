# op-broker-notice [--timeout SECS] -- REQUESTER SUMMARY DETAIL
#
# The broker's "this looks like probing" notice: a browser asked for logins on
# several sites that have none saved (or hit the rate limit). Informational;
# the one choice it offers is to block the requester for a while. Prints
# "block" when the user chose that, "dismiss" otherwise (closed, timed out).
#
# SUMMARY and DETAIL come from the broker (canonical origins it validated, its
# own label for the requester) and are shown as plain text.
set -u
timeout=120
while [ $# -gt 0 ]; do
  case "$1" in
    --timeout) timeout="$2"; shift 2 ;;
    --) shift; break ;;
    *) echo "op-broker-notice: unknown option $1" >&2; exit 2 ;;
  esac
done
if [ $# -lt 3 ]; then
  echo "usage: op-broker-notice [--timeout SECS] -- REQUESTER SUMMARY DETAIL" >&2
  exit 2
fi
who="$1" what="$2" detail="$3"
out="$(@zenity@ --warning --no-markup --no-wrap \
  --title "1Password: possible probing" \
  --text "$who $what.

$detail" \
  --ok-label "Dismiss" \
  --extra-button "Block it for an hour" \
  --timeout "$timeout" 2>/dev/null)"
if [ "$out" = "Block it for an hour" ]; then
  echo block
else
  echo dismiss
fi
exit 0
