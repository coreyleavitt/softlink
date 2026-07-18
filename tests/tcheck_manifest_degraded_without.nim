## RFC-0001 §B.5 check 9, slice B6a: absence control for
## `tcheck_manifest_degraded_with.nim` — the identical binding, no
## `compatManifest` directive at all. See that file's doc comment for the
## full rationale.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
