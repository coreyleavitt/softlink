## RFC-0001 §B.5, slice B6a: at most ONE `compatManifest` directive per
## `dynlib`/`verifyProcs` block. A second directive must fail with a
## clear, softlink-authored merge-style error (voiced like the existing
## #14 dup-block guard), not a generic body-shape error. Run by the
## nimble test task, which expects compilation to fail with "duplicate
## compatManifest directive".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "libtestlib.so":
  compatManifest "manifests/testlib.compat.json"
  compatManifest "manifests/testlib.compat.json"
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
