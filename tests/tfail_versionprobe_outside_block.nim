## RFC-0001 §9/§C.1, slice C1b: `versionProbe` is a body directive of
## `dynlib` blocks. Writing it OUTSIDE one must resolve to softlink's
## exported erroring stub template (`{.error.}` pragma) and produce a
## softlink-authored diagnostic — never a raw "undeclared identifier" or a
## confusing "wrong number of arguments" (the #14 lesson, reapplied — same
## treatment as `tests/tfail_manifest_outside_block.nim` for
## `compatManifest`). Run by the nimble test task, which expects
## compilation to fail with "versionProbe is a body directive".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

versionProbe:
  "1.0"
