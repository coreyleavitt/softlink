## RFC-0001 §9/§C.1, slice C1b: with NO `versionProbe` directive attached to
## a `dynlib` block, neither `softlinkProbedVersion<Base>` nor
## `softlinkProbeFailed<Base>` (nor the internal `softlinkLoadInProgress
## <Base>` reentrancy flag) is emitted at all — mirrors slice B6b's "no
## directive → no const" precedent for `softlinkCompatFacts<Base>`. Proven
## here via `declared()`, the same primitive slice B6b's own
## `tests/tcheck_manifest_facts_const_absent.nim` fixture (and the #14
## duplicate-block guard before it) already rely on for scope-accurate
## compile-time identifier checks.
##
## `{.noverify.}` on `foo`'s only proc keeps this fixture free of any
## `{.header.}`/manifest machinery — the point here is purely "no directive
## means no vars," independent of everything else this slice checks.
##
## Run by the nimble test task via `runVersionProbeChecks()`.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "libfoo.so":
  proc foo(x: cint): cint {.cdecl, noverify.}

static:
  doAssert not declared(softlinkProbedVersionFoo)
  doAssert not declared(softlinkProbeFailedFoo)
  doAssert not declared(softlinkLoadInProgressFoo)
