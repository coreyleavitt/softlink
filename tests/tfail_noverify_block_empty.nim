## RFC 0011 S0a item 6: the block-level `noverify` directive's
## justification must be non-empty — unlike the per-proc {.noverify.}
## pragma (whose justification is optional), the block-level form has no
## bare spelling: an empty string is rejected with a directive-specific
## macro error. Run by the nimble test task, which expects compilation to
## fail with "block-level noverify's justification must be non-empty".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  noverify: ""
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
