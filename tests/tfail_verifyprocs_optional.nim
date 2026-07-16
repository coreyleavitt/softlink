## Compile-must-FAIL test (code-review finding F4): `{.optional.}` on a
## `verifyProcs` proc must be rejected — `verifyProcs` has no runtime
## footprint (no `loadX`, no function pointers, nothing that could ever be
## "missing at runtime"), so "optional" is meaningless there, exactly like
## `{.noverify.}` (see tests/tfail_verifywhen_noverify.nim's sibling
## rejection) and unlike `dynlib`, where `{.optional.}` is a real, load-time
## escape hatch. Before this fixture, the rejection branch in
## src/softlink.nim's `parseProcPragmas` (the `ppmVerifyProcs` / `optional`
## arm) had zero test coverage — `tests/test_softlink.nim`'s
## "compile-time: verifyProcs rejects noverify and unknown pragmas" suite
## covered `noverify` and `varargs` only.
##
## Uses `{.prototype.}` rather than `{.header.}` so this is a pure Nim-level
## macro-expansion-time check with no C include-path dependency at all
## (unlike a header-bound fixture, whose compile would ALSO fail — for an
## unrelated, incidental reason — if this pragma-rejection regressed AND no
## `-I` were passed; that would make a sabotage test's "catch" accidental
## rather than a clean, direct proof of this one diagnostic).
##
## Run by the nimble test task, which expects compilation to fail with the
## exact wording "verifyProcs does not support pragma 'optional'".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

verifyProcs:
  proc vp_optional_fail(): cint {.cdecl, optional, prototype: "int vp_optional_fail(void)".}
