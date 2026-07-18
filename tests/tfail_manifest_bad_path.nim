## RFC-0001 §B.5, slice B6a: a `compatManifest` path that doesn't resolve
## to a real file must be a clear macro error naming the resolved
## ABSOLUTE path (design guidance: resolve via the invoking module's
## directory, then check existence before `staticRead`), never a raw
## `staticRead` I/O error. Run by the nimble test task, which expects
## compilation to fail with "manifest file not found".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  compatManifest "manifests/does_not_exist.compat.json"
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
