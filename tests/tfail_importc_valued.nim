## RFC 0011 S0a item 3: the valued spelling `{.importc: "real_c_name".}` in
## a `dynlib` body must ALSO be rejected as an unrecognized pragma — see
## tests/tfail_importc_bare.nim's doc comment for the full rationale
## (softlink's rename axis is `symbol:`, never `importc`, bare or valued).
## Pinned as its own fixture, distinct from the bare form, because the two
## are parsed by different `NimNode` shapes (`nnkIdent` vs.
## `nnkExprColonExpr`) and `pragmaKeyName` must recognize BOTH as the same
## unrecognized name — a regression could plausibly fix one shape and miss
## the other.
##
## Run by the nimble test task, which expects compilation to fail with
## "dynlib does not support pragma 'importc'".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  proc icValued(): cint {.cdecl, noverify, importc: "real_c_name".}
