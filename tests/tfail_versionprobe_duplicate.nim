## RFC-0001 §9/§C.1, slice C1b: at most ONE `versionProbe` directive per
## `dynlib` block, any position — mirrors slice B6a's `compatManifest` dup
## guard (`tests/tfail_manifest_dup_directive.nim`), voiced the same way
## (dup-block-guard style: "merge the probes"). Run by the nimble test
## task, which expects compilation to fail with "duplicate versionProbe
## directive".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
  versionProbe:
    "1.0"
  versionProbe:
    "2.0"
