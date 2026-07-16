## RFC-0001 §B.5, slice B6a: a `compatManifest` argument shape softlink
## does not recognize (here: a non-string-literal path) must get its own
## directive-specific macro error, never the generic body-shape error.
## Run by the nimble test task, which expects compilation to fail with
## "unrecognized argument".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "libtestlib.so":
  compatManifest(42)
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
