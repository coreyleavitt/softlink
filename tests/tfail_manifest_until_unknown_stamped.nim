## RFC-0003 §2/§7 slice C1: the STAMPED control for `tfail_manifest_until_
## unknown.nim`'s ground-truth breadcrumb proof. Identical contradiction
## shape (rule (b′): `testlib_add` recorded `unknown` at/above the declared
## `until`, "no decisive classification"), against a manifest identical to
## `tests/manifests/testlib_until_unknown.tmpl.json` EXCEPT it carries
## `"harvesterVersion": "0.10.0"` in its `harvest` object.
##
## The point of this fixture is what it must NOT say: the §2 breadcrumb
## ("this manifest predates softlink's ground-truth harvest fix") must be
## ABSENT here, proving absence-of-the-field is the SOLE trigger (§2/§8
## resolution 2) — not, say, "any until-contradiction gets the breadcrumb"
## or some other broader condition. Run by the nimble test task, which
## expects compilation to fail with "no decisive classification" but WITHOUT
## "predates softlink's ground-truth harvest fix" anywhere in the output.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  compatManifest "manifests/testlib_until_unknown_stamped.compat.json"
  proc testlib_add(a: cint, b: cint): cint {.cdecl, until: "2.0.0",
    verifyWhen: "TESTLIB_VERSION < 99", header: "tests/testlib.h".}
