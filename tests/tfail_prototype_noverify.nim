## Compile-must-FAIL test: {.prototype.} and {.noverify.} on the same proc
## are contradictory — both select a declaration source (RFC-0001 §3 A.1:
## "prototype + noverify -> error"), mirroring the existing verifyWhen +
## noverify contradiction. Run by the nimble test task, which expects the
## "contradicts" error.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "libfoo.so":
  proc foo(x: cint): cint
    {.cdecl, noverify, prototype: "int foo(int x)".}
