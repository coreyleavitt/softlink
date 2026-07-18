## Compile-must-FAIL test for {.verifyWhen.}. Run by the nimble test task,
## which expects the C compile to fail with "signature mismatch": when the
## gate condition is TRUE, verification must run at full strength — the
## conditional wrapper must not weaken checking on systems whose headers
## are new enough.
##
## testlib_gated is declared `int testlib_gated(void)` in testlib.h; binding
## it as returning cdouble is a signature mismatch the gated _Static_assert
## must catch (TESTLIB_VERSION is 1, so the condition holds).
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  proc testlib_gated(): cdouble
    {.cdecl, verifyWhen: "TESTLIB_VERSION >= 1", header: "tests/testlib.h".}
