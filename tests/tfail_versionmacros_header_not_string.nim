## RFC-0002 `versionMacros(header = ...)` extension: `header = ...`'s
## value must be a string literal — a bare non-string expression (here, an
## int literal) is a directive-specific macro error, mirroring
## tests/tfail_versionmacros_malformed.nim's positional-argument
## non-literal check. Run by the nimble test task, which expects
## compilation to fail naming the string-literal requirement.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  versionMacros("TESTLIB_VERSION", header = 42)
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
