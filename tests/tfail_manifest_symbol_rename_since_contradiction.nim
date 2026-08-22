## RFC 0011 S0a item 3: `checkSince` (softlink/manifest, invoked from
## `softlink/directives.applyCompatManifest`'s Check 6) must key its
## `findSymbol` lookup on the proc's C symbol (`symbol:`'s value), never
## the Nim name — a renamed Nim proc is otherwise invisible to the
## manifest entirely, and the contradiction check would vacuously pass
## instead of firing (see `checkSince`'s own doc comment: "no check is
## possible for a symbol entirely absent from the manifest").
##
## Reuses `tests/manifests/testlib_since.tmpl.json` verbatim — the SAME
## manifest tests/tfail_manifest_since_contradiction.nim exercises (it
## records `testlib_add` as `absent` through 2.0.0 and `verified` from
## 2.0.0 onward). `renamedSinceAlias` is a DIFFERENT Nim name for the exact
## same C symbol, claiming `since: "1.0.0"` — the identical contradiction,
## reached only if the lookup keys on `symbol: "testlib_add"` rather than
## on `renamedSinceAlias` (which the manifest has never heard of). If the
## lookup regressed to the Nim name, this fixture would compile
## SUCCESSFULLY instead of failing — the nimble task's
## `expectManifestCompileFail` catches that polarity flip directly.
##
## Run by the nimble test task, which expects compilation to fail with
## "corrected lower bound is 2.0.0" AND a mention of 'testlib_add' (the C
## symbol the manifest actually knows about, never 'renamedSinceAlias').
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  compatManifest "manifests/testlib_since.compat.json"
  proc renamedSinceAlias(a: cint, b: cint): cint
    {.cdecl, since: "1.0.0", header: "tests/testlib.h", symbol: "testlib_add".}
