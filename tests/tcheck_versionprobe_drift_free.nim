## RFC-0001 §9/§C.1/§C.4b, positive counterpart to
## tests/tfail_probe_drift_call.nim: a versionProbe body directly calling
## a wrapper whose symbol carries NO `mismatch` interval in the attached
## manifest must compile fine — the static scan only rejects calls to
## symbols with a recorded drift range. `tests/manifests/testlib.compat.json`
## records `testlib_add` as `verified` across the whole corpus (no
## `mismatch` entry at all).
##
## Code-review finding F3 no-false-positive pin: the UFCS/dot-call form
## (`x.testlib_add(2)`, AST `Call(DotExpr(x, testlib_add), 2)`) of the same
## non-drift-ranged call must ALSO compile fine once the scan learns to
## recognize dot-call callees — extending the scan's reach must not turn
## every legitimate UFCS call into a false positive.
##
## Run by the nimble test task (`--compileOnly`), which expects
## compilation to SUCCEED.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  compatManifest "manifests/testlib.compat.json"
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
  versionProbe:
    let x: cint = 1
    discard x.testlib_add(2)
    $testlib_add(1, 2)
