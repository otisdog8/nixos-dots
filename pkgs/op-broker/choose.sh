# op-broker-choose [--timeout SECS] -- REQUESTER TEXT OPTION...
#
# The broker's "which login?" dialog, for when several items match an origin.
# Prints the 0-based index of the chosen option and exits 0; anything else
# (cancel, close, timeout) prints nothing and exits 1. Choosing is not approving:
# the broker still asks sbx-prompt about the chosen item.
#
# Every string comes from the broker (requester label, cleaned item titles), but
# item titles are the vault's, so they are shown as plain text: zenity's list
# text is markup, hence the escaping.
set -u
timeout=60
while [ $# -gt 0 ]; do
  case "$1" in
    --timeout) timeout="$2"; shift 2 ;;
    --) shift; break ;;
    *) echo "op-broker-choose: unknown option $1" >&2; exit 2 ;;
  esac
done
if [ $# -lt 3 ]; then
  echo "usage: op-broker-choose [--timeout SECS] -- REQUESTER TEXT OPTION..." >&2
  exit 2
fi
esc() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  printf '%s' "$s"
}
who="$1" text="$2"
shift 2
rows=()
i=0
for opt in "$@"; do
  rows+=("$i" "$(esc "$opt")")
  i=$((i + 1))
done
out="$(@zenity@ --list \
  --title "Sandbox permission request" \
  --text "$(esc "$who") asks for a 1Password login.
$(esc "$text")" \
  --column "#" --column "Login" --hide-column 1 --print-column 1 \
  --ok-label "Choose" --cancel-label "Deny" \
  --timeout "$timeout" --width 520 --height 360 \
  "${rows[@]}" 2>/dev/null)"
rc=$?
case "$out" in
  '' | *[!0-9]*) exit 1 ;;
esac
[ "$rc" = 0 ] || exit 1
printf '%s\n' "$out"
