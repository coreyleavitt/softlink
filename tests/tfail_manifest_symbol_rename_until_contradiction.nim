## RFC 0011 S0a item 3: the `checkUntil` mirror of
## tests/tfail_manifest_symbol_rename_since_contradiction.nim — same
## rationale, `checkUntil`'s own `findSymbol` lookup (Check 6b) must key on
## the C symbol, never the Nim name.
##
## Reuses `tests/manifests/testlib_until.tmpl.json` verbatim — the SAME
## manifest tests/tfail_manifest_until_contradiction.nim exercises (it
## records `testlib_add` as `verified` through 2.0.0 and `mismatch` from
## 2.0.0 onward). `renamedUntilAlias` is a DIFFERENT Nim name for the exact
## same C symbol, over-claiming `until: "3.0.0"` — the identical
## over-claim contradiction, reached only via `symbol: "testlib_add"`. A
## regression back to the Nim name would make this compile SUCCESSFULLY
## instead of failing.
##
## `{.verifyWhen.}` is required unconditionally alongside `{.until.}`
## (RFC-0002 §4.1/§5/§6, slice D1) — `TESTLIB_VERSION < 99` is trivially
## true and irrelevant to the manifest contradiction under test.
##
## Run by the nimble test task, which expects compilation to fail with
## "corrected upper bound is until: \"2.0.0\"".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  compatManifest "manifests/testlib_until.compat.json"
  proc renamedUntilAlias(a: cint, b: cint): cint
    {.cdecl, until: "3.0.0", verifyWhen: "TESTLIB_VERSION < 99",
      header: "tests/testlib.h", symbol: "testlib_add".}
