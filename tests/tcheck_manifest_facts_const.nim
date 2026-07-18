## RFC-0001 §B.5/§9, slice B6b: with a manifest attached AND surviving the
## ABI check, `dynlib` embeds the manifest's per-symbol interval table
## verbatim as a module-level const `softlinkCompatFacts<Base>:
## seq[SymbolFacts]`, using the pinned B0 types (`FactKind`,
## `VersionInterval`, `SymbolFacts` from `softlink/versions`) — Stage C's
## load-time contract, inspectable at compile time NOW even though nothing
## reads it at runtime yet (that's Stage C, out of scope here).
##
## `tests/manifests/testlib.tmpl.json` records, in this exact order:
## `testlib_add` verified (one unbounded interval) and `testlib_noop`
## mismatch (one unbounded interval) — the const must reproduce both
## entries VERBATIM, in that same order, regardless of which symbols this
## block actually binds (only `testlib_add` is bound here; `testlib_noop`
## still appears in the const, because the const mirrors the MANIFEST, not
## the block's own proc list).
##
## `tests/manifests/testlib.compat.json`'s `harvest.abi` is rewritten
## in-place by the nimble task (per-OS-leg-correct) immediately before
## this file is compiled — see `writeManifestFromTemplate`
## in softlink.nimble.
##
## Run by the nimble test task via `runManifestChecks()`; a `static:`
## assert failure here would itself fail the compile, so
## `expectManifestCompileOk` succeeding IS the test passing.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  compatManifest "manifests/testlib.compat.json"
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}

static:
  doAssert softlinkCompatFactsTestlib.len == 2

  doAssert softlinkCompatFactsTestlib[0].cname == "testlib_add"
  doAssert softlinkCompatFactsTestlib[0].header[fkVerified].len == 1
  doAssert softlinkCompatFactsTestlib[0].header[fkVerified][0].lo == ""
  doAssert softlinkCompatFactsTestlib[0].header[fkVerified][0].hi == ""
  doAssert softlinkCompatFactsTestlib[0].header[fkMismatch].len == 0

  doAssert softlinkCompatFactsTestlib[1].cname == "testlib_noop"
  doAssert softlinkCompatFactsTestlib[1].header[fkMismatch].len == 1
  doAssert softlinkCompatFactsTestlib[1].header[fkVerified].len == 0
