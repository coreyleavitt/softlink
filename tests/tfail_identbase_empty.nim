## RFC 0011 S0a item 1: `identBase`'s argument must be non-empty — an
## empty string literal is a directive-specific macro error, mirroring
## `compatManifest`'s own empty-path rejection
## (RFC-0001 §B.5's "manifest path must be non-empty"). Run by the nimble
## test task, which expects compilation to fail with "identBase's argument
## must be non-empty".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  identBase ""
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
