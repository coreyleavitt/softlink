## RFC 0011 S0a item 3: the positive control for the two
## tfail_manifest_symbol_rename_*_contradiction.nim fixtures — proves a
## renamed proc's manifest entry is FOUND under its C name (Check 8's
## "not in compat manifest" hint must NOT fire), even though the manifest
## has never heard of the Nim identifier `renamedFoundAlias`.
##
## Reuses `tests/manifests/testlib_since.tmpl.json` (`testlib_add` verified
## from 2.0.0 onward). Claiming `since: "2.0.0"` agrees with that fact, so
## `checkSince` does not contradict — but if the manifest lookup (both
## `checkSince` itself and the `trackable`/`notInManifest` Check 8 pass)
## regressed to keying on the Nim name, `renamedFoundAlias` would be
## classified "not in compat manifest" (a real symbol, `testlib_add`, IS in
## the manifest — just not findable under the wrong key), and the hint
## WOULD fire. The nimble task's `mustNotContain` catches that.
##
## Run by the nimble test task, which expects compilation to SUCCEED with
## no "not in compat manifest" hint.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  compatManifest "manifests/testlib_since.compat.json"
  proc renamedFoundAlias(a: cint, b: cint): cint
    {.cdecl, since: "2.0.0", header: "tests/testlib.h", symbol: "testlib_add".}
