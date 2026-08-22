## RFC 0011 S0a item 6: the block-level `noverify: "reason"` directive,
## declared BEFORE the procs it defaults — the straightforward ordering.
## Every bodyless proc below carries none of {.header.}/{.prototype.}/
## {.noverify.} and so inherits the block default, skipping compile-time
## header verification entirely — the same runtime mechanism as an
## explicit per-proc {.noverify.} (see `testlib_unheralded` in
## test_softlink.nim), just sourced from the block instead of the proc.
##
## Run by the nimble test task, which expects this compile to SUCCEED.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  noverify: "no public header for any of these symbols"
  proc testlib_nv_before_a(): cint {.cdecl.}
  proc testlib_nv_before_b(): cint {.cdecl.}
