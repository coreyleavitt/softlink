## RFC 0011 S0a item 3: the `{.prototype.}` name-match rule keys on the
## proc's EFFECTIVE C name (`symbol:`'s value when present, else the Nim
## name), not the Nim identifier itself. `protoAliasBad` renames to the
## real `testlib_add` C symbol via `symbol:`, but its own vendored
## prototype string names the NIM alias instead of the C symbol — this must
## be rejected exactly like a prototype naming any other wrong C symbol
## would be (see tests/tfail_prototype_mismatch.nim's sibling family), not
## silently accepted because it happens to match the Nim identifier.
##
## No `{.header.}` needed (prototype alone lifts the header requirement),
## so this is a pure Nim-level macro-expansion-time check with no C
## include-path dependency at all.
##
## Run by the nimble test task, which expects compilation to fail with
## "does not match the proc's C name 'testlib_add'".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  proc protoAliasBad(a: cint, b: cint): cint
    {.cdecl, symbol: "testlib_add",
      prototype: "int protoAliasBad(int a, int b)".}
