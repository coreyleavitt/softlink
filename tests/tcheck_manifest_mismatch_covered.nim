## Check 7 bound-covered mismatch fix (nim-z3 report, softlink-mismatch-
## warning-issue.md; CHECK7-WARNING.handoff.md): a symbol whose recorded
## `mismatch` interval is FULLY explained by a declared `{.until.}` bound
## must NOT get the unbounded-drift `warning()` ("recorded a 'mismatch'
## interval") -- `checkUntil` (Check 6b, run just above Check 7) already
## confirms the bound is consistent with the manifest, so the mismatch is
## the mechanism working as designed, not a surprise. `tests/manifests/
## testlib_until_covered.compat.json` records `testlib_add` as `verified`
## through 2.0.0 (exclusive) and `mismatch` from 2.0.0 onward -- exactly
## what declaring `until: "2.0.0"` predicts. Run by the nimble test task,
## which expects compilation to SUCCEED with a Hint containing
## "bound-covered mismatch" and NO "recorded a 'mismatch' interval" text.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  compatManifest "manifests/testlib_until_covered.compat.json"
  proc testlib_add(a: cint, b: cint): cint {.cdecl, until: "2.0.0",
    verifyWhen: "TESTLIB_VERSION < 99", header: "tests/testlib.h".}
