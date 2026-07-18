## RFC-0001 §B.3/§B.5, slice B6a: a manifest with a newer, unsupported
## `schema` value must be a compile error naming the softlink version's
## supported schema — never a silent partial read. `tests/manifests/
## testlib_schema2.compat.json` has `"schema": 2`; this softlink only
## supports schema 1. Run by the nimble test task, which expects
## compilation to fail with "only supports schema 1".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  compatManifest "manifests/testlib_schema2.compat.json"
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
