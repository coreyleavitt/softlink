## Compile-must-FAIL test (RFC-0001 slice A8 — verifyProcs parity analog of
## slice A3's tfail_prototype_mismatch.nim): a {.prototype.}-verified proc
## whose Nim signature disagrees with the vendored prototype must fail the
## C compile with softlink's own "signature mismatch" diagnostic in
## `verifyProcs` too — the RFC gives `dynlib` and `verifyProcs` the same
## shared `parseProcPragmas`/`genVerifyBlock` codepath (A0/A2), so this pins
## that parity isn't merely structural-by-luck but actually holds.
##
## testlib_protoonly is `int testlib_protoonly(void)` (see testlib.c); it is
## deliberately absent from testlib.h so it can only be verified via
## {.prototype.}. Binding it here (through verifyProcs, not dynlib) as
## returning cdouble is a signature mismatch the prototype-driven
## _Static_assert must catch.
##
## Run by the nimble test task, which expects "signature mismatch" in the
## compiler output. NOT compiled by the regular test suite.
import softlink

verifyProcs:
  proc testlib_protoonly(): cdouble
    {.cdecl, prototype: "int testlib_protoonly(void)".}
