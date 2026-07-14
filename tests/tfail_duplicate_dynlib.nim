## Compile-must-FAIL test for #14 (Defect A). Run by the nimble test task,
## which expects compilation to fail with the clear duplicate-block error
## ("collides with an earlier dynlib block") — NOT the opaque
## "redefinition of 'softlinkHandleFoo'" that leaked from softlink.nim
## before the declared()-guard existed.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "libfoo.so":
  proc foo(x: cint): cint {.cdecl, noverify.}

# A *different* pattern string that derives the same ident base "Foo" —
# varying the pattern is no escape (libNameToIdent collapses them), so the
# guard must reject this exactly like a verbatim duplicate.
dynlib "foo":
  proc bar(x: cint): cint {.cdecl, noverify.}
