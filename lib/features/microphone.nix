# Audio input: the microphone (and other apps' sound, via monitor sources), on
# top of audio output. Every recording stream is approved first by the sandbox
# broker (a desktop prompt; "Allow for this session" covers the rest of it).
{ ... }:
{
  imports = [ ./audio.nix ];
  config.app.capabilities.microphone = true;
}
