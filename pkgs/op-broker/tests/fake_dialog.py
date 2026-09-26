#!/usr/bin/env python3
"""Stand-in for sbx-prompt ("prompt") and op-broker-choose ("choose") in the
tests: logs [mode, argv...] to $FAKE_DIALOG_LOG and answers from
$FAKE_PROMPT_ANSWER (once/session/deny) or $FAKE_CHOOSE_ANSWER (an index, or
empty to cancel)."""

import json
import os
import sys

mode = sys.argv[1]
with open(os.environ["FAKE_DIALOG_LOG"], "a") as log:
    log.write(json.dumps([mode] + sys.argv[2:]) + "\n")

if mode == "choose":
    ans = os.environ.get("FAKE_CHOOSE_ANSWER", "")
    if ans == "":
        sys.exit(1)
    print(ans)
    sys.exit(0)

ans = os.environ.get("FAKE_PROMPT_ANSWER", "deny")
print(ans)
sys.exit(0 if ans in ("once", "session") else 1)
