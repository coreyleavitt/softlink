## RFC 0011 S0a item 3: `{.symbol: "123bad".}` — a non-empty string that is
## nonetheless not a syntactically valid C identifier (starts with a digit)
## — is rejected with a softlink-authored error. softlink splices this
## string as literal C text into both `symAddr` lookups and the call-based
## `_Static_assert` chain, so anything that isn't a plain identifier would
## either fail confusingly deep in generated C or "successfully" compile as
## something other than a symbol reference; this check turns that into a
## clear diagnostic at the pragma itself. Uses `{.noverify.}` so this is a
## pure Nim-level macro-expansion-time check with no C include-path
## dependency at all.
##
## Run by the nimble test task, which expects compilation to fail with
## "is not a valid C identifier".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  proc symBadIdent(): cint {.cdecl, noverify, symbol: "123bad".}
