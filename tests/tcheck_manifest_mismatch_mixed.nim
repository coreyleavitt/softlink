## Check 7 bound-covered mismatch fix, partition proof (nim-z3 report,
## softlink-mismatch-warning-issue.md; CHECK7-WARNING.handoff.md): ONE
## `compatManifest` directive with two mismatched symbols -- `testlib_add`
## (declares `until: "2.0.0"`, mismatch begins exactly there: covered) and
## `testlib_noop` (no declared bound at all, mismatch across the whole
## corpus: uncovered) -- must partition the diagnostic: the WARNING names
## ONLY `testlib_noop`, the HINT names ONLY `testlib_add`. Reuses the same
## `tests/manifests/testlib_until_covered.compat.json` the mismatch-covered
## fixture above uses (it already records both symbols). Run by the
## nimble test task, which expects compilation to SUCCEED with both a
## Warning naming `testlib_noop` and a Hint naming `testlib_add`, neither
## message naming the other symbol.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  compatManifest "manifests/testlib_until_covered.compat.json"
  proc testlib_add(a: cint, b: cint): cint {.cdecl, until: "2.0.0",
    verifyWhen: "TESTLIB_VERSION < 99", header: "tests/testlib.h".}
  proc testlib_noop() {.cdecl, header: "tests/testlib.h".}
