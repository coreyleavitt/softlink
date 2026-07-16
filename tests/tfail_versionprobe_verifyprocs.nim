## RFC-0001 §9/§C.1, slice C1b, judgment call (not stated explicitly by the
## RFC — flagged in the C1b handoff report): `verifyProcs` has no library
## identity, no `loadX`, no runtime footprint at all, so there is no
## pipeline for a `versionProbe` to ever run inside. Rejected outright,
## analogous to how verifyProcs already rejects `noverify` ("meaningless…
## simply omit"). Run by the nimble test task, which expects compilation
## to fail with "versionProbe has no meaning in verifyProcs".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

verifyProcs:
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
  versionProbe:
    "1.0"
