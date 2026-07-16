## RFC-0001 §B.5a, slice B6a: the since-contradiction check is part of
## `verifyProcs`'s compile-time subset too. `tests/manifests/
## testlib_vp_since.compat.json` records `testlib_add` as `absent`
## through 2.0.0 (exclusive) and `verified` from 2.0.0 onward; claiming
## `since: "1.0.0"` contradicts that. Run by the nimble test task, which
## expects compilation to fail with "corrected lower bound is 2.0.0".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

verifyProcs:
  compatManifest "manifests/testlib_vp_since.compat.json"
  proc testlib_add(a: cint, b: cint): cint {.cdecl, since: "1.0.0", header: "tests/testlib.h".}
