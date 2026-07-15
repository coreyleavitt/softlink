## Compile-must-FAIL test (RFC-0001 slice A3): a {.prototype.}-verified proc
## whose Nim signature disagrees with the vendored prototype must fail the
## C compile with softlink's own "signature mismatch" diagnostic — the same
## call-based _Static_assert chain header-verified procs get, just checked
## against the vendored `extern` declaration instead of an installed header.
##
## testlib_protoonly is `int testlib_protoonly(void)` (see testlib.c); it is
## deliberately absent from testlib.h so it can only be verified via
## {.prototype.}. Binding it here as returning cdouble is a signature
## mismatch the prototype-driven _Static_assert must catch.
##
## Run by the nimble test task, which expects "signature mismatch" in the
## compiler output. NOT compiled by the regular test suite.
import softlink

dynlib "libtestlib.so":
  proc testlib_protoonly(): cdouble
    {.cdecl, prototype: "int testlib_protoonly(void)".}
