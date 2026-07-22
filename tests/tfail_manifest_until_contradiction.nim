## RFC-0002 §4.2/§6, slice B2: `{.until: "x.y.z".}` claims a symbol's
## currently-declared signature stays valid through that version (exclusive).
## `tests/manifests/testlib_until.compat.json` records `testlib_add` as
## `verified` through 2.0.0 (exclusive) and `mismatch` from 2.0.0 onward —
## claiming `until: "3.0.0"` is the dangerous over-claim (rule (a)): the
## corpus already shows drift at 2.0.0, well inside the declared window.
## This is a hard error with NO escape hatch, and the message must include
## the corrected upper bound (2.0.0). Run by the nimble test task, which
## expects compilation to fail with "corrected upper bound is until:
## \"2.0.0\"".
##
## RFC-0002 §4.1/§5/§6, slice D1: the proc below also needs a `{.verifyWhen.}`
## gate now that D1 requires one unconditionally — `TESTLIB_VERSION < 99` is
## trivially true and irrelevant to the manifest contradiction under test:
## `checkUntil`'s over-claim error (Check 6b, inside `applyCompatManifest`)
## fires from the manifest facts alone and must remain THIS fixture's
## failure reason, not D1's.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  compatManifest "manifests/testlib_until.compat.json"
  proc testlib_add(a: cint, b: cint): cint {.cdecl, until: "3.0.0",
    verifyWhen: "TESTLIB_VERSION < 99", header: "tests/testlib.h".}
