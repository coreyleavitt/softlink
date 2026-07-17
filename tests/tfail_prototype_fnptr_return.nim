## Compile-must-FAIL test (Finding #19.9 — code-review coverage gap): a
## {.prototype.} whose return type is itself a function pointer (the name
## is nested inside the return type, e.g. `void (*signal(int))(int)`, and
## can't be extracted) must be rejected with softlink's OWN diagnostic
## wording, not merely "some compile failure fired." Same rationale as
## tests/tfail_prototype_variadic.nim's doc comment: the classification is
## already pinned by pure unit tests
## (tests/test_softlink.nim's "analyzer: function-pointer return type ..."
## tests) and the rejection by a `compiles()` check
## ("negative: function-pointer-return prototype rejected") — but
## `compiles()` can't inspect the error text, so the wording itself was
## never pinned anywhere until this fixture.
##
## Run by the nimble test task, which expects "prototype has a
## function-pointer return type" in the compiler output.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "libfoo.so":
  proc foo(sig: cint): cint
    {.cdecl, prototype: "void (*foo(int))(int)".}
