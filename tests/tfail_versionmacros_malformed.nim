## RFC-0002 §5/§6, slice E1: `versionMacros(...)` arguments must each be a
## string literal naming a valid C identifier ([A-Za-z_][A-Za-z0-9_]*) — a
## macro name that isn't a legal C identifier can never appear in an
## `#ifndef`/`#if` gate. This fixture pins the clearest malformed shape: a
## string literal whose value ("3BAD-MACRO") starts with a digit AND
## contains a hyphen, so it fails on the first character check. Run by the
## nimble test task, which expects compilation to fail with "is not a valid
## C identifier".
##
## Other rejected shapes verified ad hoc (not separately pinned as
## fixtures): a zero-argument call (`versionMacros()`) — "requires at
## least one macro name"; a non-string-literal argument
## (`versionMacros(FOO_MAJOR_VERSION)`, a bare identifier rather than a
## string) — "arguments must be string literals".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  versionMacros("3BAD-MACRO")
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
