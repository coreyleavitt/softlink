## RFC-0002 §6, slice C3a: the dual-header compile test — the suite's first
## fixture proving a TRUE {.verifyWhen.} gate branch actually type-checks
## against a genuinely DIFFERENT C declaration, not merely an absent one.
## Contrast `testlib_gated_v2` (tests/test_softlink.nim): its false-gate
## branch has no declaration at all to check against, so it never proves
## the true-gate branch is checking real, drifted content.
##
## `tests/testlib.h`'s `testlib_drifted` is gated on `TESTLIB_VERSION`
## (`#if TESTLIB_VERSION >= 2 ... #else ... #endif`): the pre-2 shape takes
## `int *`; the >=2 shape takes `double *` — mirroring the RFC's own
## motivating drift (`Z3_fpa_get_numeral_sign`'s `int *sgn` -> `bool *sgn`)
## exactly, down to it being a POINTER parameter change. See testlib.h's
## own comment on why the drift must be a pointer type, not a scalar one
## (a scalar mismatch is silently converted at the call site — invisible
## to softlink's call-based assert, verified by hand).
##
## softlink has no `{.importc: "...".}`-style C-name rename axis — the C
## symbol IS the Nim proc name (`probeFactsJson`'s doc comment,
## src/softlink.nim) — so "declaring the symbol twice" needs two separate
## blocks. `dynlib` is unusable here even across two DIFFERENT library
## patterns: every proc also gets a zero-arg `xxxPtr*(): proc type`
## accessor (`src/softlink.nim`, ~line 1343) named ONLY from `p.nameStr`
## (no per-block prefix), so two dynlib blocks both binding
## `testlib_drifted` collide on `testlib_driftedPtr` — Nim reports
## "overloaded 'testlib_driftedPtr' leads to ambiguous calls" even when the
## two blocks' `testlib_drifted` signatures themselves differ enough to be
## legal overloads (verified by hand). `verifyProcs` has no such
## accessor — it emits nothing Nim-level for a proc beyond the shared
## compile-time verify chain — so it's the collision-free shape, PROVIDED
## the two blocks' generated C verify-proc names (keyed off `tag`, the
## block's FIRST proc's name — see verifyProcs' own doc comment: "two
## blocks sharing a tag would already collide") differ. The second block
## below therefore leads with `testlib_add` (a real, always-valid,
## ungated header symbol already used elsewhere in this suite) purely as a
## tag-differentiator — it carries no drift story of its own.
##
## The nimble test task compiles this file TWICE, in distinct --nimcache
## dirs (a `-D` flag changes no Nim-emitted C, so a shared nimcache would
## let Nim's content hash reuse the first invocation's object file and the
## second invocation would "pass" without recompiling anything at all —
## precedent for the isolation this guards against: `runProbeOnlyChecks`'
## per-define --nimcache dirs in softlink.nimble):
##   - default (TESTLIB_VERSION=1, the header's own `#ifndef` default):
##     the first block's gate (`TESTLIB_VERSION < 2`) is TRUE and the
##     header's real `int *`-param declaration is genuinely type-checked;
##     the second block's `testlib_drifted` gate is FALSE and its
##     declaration is absent from this build, so nothing is checked there
##     (must still compile clean).
##   - `--passC:-DTESTLIB_VERSION=2`: the reverse — the second block's gate
##     opens against the header's now-`double *`-param declaration; the
##     first block's gate closes, and its declaration is now absent.
## Both invocations must compile clean.
##
## RED evidence (captured by hand, reverted before this fixture landed):
## binding the first block's `testlib_drifted` as `(a: ptr cdouble): cint`
## (the WRONG parameter type — the real header, under the default
## TESTLIB_VERSION=1 this gate is true for, declares `int *sgn`) failed
## the C compile with "error: passing argument 1 of 'testlib_drifted' from
## incompatible pointer type" (a hard gcc error, not merely a warning) AND
## softlink's own "softlink: testlib_drifted signature mismatch vs
## tests/testlib.h" `_Static_assert`, proving the true-gate branch
## actually type-checks against the real, present declaration rather than
## silently passing. Restored to the correct `ptr cint` shape below.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

verifyProcs:
  proc testlib_drifted(a: ptr cint): cint
    {.cdecl, verifyWhen: "TESTLIB_VERSION < 2", header: "tests/testlib.h".}

verifyProcs:
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
  proc testlib_drifted(a: ptr cdouble): cint
    {.cdecl, verifyWhen: "TESTLIB_VERSION >= 2", header: "tests/testlib.h".}
