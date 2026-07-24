## RFC-0003 §4.1: `-d:softlinkProbeGroundTruth` set without
## `-d:softlinkHarvestSession` is a loud macro-expansion-time error —
## `softlinkProbeGroundTruth` exists ONLY for softlink's own harvester (it
## defeats every `since`/`until`/`verifyWhen` gate and vendored
## `{.prototype.}` declaration a probe compile carries, measuring header
## ground truth instead of "does this binding compile"), and the harvester
## always sets `-d:softlinkHarvestSession` alongside it — the fast-path
## whole-module compile (groundTruth set, no `softlinkProbeOnly` at all) is
## otherwise macro-indistinguishable from a stray hand-set define, which is
## why `softlinkHarvestSession` exists as the misuse guard's own signal
## (RFC-0003 §4.1).
##
## Mirrors `tests/tfail_probe_existence_no_target.nim`'s shape: a single
## plain, header-verified proc is enough to reach `genVerifyBlock`'s
## probe-mode validation (an empty `procs` list would short-circuit before
## ever reaching it).
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  proc testlib_noop() {.cdecl, header: "tests/testlib.h".}
