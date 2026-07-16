## RFC-0001 §B.5, slice B6a: a bare `compatManifest()` call with no path
## argument at all must get a directive-specific macro error, never the
## generic body-shape error. Run by the nimble test task, which expects
## compilation to fail with "requires a string literal manifest path".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "libtestlib.so":
  compatManifest()
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
