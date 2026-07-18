## Compile-must-FAIL test (RFC-0001 slice A4): {.header.} and {.prototype.}
## disagree on testlib_add's return type — an unambiguous hard conflict
## (return-type difference) that both the C and C++ backend must reject.
##
## testlib.h declares `int testlib_add(int a, int b)`. Here the vendored
## prototype instead claims `double testlib_add(int a, int b)`. The Nim
## signature below is written to MATCH THE PROTOTYPE (cdouble return) —
## deliberately, so the only possible failure is the C-level declaration
## conflict between the header's `extern` (from #include) and the
## `{.prototype.}`-emitted `extern` (see `emitPrototypeDecl` in
## src/softlink.nim), not softlink's own call-based _Static_assert
## ("signature mismatch"), which never gets a chance to run: the second,
## conflicting `extern` declaration is rejected by the C/C++ compiler at
## the declaration itself (C11 6.7p4: incompatible redeclaration in the
## same scope is a mandatory diagnostic; the C++ backend hits the same
## because both externs are `extern "C"`-linked, so this is a genuine
## redeclaration conflict rather than a legal overload — see A.1's
## `extern "C"` rationale in emitPrototypeDecl).
##
## RED evidence (both backends, verified against ghcr.io/coreyleavitt/nim:2.2.10):
##   nim c:   error: conflicting types for 'testlib_add'; have 'double(int, int)'
##            note: previous declaration of 'testlib_add' with type 'int(int, int)'
##   nim cpp: error: conflicting declaration 'double testlib_add(int, int)'
##            note: previous declaration 'int testlib_add(int, int)'
## Both are the COMPILER's own diagnostic (not softlink's "signature
## mismatch" string), which is why the nimble test task asserts on EXIT
## CODE ONLY for this fixture — no grep of compiler wording is in the
## required path (portable to gcc/clang/g++/MSVC by construction).
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  proc testlib_add(a: cint, b: cint): cdouble
    {.cdecl, header: "tests/testlib.h",
      prototype: "double testlib_add(int a, int b)".}
