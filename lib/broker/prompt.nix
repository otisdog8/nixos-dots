# sbx-prompt: the one permission dialog every sandbox broker uses (sandbox
# escapes, temporary grants, FIDO sharing, password items).
#
#   sbx-prompt [--timeout SECS] [--no-session] [--deny-all LABEL] REQUESTER SUMMARY [DETAIL]
#
# Shows a dialog on the user's desktop naming the requesting sandbox and what it
# asks for, and prints the decision on stdout: "once", "session" (allow the same
# request again without asking, for the rest of the login session; the broker
# caps it at 12 hours), "deny", or "deny-all" (the --deny-all button, LABEL: the
# broker refuses this request and the kind it names for the session, without
# asking). Exit status 0 when allowed, 1 when denied. No answer
# within the timeout (default 60 s) is a denial, as is a closed dialog. Deny has
# the focus, so a stray Enter or Space (typing into the window under the dialog
# as it appears) denies.
#
# Everything in the dialog may come from the sandbox, so it is shown as plain text
# (no markup) and the requester is always the broker's own name for the sandbox,
# never something the sandbox chose. Callers pass sandbox-supplied text escaped,
# one line per field and of bounded length (no wrapping here, so it can't pose as
# a line of the dialog's own).
pkgs:
pkgs.writeShellScriptBin "sbx-prompt" ''
  set -u
  timeout=60
  session=1
  denyall=
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout) timeout="$2"; shift 2 ;;
      --no-session) session=0; shift ;;
      --deny-all) denyall="$2"; shift 2 ;;
      --) shift; break ;;
      -*) echo "sbx-prompt: unknown option $1" >&2; exit 2 ;;
      *) break ;;
    esac
  done
  if [ $# -lt 2 ]; then
    echo "usage: sbx-prompt [--timeout SECS] [--no-session] [--deny-all LABEL] REQUESTER SUMMARY [DETAIL]" >&2
    exit 2
  fi
  who="$1" what="$2" detail="''${3:-}"
  text="$who asks to:
  $what"
  [ -n "$detail" ] && text="$text

  $detail"
  args=(
    --question --no-markup --no-wrap --default-cancel
    --title "Sandbox permission request"
    --icon dialog-warning
    --text "$text"
    --ok-label "Allow once"
    --cancel-label "Deny"
    --timeout "$timeout"
  )
  [ "$session" = 1 ] && args+=(--extra-button "Allow for this session")
  [ -n "$denyall" ] && args+=(--extra-button "$denyall")
  out="$(${pkgs.zenity}/bin/zenity "''${args[@]}" 2>/dev/null)"
  rc=$?
  if [ "$rc" = 0 ]; then
    echo once
    exit 0
  elif [ "$session" = 1 ] && [ "$out" = "Allow for this session" ]; then
    echo session
    exit 0
  elif [ -n "$denyall" ] && [ "$out" = "$denyall" ]; then
    echo deny-all
    exit 1
  fi
  echo deny
  exit 1
''
