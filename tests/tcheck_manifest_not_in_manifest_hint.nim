## RFC-0001 §B.5, slice B6a: a bound (header/prototype-verified) symbol
## entirely absent from the attached manifest's own symbol table must get
## a compile HINT — a stale manifest should be visible, not silently
## permissive. `tests/manifests/testlib.compat.json` never mentions
## `testlib_future`. Run by the nimble test task, which expects
## compilation to SUCCEED and its output to contain "not in compat
## manifest".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  compatManifest "manifests/testlib.compat.json"
  proc testlib_future(): cint {.cdecl, optional, header: "tests/testlib.h".}
