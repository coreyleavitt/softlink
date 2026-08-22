## RFC 0011 S0b, work item (i)(e): `trustedWrappers: ""` — a colon-block
## with an empty string justification — is rejected: unlike the bare form
## (which carries no justification and is legal), an explicitly-given but
## empty string is treated as author error, not a synonym for "no
## justification". Run by the nimble test task, which expects compilation
## to fail with "trustedWrappers's justification must be non-empty".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  trustedWrappers: ""
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
