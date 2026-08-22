## RFC 0011 S0a item 6, judgment call (per the RFC's design guidance):
## the block-level `noverify` directive has no meaning in `verifyProcs` —
## per-proc {.noverify.} is already rejected there ("noverify is
## meaningless in verifyProcs"), and a whole-block default would be the
## same mistake at a larger scale. Rather than a dedicated rejection,
## `noverify: "..."` is simply never recognized by `collectVProcs`, so it
## falls straight into the existing generic body-shape error — the same
## treatment `identBase` gets there
## (`tests/tfail_identbase_verifyprocs.nim`). Run by the nimble test task,
## which expects compilation to fail with "verifyProcs body must contain
## only proc declarations".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

verifyProcs:
  noverify: "reason"
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
