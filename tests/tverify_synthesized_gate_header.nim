## RFC-0002 `versionMacros(header = ...)` extension (the Z3 case): a
## synthesized `{.until.}` gate whose macro (TESTLIB_VERSION) is NOT
## defined or included by the verified proc's own {.header.} —
## tests/testlib_bare.h deliberately omits it, mirroring z3.h not
## including z3_version.h. `versionMacros("TESTLIB_VERSION", header =
## "tests/testlib_gates_version.h")` is the fix: the named header joins
## the block's #include list, so the macro is visible before the
## synthesized `#if` (and the `#ifndef`/`#error` visibility guard)
## evaluate — without it, this exact fixture would fail with the real C
## `#error` tests/tfail_versionmacros_header_missing.nim pins.
##
## RED evidence: before this feature existed, `header = ...` fell through
## the (then-)generic "arguments must be string literals" check — this
## exact fixture failed to compile with that message (hand-verified before
## implementation; see the softlink.nimble task's own comment for the
## captured text). See tests/tfail_versionmacros_header_missing.nim for the
## OTHER RED control: same shape, no `header =`, and the `#ifndef`/`#error`
## guard fires for real (TESTLIB_VERSION is genuinely undefined in that
## TU).
##
## `verifyProcs`, not `dynlib`, mirroring tests/tverify_synthesized_gate.nim
## (this fixture's un-headered sibling) for the same reason its own doc
## comment gives (no per-block-prefixed Nim-level accessor collision).
##
## The nimble test task compiles this TWICE, in distinct --nimcache dirs,
## the same dual-header proof as tests/tverify_synthesized_gate.nim:
##   - default (TESTLIB_VERSION=1, from tests/testlib_gates_version.h's own
##     #ifndef default): the synthesized gate (`TESTLIB_VERSION < 2`) is
##     TRUE and the header's real `int *`-param declaration is genuinely
##     type-checked.
##   - --passC:-DTESTLIB_VERSION=2: the gate is FALSE and the declaration is
##     absent from this build — must still compile clean.
## Both invocations must compile clean.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

verifyProcs:
  versionMacros("TESTLIB_VERSION", header = "tests/testlib_gates_version.h")
  proc testlib_bare_drifted(a: ptr cint): cint
    {.cdecl, until: "2", header: "tests/testlib_bare.h".}
