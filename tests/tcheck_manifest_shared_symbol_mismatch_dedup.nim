## Code-review finding M7: Check 7's "recorded a 'mismatch' interval"
## warning must count a single underlying C symbol ONCE, even when two Nim
## procs reach it through `{.symbol: "c_name".}` (RFC 0011 S0a item 3's
## headline use case — multiple fixed-arity Nim views of one C function).
## Before the fix, `applyCompatManifest`'s `trackable` list (softlink/
## directives.nim) held one entry PER PROC rather than per distinct C name,
## so `mismatchedSymbols` (softlink/manifest.nim) reported `testlib_add`
## TWICE — "2 symbols recorded a 'mismatch' interval: testlib_add,
## testlib_add" — for a manifest that records exactly one mismatched
## symbol.
##
## `sharedMismatchAddA`/`sharedMismatchAddB` are two independent Nim procs
## naming the same C symbol `testlib_add`, exactly like
## `tests/test_softlink.nim`'s "symbol rename pragma" suite's
## `renamedAdd`/`renamedAdd2` pair. `manifests/testlib_shared_symbol_
## mismatch.compat.json` (materialized from the `.tmpl.json` of the same
## name) records `testlib_add` with one corpus-wide `mismatch` interval.
##
## Run by the nimble test task, which expects compilation to SUCCEED and
## asserts the mismatch count names `testlib_add` exactly once — see
## `runManifestChecks`'s own assertions for this fixture.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  compatManifest "manifests/testlib_shared_symbol_mismatch.compat.json"
  proc sharedMismatchAddA(a: cint, b: cint): cint
    {.cdecl, header: "tests/testlib.h", symbol: "testlib_add".}
  proc sharedMismatchAddB(a: cint, b: cint): cint
    {.cdecl, header: "tests/testlib.h", symbol: "testlib_add".}
