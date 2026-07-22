## RFC-0002 `versionMacros(header = ...)` extension: versionMacros(...)'s
## only supported NAMED argument is `header` — any other named argument
## (e.g. a typo like `hdr = ...`) is a directive-specific macro error,
## mirroring tests/tfail_versionmacros_malformed.nim's positional-argument
## checks one level up. Run by the nimble test task, which expects
## compilation to fail naming `header` as the only supported named
## argument.
##
## RED evidence: before this feature existed, ANY nnkExprEqExpr argument
## (named or not) fell through the pre-existing generic "arguments must be
## string literals" branch — this fixture's needle ("only supported named
## argument is 'header'") did not appear in that output at all (captured
## before implementation; see the softlink.nimble task's own comment).
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  versionMacros("TESTLIB_VERSION", hdr = "tests/testlib_gates_version.h")
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
