## Code-review finding F3 (High): the version-probe static drift-call scan
## (`scanProbeBodyForDriftCalls` in src/softlink.nim) previously matched
## only a DIRECT call whose callee was a bare `nnkIdent` (`P(x)`) — the
## UFCS/dot-call form `x.P(...)` (AST `Call(DotExpr(x, P), ...)`) was never
## inspected, so a probe could dispatch a known-drifted symbol through
## trivial dot-syntax and slip past the scan entirely, defeating RFC-0001
## §C.1's "the probe must not be the drift" guarantee.
##
## `tests/manifests/testlib_probe_drift_ufcs.compat.json` (materialized from
## `testlib_probe_drift_ufcs.tmpl.json`) records `testlib_add` — a
## two-parameter symbol, chosen specifically so the UFCS form
## `x.testlib_add(b)` is genuinely valid, type-checking Nim, not merely
## syntax that happens to parse — as `mismatch` across the whole corpus.
## `x.testlib_add(b)` below is exactly the receiver-position call the fixed
## scan must catch. Before the fix this file COMPILED CLEAN (that was the
## bug); after the fix it must fail with the same "the version probe may
## only call symbols with no known drift ranges" wording
## `tests/tfail_probe_drift_call.nim` already pins for the bare-ident form.
##
## Run by the nimble test task (`--compileOnly`), which expects compilation
## to FAIL with that wording.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "libtestlib.so":
  compatManifest "manifests/testlib_probe_drift_ufcs.compat.json"
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
  versionProbe:
    let x: cint = 1
    discard x.testlib_add(2)
    "1.0.0"
