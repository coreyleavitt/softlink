## C-inspection test: RFC-0001 §3 A.1 / slice A6 — a verifyProcs block whose
## procs are ALL prototype-only (no {.header.} anywhere in the block) must
## NOT emit the invalid `#include ""` a naive per-proc include-collection
## loop would produce for an empty `headerFile` (RFC-0001 §3 A.1's
## implementation note: "the verify TU's include-collection loop must skip
## empty headerFile entries (today it would emit an invalid #include \"\")").
## The nimble test task compiles this file with --compileOnly + a dedicated
## --nimcache dir (same technique as the protoEmitCheck fixture in
## test_softlink.nim) and inspects the generated C directly:
##   - it must contain no `#include ""` (see `expectNoEmptyInclude` in
##     softlink.nimble) — NOT a blanket "no #include substring anywhere"
##     check: every Nim-generated .c file unconditionally #includes its own
##     runtime headers (`nimbase.h` et al.), and `genVerifyBlock` itself
##     unconditionally emits one further fixed scaffolding line,
##     `#include <type_traits>` (guarded by `#if defined(__cplusplus)`),
##     needed by the C++ tier's const-stripping helper for ANY verified
##     proc, header-driven or not — neither is "a header this block asked
##     to verify against";
##   - it must still contain the vendored `extern` declaration for
##     softlink_a6_protoonly_check, proving verification actually ran (the
##     empty-include skip must not silently disable verification too).
## --compileOnly means the C compiler never actually runs, so the
## fictitious symbol name below need not exist anywhere real (identical
## reasoning to protoEmitCheck).
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

verifyProcs:
  proc softlink_a6_protoonly_check(a: cint, b: cint): cint
    {.cdecl, prototype: "int softlink_a6_protoonly_check(int a, int b)".}
