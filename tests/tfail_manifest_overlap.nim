## RFC-0001 §B.3/§B.5, slice B6a: the disjoint/exhaustive interval
## invariant is VALIDATED at consumption time, not merely trusted.
## `tests/manifests/testlib_overlap.compat.json` hand-merges
## `testlib_add` into BOTH `verified` and `mismatch` across the whole
## corpus — an overlap. Run by the nimble test task, which expects
## compilation to fail with "an overlap".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  compatManifest "manifests/testlib_overlap.compat.json"
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
