## RFC 0011 S0b, work item (i)(i): `trustedWrappers` + `versionProbe` in one
## block is a compile-time error — the probe contract converts a wrapper's
## raised SoftlinkError into a reported atProbeFailed attestation via
## try/except around the probe body's own wrapper calls, but a
## trustedWrappers block's wrappers are {.raises: [].} and can never raise
## for that except to catch. Run by the nimble test task, which expects
## compilation to fail with "trustedWrappers and versionProbe cannot both
## be declared".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  trustedWrappers
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
  versionProbe:
    "1." & $testlib_add(1, 0)
