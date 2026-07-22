## RFC-0002 `versionMacros(header = ...)` extension: `header = ...` may be
## given at most once per versionMacros(...) call — a second occurrence is
## a directive-specific macro error, mirroring versionMacros's own
## whole-directive duplicate guard (tests/tfail_versionmacros_duplicate.nim)
## one level down, at the single-argument grain. Run by the nimble test
## task, which expects compilation to fail naming the "more than once"
## restriction.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  versionMacros("TESTLIB_VERSION", header = "tests/testlib_gates_version.h",
    header = "tests/testlib_gates_version.h")
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
