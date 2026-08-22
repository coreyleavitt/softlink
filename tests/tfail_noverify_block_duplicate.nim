## RFC 0011 S0a item 6: at most ONE block-level `noverify: "..."` directive
## per `dynlib` block — mirrors `identBase`'s
## (`tests/tfail_identbase_duplicate.nim`) and `versionMacros`'s
## (`tests/tfail_versionmacros_duplicate.nim`) own dup-guard, voiced the
## same way ("merge them"). Run by the nimble test task, which expects
## compilation to fail with "duplicate block-level noverify directive".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  noverify: "reason one"
  noverify: "reason two"
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
