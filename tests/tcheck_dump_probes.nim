## RFC-0001 §4 B.1: -d:softlinkDumpProbes=<dir> probe-facts dump fixture.
## Compiled --compileOnly by the nimble test task, once WITHOUT the define
## (must produce no dump directory at all — additive-only) and once WITH
## it pointed at a scratch dir; the task then validates the resulting
## <Base>.probes.json files against the schema (existence, valid JSON,
## required keys present, no unexpected extra keys) via a small Nim-side
## validator in softlink.nimble — OS-agnostic, so this one fixture (and one
## task-side check) covers all three CI branches identically, unlike the
## grep/findstr fixture checks elsewhere in this file.
##
## Exercises BOTH macros in one compile:
## - a `dynlib` block (base name "Dumpfoo"): a header-verified proc
##   (testlib_add), a prototype-only proc (testlib_protoonly), an optional
##   header-verified proc (testlib_future), and a noverify proc with a
##   justification (dumpfoo_private) — one proc per pragma-fact axis the
##   dump schema carries.
## - a `verifyProcs` block (base name "VerifyTestlib_noop" — see the
##   tag-reuse rationale on `dumpProbeFacts`'s call site in
##   src/softlink.nim): a single header-verified proc.
##
## All bindings reuse EXISTING testlib.h symbols/signatures/prototype
## strings already proven correct by test_softlink.nim's own fixtures
## (testlib_add, testlib_protoonly, testlib_future, testlib_noop) — this
## file's job is to exercise the DUMP, not to re-prove header verification
## itself.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "libdumpfoo.so":
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
  proc testlib_protoonly(): cint
    {.cdecl, prototype: "int testlib_protoonly(void)".}
  proc testlib_future(): cint {.cdecl, optional, header: "tests/testlib.h".}
  proc dumpfoo_private(): cint
    {.cdecl, noverify: "vendor-private, no public header".}

verifyProcs:
  proc testlib_noop() {.cdecl, header: "tests/testlib.h".}
