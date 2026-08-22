## RFC 0011 S0a item 6, contradiction-rule pin: the {.verifyWhen.} mirror of
## `tfail_noverify_block_until_no_header.nim` — a proc carrying
## {.verifyWhen.} with no {.header.}/{.prototype.} does NOT inherit the
## block-level noverify default either, for the identical reason (avoiding
## a misattributed "{.verifyWhen.} contradicts {.noverify.}" error). It
## keeps today's "must specify a header pragma" error instead.
##
## Run by the nimble test task, which expects compilation to fail with
## "must specify a header pragma".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  noverify: "block default reason"
  proc testlib_nv_vw(): cint {.cdecl, verifyWhen: "TESTLIB_VERSION >= 1".}
