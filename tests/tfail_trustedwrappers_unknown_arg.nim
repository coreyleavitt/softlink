## RFC 0011 S0b, work item (i)(e): `trustedWrappers` accepts only bare
## `trustedWrappers` or `trustedWrappers: "justification"` — a positional
## call-argument shape (`trustedWrappers("x")`, ordinary parens, not the
## colon-block sugar) is an unrecognized argument shape and must be a
## directive-specific macro error, never the generic body-shape error.
## Run by the nimble test task, which expects compilation to fail with
## "trustedWrappers accepts either bare trustedWrappers or".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  trustedWrappers("private symbol")
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
