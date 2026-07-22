## RFC-0002 §5/§6, slice E2: gate synthesis bound validation — a bound with
## MORE components than the declared `versionMacros` list has no C macro
## for its extra, most-significant... no, LEAST-significant component(s):
## `until: "2.1.0"` has 3 components but only ONE macro
## (`TESTLIB_VERSION`) is declared, so silently truncating to just the
## first component would synthesize a gate that's wrong at exactly the
## boundary that matters (RFC-0002 §5). `softlink/gates.
## synthesizeBoundPredicate` reports this as a `geExcessComponents` error;
## `softlink/pragmas.synthesizeVersionGates` turns it into this
## proc-anchored macro error. Run by the nimble test task, which expects
## compilation to fail naming the component/macro counts.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  versionMacros("TESTLIB_VERSION")
  proc testlib_add(a: cint, b: cint): cint
    {.cdecl, until: "2.1.0", header: "tests/testlib.h".}
