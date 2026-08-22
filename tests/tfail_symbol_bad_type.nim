## RFC 0011 S0a item 3: `{.symbol: <value>.}` requires a string literal —
## an integer (or any other non-string-literal shape) is rejected with a
## softlink-authored error, mirroring `since`/`until`'s own value-shape
## checks. Uses `{.noverify.}` so this is a pure Nim-level macro-expansion-
## time check with no C include-path dependency at all.
##
## Run by the nimble test task, which expects compilation to fail with
## "symbol pragma requires a non-empty C identifier string literal".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  proc symBadType(): cint {.cdecl, noverify, symbol: 123.}
