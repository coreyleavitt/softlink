## RFC 0011 S0a item 1: at most ONE `identBase` directive per `dynlib`
## block — mirrors `compatManifest`'s (`tests/tfail_manifest_dup_directive.nim`)
## and `versionMacros`'s (`tests/tfail_versionmacros_duplicate.nim`) own
## dup-guard, voiced the same way ("merge them"). Run by the nimble test
## task, which expects compilation to fail with "duplicate identBase
## directive".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  identBase "Testlib1"
  identBase "Testlib2"
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
