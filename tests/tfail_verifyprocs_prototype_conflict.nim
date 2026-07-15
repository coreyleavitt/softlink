## Compile-must-FAIL test (RFC-0001 slice A8 — verifyProcs parity analog of
## slice A4's tfail_prototype_conflict.nim): {.header.} and {.prototype.}
## disagree on testlib_add's return type through `verifyProcs` instead of
## `dynlib` — an unambiguous hard conflict (return-type difference) that
## both the C and C++ backend must reject, exactly like the dynlib case,
## since both macros funnel into the same `genVerifyBlock`/`emitPrototypeDecl`
## codepath (A0/A2).
##
## testlib.h declares `int testlib_add(int a, int b)`. Here the vendored
## prototype instead claims `double testlib_add(int a, int b)`. The Nim
## signature below is written to MATCH THE PROTOTYPE (cdouble return) —
## deliberately, so the only possible failure is the C-level declaration
## conflict between the header's `extern` (from #include) and the
## `{.prototype.}`-emitted `extern`, not softlink's own call-based
## _Static_assert ("signature mismatch"), which never gets a chance to run.
##
## Like tfail_prototype_conflict.nim, the nimble test task asserts on EXIT
## CODE ONLY for this fixture (via `expectCompileFailure`) — no grep of
## compiler wording, portable to gcc/clang/g++/MSVC by construction.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

verifyProcs:
  proc testlib_add(a: cint, b: cint): cdouble
    {.cdecl, header: "tests/testlib.h",
      prototype: "double testlib_add(int a, int b)".}
