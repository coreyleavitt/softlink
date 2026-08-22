## RFC 0011 S0a item 3: bare `{.importc.}` in a `dynlib` body must be
## rejected as an ordinary unrecognized pragma — NOT treated as a rename
## axis. softlink's own rename pragma is spelled `symbol:` (see
## tests/test_softlink.nim's "symbol rename pragma" suite), deliberately
## NOT `importc`: that name belongs to a real Nim compiler pragma for an
## unrelated axis (the FFI import mechanism itself), and reusing it here —
## while making the bare form every Nim FFI author reflexively types a hard
## error — would be a false friend. `importc`, bare or valued (see the
## sibling tests/tfail_importc_valued.nim), is therefore simply an
## unrecognized pragma: the SAME generic "does not support pragma" error
## every other unknown pragma already gets, no special case.
##
## Uses `{.noverify.}` (no `{.header.}`) so this is a pure Nim-level
## macro-expansion-time check with no C include-path dependency at all.
##
## Run by the nimble test task, which expects compilation to fail with
## "dynlib does not support pragma 'importc'".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  proc icBare(): cint {.cdecl, noverify, importc.}
