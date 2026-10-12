#!/usr/bin/env python3
"""Stand-in for the op launcher (`timeout` in a VM guest): logs that it ran to
$FAKE_LAUNCHER_LOG, then runs its arguments as a child and exits with its
status (so op's parent is this process, as with timeout)."""

import os
import subprocess
import sys

with open(os.environ["FAKE_LAUNCHER_LOG"], "a") as log:
    log.write(" ".join(sys.argv[1:2]) + "\n")
sys.exit(subprocess.call(sys.argv[1:]))
