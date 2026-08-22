## RFC 0011 S0a item 1: `identBase`'s argument must be a single string
## literal — a non-literal argument (here, an int literal) is a
## directive-specific macro error, never the generic body-shape error.
## Run by the nimble test task, which expects compilation to fail with
## "identBase requires exactly one string literal argument".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  identBase(42)
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
