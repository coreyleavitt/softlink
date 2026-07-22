## RFC-0002 §5/§6, slice E1: at most ONE `versionMacros` directive per
## `dynlib`/`verifyProcs` block, any position — mirrors slice B6a's
## `compatManifest` dup guard (`tests/tfail_manifest_dup_directive.nim`) and
## slice C1b's `versionProbe` dup guard
## (`tests/tfail_versionprobe_duplicate.nim`), voiced the same way
## (dup-block-guard style: "merge them"). Run by the nimble test task,
## which expects compilation to fail with "duplicate versionMacros
## directive".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  versionMacros("TESTLIB_MAJOR_VERSION")
  versionMacros("TESTLIB_MINOR_VERSION")
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
