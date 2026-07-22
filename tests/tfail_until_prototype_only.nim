## Compile-must-FAIL test: {.until.} on a prototype-only proc (no {.header.})
## is rejected — RFC-0002 §4.1: a `{.prototype.}`-only symbol verifies
## against a vendored, corpus-INVARIANT declaration that never varies by
## installed headers (`isCorpusTrackable`, `softlink/versions.nim`), so it
## has no per-version facts to harvest or compare and a declared `until` is
## unfalsifiable. `{.prototype.}` + `{.header.}` TOGETHER (cross-check mode)
## remains accepted — see the `testlib_add` positive control in
## `test_softlink.nim` (dynlib block), which now also carries `until`. Run
## by the nimble test task, which expects the "not corpus-trackable" error.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "libfoo.so":
  proc foo(x: cint): cint
    {.cdecl, prototype: "int foo(int x)", until: "2.0.0".}
