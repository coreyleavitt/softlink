## RFC-0002 §5/§6, slice E2: gate synthesis bound validation — an
## alpha-run bound (a pre-release/suffixed version string like
## `"2.0.0-rc1"`) has no C macro a component like that could ever compare
## against, so `softlink/gates.synthesizeBoundPredicate` reports it as a
## `geAlphaRun` error and `softlink/pragmas.synthesizeVersionGates` turns
## that into this proc-anchored macro error. `until`-carrying, no explicit
## `{.verifyWhen.}` (so synthesis is actually attempted), one
## `versionMacros` macro declared. Run by the nimble test task, which
## expects compilation to fail naming the offending bound and explaining
## why (no C macro for an alphabetic run).
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  versionMacros("TESTLIB_VERSION")
  proc testlib_add(a: cint, b: cint): cint
    {.cdecl, until: "2.0.0-rc1", header: "tests/testlib.h".}
