## RFC 0011 S0a item 1, judgment call (per the RFC's design guidance):
## `identBase` has no meaning in `verifyProcs` — there is no `loadX`/
## `unloadX`/wrapper surface for an identifier-base override to rename at
## all (`verifyProcs` derives its own internal, unexported tag from the
## first proc's name; nothing about that is user-facing). Rather than a
## dedicated rejection (as `versionProbe` gets in `verifyProcs` — "has no
## meaning"), `identBase` is simply never recognized by `collectVProcs`,
## so it falls straight into the existing generic body-shape error. Run by
## the nimble test task, which expects compilation to fail with
## "verifyProcs body must contain only proc declarations".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

verifyProcs:
  identBase "Foo"
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
