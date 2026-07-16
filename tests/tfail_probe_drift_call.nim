## RFC-0001 §9/§C.1/§C.4b: the version probe may not directly call one of
## the block's own wrappers when that symbol carries any `mismatch`
## interval in the attached compat manifest — dispatching a known-drifted
## symbol INSIDE the mechanism built to detect drift would be exactly the
## corruption the refusal machinery exists to prevent ("the probe must not
## be the drift", RFC-0001 §C.1). This is a MACRO-TIME check (the manifest
## is already parsed by the time the probe body is scanned); indirect
## calls can't be seen statically and remain a documented residual risk
## (see `scanProbeBodyForDriftCalls`'s own doc comment in src/softlink.nim).
##
## `tests/manifests/testlib.compat.json` records `testlib_noop` as
## `mismatch` across the WHOLE corpus (the same fixture
## `tcheck_manifest_mismatch_warning.nim` uses for its own, unrelated,
## warning check) — calling it from the probe body must be a macro error.
## Run by the nimble test task, which expects compilation to fail with
## wording conveying "the version probe may only call symbols with no
## known drift ranges".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "libtestlib.so":
  compatManifest "manifests/testlib.compat.json"
  proc testlib_noop() {.cdecl, header: "tests/testlib.h".}
  versionProbe:
    testlib_noop()
    "1.0.0"
