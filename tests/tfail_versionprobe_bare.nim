## RFC-0001 §9/§C.1, slice C1b: a bare `versionProbe` (no colon, no block)
## inside a `dynlib` block must get a directive-specific macro error, NOT
## the generic "body must contain only proc declarations" error. Run by
## the nimble test task, which expects compilation to fail with
## "versionProbe requires a statement body".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "libtestlib.so":
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
  versionProbe
