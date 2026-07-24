## RFC-0003 §7 A1: dedicated, minimal fixture for the NEW byte-identical
## generated-C golden-snapshot check (`runGoldenVerifyApparatusCheck` in
## `softlink.nimble`). Deliberately its own tiny header/proc
## (`tests/testlib_golden.h`), decoupled from `tests/testlib.h`'s own
## churn, so the golden snapshot only ever changes for a reason that
## actually touches `genVerifyBlock`'s emission (a Nim-version codegen
## shift, or a genuine `verify.nim` change) — never as a side effect of an
## unrelated `testlib.h` edit made for some other slice's fixture.
##
## One plain header-verified proc, no `{.verifyWhen.}`/`{.prototype.}` —
## the golden captures the ORDINARY (ungated, unprobed) emission shape;
## the ground-truth-specific gate/guard/prototype-suppression behaviors are
## proven separately, by `runGroundTruthChecks` reusing
## `tests/tcheck_probe_only.nim`/`tests/tverify_synthesized_gate.nim`
## (already-established fixtures, not this one).
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "libsoftlinkgolden.so":
  proc softlink_golden_add(a: cint, b: cint): cint
    {.cdecl, header: "tests/testlib_golden.h".}
