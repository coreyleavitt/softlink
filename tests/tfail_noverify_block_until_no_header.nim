## RFC 0011 S0a item 6, contradiction-rule pin: a proc carrying {.until.}
## (one of the two noverify-CONTRADICTING pragmas, the other being
## {.verifyWhen.}) with no {.header.}/{.prototype.} does NOT inherit the
## block-level noverify default, even though it otherwise has no
## verification source of its own — inheriting it would trip the
## "{.until.} contradicts {.noverify.}" error for a proc that never wrote
## {.noverify.} itself, misattributing the mistake. It simply keeps
## today's pre-existing "must specify a header pragma" error instead (see
## `applyNoVerifyDefault`'s own doc comment, softlink/pragmas.nim, for the
## pinned rule).
##
## Run by the nimble test task, which expects compilation to fail with
## "must specify a header pragma".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  noverify: "block default reason"
  proc testlib_nv_until(): cint {.cdecl, until: "2.0.0".}
