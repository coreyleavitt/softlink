## RFC-0001 §4 B.2: the other half of the classification-table proof — an
## existence probe against a symbol the header genuinely does NOT declare
## must FAIL to compile (this is what lets the harvester classify `absent`).
##
## `testlib_totally_absent` names no symbol in tests/testlib.h. Bound here
## via {.header.} (required — no {.prototype.} escape hatch, so nothing
## else in this TU declares it), then probed in existence mode: the emitted
## `(void)sizeof(__typeof__(&testlib_totally_absent))` /
## `(void)sizeof(decltype(&testlib_totally_absent))` references an
## undeclared identifier, which C and C++ both reject as a hard error (this
## is "use of undeclared identifier", not the lenient old-C
## implicit-*function*-declaration case, which only applies to call
## expressions `f(...)`, never to `&f`) — so the compiler's own diagnostic
## wording is asserted on EXIT CODE ONLY via `expectCompileFailure`, exactly
## like RFC-0001 slice A4's prototype-conflict fixtures, rather than a
## grepped string (see softlink.nimble's `expectCompileFailure` doc comment).
##
## Run by the nimble test task under BOTH `nim c` and `nim cpp` (proving the
## discrimination holds under the GCC/Clang __typeof__ tier AND the C++
## decltype tier). NOT compiled by the regular test suite.
import softlink

dynlib "testlib":
  proc testlib_totally_absent(): cint {.cdecl, header: "tests/testlib.h".}
