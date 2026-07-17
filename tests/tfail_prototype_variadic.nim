## Compile-must-FAIL test (Finding #19.9 — code-review coverage gap): a
## {.prototype.} declaring a variadic ('...') C function must be rejected
## with softlink's OWN diagnostic wording, not merely "some compile
## failure fired." `analyzePrototype`'s classification of variadic
## prototypes is pinned by pure unit tests
## (tests/test_softlink.nim's "analyzer: variadic '...' detected anywhere
## in the prototype" test), and the rejection itself is proven by a
## `compiles()` check in the same file ("negative: variadic prototype
## rejected") — but `compiles()` can only observe pass/fail, never inspect
## the actual error MESSAGE text, so neither test pins the wording. This
## fixture, driven by the nimble test task via `gorgeEx` + a grep on the
## captured compiler stderr, closes that gap.
##
## Run by the nimble test task, which expects "prototype must not be
## variadic" in the compiler output.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "libfoo.so":
  proc foo(fmt: cstring): cint
    {.cdecl, prototype: "int foo(const char *fmt, ...)".}
