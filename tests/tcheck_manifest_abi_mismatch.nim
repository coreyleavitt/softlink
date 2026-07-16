## RFC-0001 §B.3/§B.5, slice B6a: an ABI mismatch degrades to
## no-manifest behavior ENTIRELY — every other check is skipped, not just
## downgraded. `tests/manifests/testlib_abi_mismatch.compat.json` is
## fixed (never templated per-OS-leg) at `"abi": "nonesuch-ilp128"`, which
## never matches any real build target, AND records `testlib_add` as
## fully `absent` — which would otherwise contradict this proc's
## `{.since: "1.0.0".}` claim (a hard error with no escape hatch, per
## `tfail_manifest_since_contradiction.nim`). Proving the compile
## succeeds with ONLY the ABI warning is the proof that "ignored" really
## means ignored, not merely "downgraded to a warning". Run by the
## nimble test task, which expects compilation to SUCCEED and its output
## to contain "ignoring the compat manifest entirely" but NOT "corrected
## lower bound".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "libtestlib.so":
  compatManifest "manifests/testlib_abi_mismatch.compat.json"
  proc testlib_add(a: cint, b: cint): cint {.cdecl, since: "1.0.0", header: "tests/testlib.h".}
