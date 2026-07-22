## RFC-0002 §4.1/§5/§6, slice D1: the positive control for
## `tfail_until_without_gate.nim` — `{.until.}` COEXISTING with a
## hand-written `{.verifyWhen.}` gate satisfies D1 and must compile clean.
## `TESTLIB_VERSION < 99` is true under the header's real (`#ifndef`)
## default of 1, so this is also a live, non-vacuous verification: the
## gate is open and the real signature is checked against `tests/testlib.h`.
##
## Run by the nimble test task, which expects this compile to SUCCEED.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  proc testlib_add(a: cint, b: cint): cint
    {.cdecl, until: "99.0.0", verifyWhen: "TESTLIB_VERSION < 99",
      header: "tests/testlib.h".}
