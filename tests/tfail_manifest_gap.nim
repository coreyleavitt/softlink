## RFC-0001 §B.3/§B.5, slice B6a: the disjoint/exhaustive interval
## invariant's other half — a corpus version covered by NONE of the four
## fact-interval sets is a gap, equally invalid. `tests/manifests/
## testlib_gap.compat.json` only records `testlib_add` as `verified`
## through 2.0.0 (exclusive), leaving 2.0.0 and 3.0.0 uncovered. Run by
## the nimble test task, which expects compilation to fail with "a gap".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "libtestlib.so":
  compatManifest "manifests/testlib_gap.compat.json"
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
