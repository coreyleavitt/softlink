## RFC 0011 S0a item 1: `identBase`'s argument is spliced by string
## concatenation into every generated identifier (`load<Base>`,
## `softlinkHandle<Base>`, ...), so it must itself be a syntactically valid
## Nim identifier — a hyphen (here, "gtk-4") is rejected with a
## directive-specific macro error rather than surfacing later as an opaque
## parse error in the macro's own generated code. Run by the nimble test
## task, which expects compilation to fail with "is not a valid Nim
## identifier".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  identBase "gtk-4"
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
