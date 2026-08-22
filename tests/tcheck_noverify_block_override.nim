## RFC 0011 S0a item 6: override/coexistence — a block-level noverify
## default coexists with procs that specify their OWN verification source.
## `testlib_add` keeps its real {.header.} verification (the default only
## fills a GAP; it never overrides an explicit source); `testlib_nv_own`
## keeps its OWN {.noverify: "..."} justification (never overwritten by the
## block's); `testlib_nv_gap` carries none of the three and inherits the
## block default.
##
## Run by the nimble test task, which expects this compile to SUCCEED.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  noverify: "block default reason"
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
  proc testlib_nv_own(): cint {.cdecl, noverify: "own reason, not the block's".}
  proc testlib_nv_gap(): cint {.cdecl.}
