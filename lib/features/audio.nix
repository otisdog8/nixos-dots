# Audio output — capability-based. Playback only: recording (the microphone)
# is microphone.nix, and even then asks you first (the sandbox broker's
# PulseAudio filter, lib/broker/broker.py).
{ config, lib, ... }:
{
  imports = [ ../app-spec.nix ];
  config.app.capabilities.audio = true;
}
