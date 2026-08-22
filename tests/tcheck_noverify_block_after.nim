## RFC 0011 S0a item 6: position independence — the block-level
## `noverify: "reason"` directive declared AFTER the procs it defaults.
## Directives are position-independent throughout softlink (`compatManifest`/
## `versionProbe`/`versionMacros`/`identBase` all work "any position"), and
## the block-level noverify default is no exception: the must-specify-a-
## verification-source check defers to a post-body-scan pass (mirrors
## `versionMacros`' gate-synthesis restructuring, `synthesizeVersionGates`)
## specifically so a directive declared here, after the procs it covers, is
## still visible by the time that check runs. Before that restructuring,
## this fixture failed with "must specify a header pragma" — this is the RED
## test that forced the deferral.
##
## Run by the nimble test task, which expects this compile to SUCCEED.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  proc testlib_nv_after_a(): cint {.cdecl.}
  proc testlib_nv_after_b(): cint {.cdecl.}
  noverify: "no public header for any of these symbols"
