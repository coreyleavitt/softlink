## RFC-0003 stage-4 review M7: the single source of truth for the C
## compiler diagnostics-severity pin flags every probe compile applies by
## default:
##
## - `-Werror=implicit-function-declaration` -- RFC-0001 SS4 B.2's guard
##   against silently misclassifying `absent` as `verified`.
## - `-Werror=incompatible-pointer-types` -- the RFC-0003 SS5.2(i)/B2a
##   pointer-parameter-drift pin that makes parameter-only drift a hard,
##   decisive verify failure.
##
## Deliberately dependency-free (imports nothing beyond this list) so BOTH
## `harvester.nim` (the heavy, filesystem/process-capable harvest engine --
## `defaultHarvestOptions()`) and `harvest_cli.nim` (the light, I/O-free
## CLI flag-parsing module -- `defaultExtraFlags*`, unit-tested with zero
## subprocess access in `tests/tharvest_cli.nim`) can import it without
## `harvest_cli.nim` picking up `harvester.nim`'s heavier dependencies.
##
## Previously `harvest_cli.defaultExtraFlags` was a hand-copied literal of
## `defaultHarvestOptions().extraFlags`, kept in sync only by a byte-
## identity unit test -- a future edit to one side without the other would
## have silently drifted until that test happened to be run. This module
## makes that drift structurally impossible: both consumers derive their
## defaults from the one `seq` below instead of maintaining their own copy.
const
  defaultDiagnosticsPinFlags* = @[
    "--passC:-Werror=implicit-function-declaration",
    "--passC:-Werror=incompatible-pointer-types",
  ]
