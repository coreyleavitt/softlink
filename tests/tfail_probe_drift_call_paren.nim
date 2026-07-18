## Code-review finding R2-1 (Medium, adversarially confirmed): the version-
## probe static drift-call scan (`scanProbeBodyForDriftCalls` in
## src/softlink.nim, helper `calleeIdentName`) previously matched a bare
## ident callee (`P(x)`) and a UFCS/dot-call callee (`x.P(...)`) — but a
## PARENTHESIZED callee, `(P)(x)`, bypassed the scan entirely:
## `(testlib_add)(2)` parses as `Call(Par(Ident "testlib_add"), IntLit 2)`,
## so `stmts[0]` is `nnkPar`, not `nnkDotExpr` nor a bare `nnkIdent`, and the
## existing unwrap/`calleeIdentName` logic returned "" for it, silently
## letting a known-drifted symbol be called directly from inside the
## version probe — exactly the corruption RFC-0001 §C.1 ("the probe must
## not be the drift") exists to prevent.
##
## `tests/manifests/testlib_probe_drift_ufcs.compat.json` (materialized from
## `testlib_probe_drift_ufcs.tmpl.json`, the SAME manifest the UFCS fixture
## `tfail_probe_drift_call_ufcs.nim` uses) records `testlib_add` — a
## two-parameter symbol — as `mismatch` across the whole corpus.
## `(testlib_add)(2)` below is exactly the paren-wrapped-callee call the
## fixed scan must catch. Before the fix this file COMPILED CLEAN (that was
## the bug); after the fix it must fail with the same "the version probe
## may only call symbols with no known drift ranges" wording
## `tests/tfail_probe_drift_call.nim` already pins for the bare-ident form.
##
## Run by the nimble test task (`--compileOnly`), which expects compilation
## to FAIL with that wording.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  compatManifest "manifests/testlib_probe_drift_ufcs.compat.json"
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
  versionProbe:
    discard (testlib_add)(1, 2)
    "1.0.0"
