# passt for VM networking.
pkgs:
# passt 2026_07_16 asserts on an exactly full receive iovec array: the
# result is a COUNT, so equality with remaining capacity is valid. Permit
# negative results to reach the existing error handler before unsigned
# conversion. Keep the bound check, rather than disabling assertions.
# The earlier brk exception only exposed this assertion (glibc allocates
# while reporting it); it was not a fix for the network failure.
pkgs.passt.overrideAttrs (old: {
  postPatch = (old.postPatch or "") + ''
    substituteInPlace tcp_vu.c --replace-fail \
      'assert(cnt < ARRAY_SIZE(iov_msg) - j);' \
      'assert(cnt < 0 || (size_t)cnt <= ARRAY_SIZE(iov_msg) - j);'
  '';
})
