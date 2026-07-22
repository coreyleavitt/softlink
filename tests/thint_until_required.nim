## Compile-diagnostic test: a dynlib block containing a required (non-
## {.optional.}) proc carrying {.until.} must emit a compile-time hint
## (upgraded to a warning under -d:softlinkStrictVerify) — RFC-0002 §4.1:
## required-symbol drift refusal unwinds the ENTIRE load, so a
## drifted-but-required symbol above `until` takes every other symbol in
## the block down with it, usually not what the author wants. Precedent:
## the per-block {.noverify.} hint (`thint_noverify.nim`). Run by the
## nimble test task, which compiles this file and greps the compiler
## output for "drifted-but-required" / "did you mean {.optional.}?" —
## plainly and with -d:softlinkStrictVerify.
##
## RFC-0002 §4.1/§5/§6, slice D1: this proc now also needs a
## `{.verifyWhen.}` gate — D1 requires one unconditionally, and this
## fixture's whole point is the A3 hint firing on a CLEAN compile (not D1's
## error), so `TESTLIB_VERSION < 99` (trivially true) is added purely to
## satisfy D1 without changing anything the hint checks below assert.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  proc testlib_add(a: cint, b: cint): cint
    {.cdecl, until: "99.0.0", verifyWhen: "TESTLIB_VERSION < 99",
      header: "tests/testlib.h".}
