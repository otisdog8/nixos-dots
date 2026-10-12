# What the sandbox broker's PulseAudio filter lets a sandbox do
# (modules.sandbox.broker.sandboxes.<name>.audio), from its capabilities:
# nothing (no socket), playback, or playback + recording after approval.
caps:
if !caps.audio then
  null
else if caps.microphone then
  "microphone"
else
  "playback"
