## RFC 0011 S0b, work item (i): "at most one trustedWrappers per block, any
## position" — mirrors the identBase/noverify/versionMacros/compatManifest
## duplicate guards. Run by the nimble test task, which expects compilation
## to fail with "duplicate trustedWrappers directive".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  trustedWrappers: "first reason"
  trustedWrappers: "second reason"
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
