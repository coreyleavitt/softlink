## RFC-0001 §9/§C.1, slice C1b: an empty-parens `versionProbe()` (no block)
## inside a `dynlib` block must get the SAME directive-specific malformed-
## shape error as bare `versionProbe` (`tests/tfail_versionprobe_bare.nim`)
## — never the generic "body must contain only proc declarations" error.
## Run by the nimble test task, which expects compilation to fail with
## "versionProbe requires a statement body".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
  versionProbe()
