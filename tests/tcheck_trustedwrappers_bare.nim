## RFC 0011 S0b, work item (i)(e): bare `trustedWrappers` (no justification)
## is legal — mirrors the per-proc `{.noverify.}` pragma's own optional-
## reason shape, unlike the block-level `noverify: "reason"` directive
## (whose justification is required). Run by the nimble test task, which
## expects this compile to SUCCEED.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  trustedWrappers
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
