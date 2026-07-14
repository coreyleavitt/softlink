## Compile-must-FAIL test: {.verifyWhen.} and {.noverify.} on the same proc
## are contradictory — one requests conditional verification, the other
## requests none. The macro must reject the combination loudly rather than
## letting one silently win. Run by the nimble test task, which expects the
## "contradicts" error.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "libfoo.so":
  proc foo(x: cint): cint
    {.cdecl, noverify, verifyWhen: "FOO_VERSION >= 2".}
