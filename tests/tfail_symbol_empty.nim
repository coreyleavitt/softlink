## RFC 0011 S0a item 3: `{.symbol: "".}` — an empty string literal — is
## rejected the same way an empty `{.noverify: "".}`/`{.since: "".}` value
## would be: a rename to nothing is not a rename. Uses `{.noverify.}` so
## this is a pure Nim-level macro-expansion-time check with no C
## include-path dependency at all.
##
## Run by the nimble test task, which expects compilation to fail with
## "symbol pragma requires a non-empty C identifier string literal".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  proc symEmpty(): cint {.cdecl, noverify, symbol: "".}
