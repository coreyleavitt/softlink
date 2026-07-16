## RFC-0001 §B.5, slice B6a: `compatManifest`'s `refuse` argument must be
## a bool literal — a string value must get a directive-specific macro
## error, never the generic body-shape error. Run by the nimble test
## task, which expects compilation to fail with "must be a bool literal".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "libtestlib.so":
  compatManifest("manifests/testlib.compat.json", refuse = "yes")
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
