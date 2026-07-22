## RFC-0002 §4.2/§6, slice B1 + Finding R2-A: `checkUntil` rule (b) now
## requires a DECISIVE fact at or above a declared `until`, not merely "no
## `fkVerified`". `tests/manifests/testlib_until_unknown.compat.json` records
## `testlib_add` as `verified` through 2.0.0 (exclusive) and `unknown` from
## 2.0.0 onward — the corpus never actually confirms the signature drifted
## (or was dropped) at or above the declared bound, it simply couldn't be
## classified. Before the R2-A fix this passed vacuously (rule (b) only
## scanned for `fkVerified`); an attested probe landing on "2.0.0" would then
## sail through the runtime attested-path exemption, which trusts this check
## having validated the whole declared-invalid window — a drifted, name-
## stable lookalike could dispatch silently. This is a hard error with NO
## escape hatch, and the message must name the unclassified corpus version
## ("2.0.0") and explain that the bound cannot be trusted at attested
## versions. Run by the nimble test task, which expects compilation to fail
## with "no decisive classification".
##
## RFC-0002 §4.1/§5/§6, slice D1: the proc below also needs a `{.verifyWhen.}`
## gate now that D1 requires one unconditionally — `TESTLIB_VERSION < 99` is
## trivially true and irrelevant to the manifest contradiction under test:
## `checkUntil`'s new rule (b) sub-rule (Check 6, inside `applyCompatManifest`)
## fires from the manifest facts alone and must remain THIS fixture's
## failure reason, not D1's.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  compatManifest "manifests/testlib_until_unknown.compat.json"
  proc testlib_add(a: cint, b: cint): cint {.cdecl, until: "2.0.0",
    verifyWhen: "TESTLIB_VERSION < 99", header: "tests/testlib.h".}
