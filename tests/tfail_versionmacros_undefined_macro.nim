## RFC-0002 §4.5/§5/§6, slice E2: the negative half of the
## `#ifndef`/`#error` macro-visibility guard (`softlink/verify.
## emitVersionMacroGuards`) — `versionMacros("TESTLIB_NO_SUCH_MACRO")`
## names a macro `tests/testlib.h` never defines. Without the guard, the
## synthesized gate `"(TESTLIB_NO_SUCH_MACRO < 2)"` would silently
## evaluate as `(0 < 2)` — always true — under C's "undefined identifier
## in #if/#elif is replaced by 0" rule (§4.5), verifying this proc's
## declared signature unconditionally instead of failing loud. The guard
## makes that a hard, unmissable compile error instead.
##
## Unlike `tfail_versionmacros_alpha_bound.nim`/
## `tfail_versionmacros_excess_components.nim` (Nim MACRO-time errors,
## `error()`-raised during expansion, caught by `--compileOnly`), THIS
## fixture's failure is a genuine C PREPROCESSOR `#error` inside the
## generated verify TU — `--compileOnly` never invokes the C compiler at
## all (it only emits C), so the nimble test task compiles this fixture
## WITHOUT `--compileOnly`, expecting the real `nim c` invocation itself
## to fail with the guard's exact `#error` wording.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

verifyProcs:
  versionMacros("TESTLIB_NO_SUCH_MACRO")
  proc testlib_add(a: cint, b: cint): cint
    {.cdecl, until: "2", header: "tests/testlib.h".}
