## RFC 0011 S0b, work item (i)(e): the `trustedWrappers` compile-time audit
## hint — "N wrappers trusted (trustedWrappers), reason: ..." — enumerated
## once per block (block-level directive, uniform for every wrapper), same
## "trust points are visible" convention as the `{.noverify.}` hint. Run by
## the nimble test task, which compiles this file and greps the compiler
## output for the hint text, plainly and with -d:softlinkStrictVerify.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  trustedWrappers: "every symbol here is a stable, always-present export"
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
  proc testlib_noop() {.cdecl, header: "tests/testlib.h".}
