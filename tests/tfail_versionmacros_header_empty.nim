## RFC-0002 `versionMacros(header = ...)` extension: `header = ""` (an
## empty string) is rejected — mirrors compatManifest's own empty-path
## rejection (tests/tfail_manifest_bad_path.nim's sibling check in
## softlink.nimble) and this same directive's empty-macro-name-list guard.
## Run by the nimble test task, which expects compilation to fail naming
## the non-empty requirement.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  versionMacros("TESTLIB_VERSION", header = "")
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
