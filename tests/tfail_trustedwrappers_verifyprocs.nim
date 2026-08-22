## RFC 0011 S0b, work item (i)(j): `verifyProcs` generates no wrappers at
## all (RFC-0001 §B.5a's documented ceiling — "no loadX, no pointers, no
## wrappers"), so `trustedWrappers` has nothing to apply to there — rejected
## outright, mirroring `versionProbe`'s own rejection in verifyProcs. Run by
## the nimble test task, which expects compilation to fail with
## "trustedWrappers has no meaning in verifyProcs".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

verifyProcs:
  trustedWrappers
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
