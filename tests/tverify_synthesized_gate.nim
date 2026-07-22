## RFC-0002 §5/§6, slice E2: the SYNTHESIZED-gate sibling of
## `tests/tverify_gated_drift.nim` (slice C3a) — same dual-header proof
## (a TRUE `{.verifyWhen.}` gate branch genuinely type-checks against a
## DIFFERENT real C declaration, not merely an absent one), but here the
## gate itself is never hand-written: `versionMacros("TESTLIB_VERSION")` +
## `{.until: "2".}` with NO `{.verifyWhen.}` at all synthesizes
## `"(TESTLIB_VERSION < 2)"` (a single macro, single component, no
## trailing-zero stripping to do — see `softlink/gates`'s own golden
## tests for the general algorithm) — textually identical to the hand
## gate `tests/tverify_gated_drift.nim` writes by hand for the same
## header shape.
##
## Reuses `tests/testlib.h`'s `testlib_drifted` (`#if TESTLIB_VERSION >= 2`:
## `int *sgn` below 2, `double *sgn` at/above) — the same genuinely-drifted
## declaration slice C3a's fixture verifies, so this fixture inherits its
## RED evidence (a deliberately wrong parameter type under a true gate
## fails the real C compile — verified by hand there; re-verifying it here
## would be redundant since the C-level checking machinery is identical,
## only the gate's ORIGIN differs).
##
## `verifyProcs`, not `dynlib`, for the same collision reason
## `tverify_gated_drift.nim`'s own doc comment gives (no per-block-prefixed
## Nim-level accessor collision).
##
## The nimble test task compiles this file TWICE, in distinct --nimcache
## dirs (same isolation precedent as `runGatedDriftChecks`; a `-D` flag
## changes no Nim-emitted C, so a shared nimcache risks a vacuous pass):
##   - default (TESTLIB_VERSION=1, the header's own `#ifndef` default): the
##     synthesized gate (`TESTLIB_VERSION < 2`) is TRUE and the header's
##     real `int *`-param declaration is genuinely type-checked.
##   - `--passC:-DTESTLIB_VERSION=2`: the gate is FALSE and the declaration
##     is absent from this build — must still compile clean (nothing is
##     checked, and nothing SHOULD be: the synthesized gate correctly
##     closed against a header whose declared shape no longer matches this
##     proc's `ptr cint`).
## Both invocations must compile clean — this is the "opens and closes
## correctly against real headers" proof RFC-0002 §6/§8 asks for.
##
## RED evidence (RFC-0002 §6 E2, captured before `synthesizeVersionGates`
## existed): with no gate-synthesis consumer wired up, `versionMacrosDirective`
## was parsed and stored but never touched `p.verifyWhen` — this exact
## fixture (until-bounded, no hand verifyWhen) failed
## `checkUntilRequiresGate`'s D1 check with "requires a {.verifyWhen.}
## gate", proving synthesis (not some other mechanism) is what makes this
## fixture compile. Re-verified by hand by temporarily reverting the
## `synthesizeVersionGates` call sites in `src/softlink.nim`.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

verifyProcs:
  versionMacros("TESTLIB_VERSION")
  proc testlib_drifted(a: ptr cint): cint
    {.cdecl, until: "2", header: "tests/testlib.h".}
