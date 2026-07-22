## Compile-must-FAIL test: {.until.} and {.noverify.} on the same proc are
## contradictory — RFC-0002 §4.1: "until requires corpus-trackability"
## (`isCorpusTrackable = not noVerify and hasHeader`, `softlink/versions.nim`),
## and `{.noverify.}` skips verification entirely, so a declared upper bound
## on a noverify symbol is an unfalsifiable claim. Mirrors the existing
## verifyWhen + noverify / prototype + noverify contradictions. Run by the
## nimble test task, which expects the "contradicts" error.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "libfoo.so":
  proc foo(x: cint): cint
    {.cdecl, noverify, until: "2.0.0".}
