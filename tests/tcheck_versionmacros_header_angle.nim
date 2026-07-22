## RFC-0002 `versionMacros(header = ...)` extension: the angle-bracket
## form — `header = "<...>"` must emit `#include <...>`, mirroring the
## SAME quoted/angle convention every per-proc {.header.} pragma already
## follows (`softlink/verify.toIncludeDirective`). Compiled `--compileOnly`
## (no real C compiler invoked, so the angle-bracket path need not actually
## resolve via -I — see `expectInGenC`'s own doc comment in softlink.nimble
## for why this suite's "inspect the generated C" checks don't need a real
## compile); the nimble test task greps the generated .c for the exact
## `#include <tests/testlib_gates_version.h>` line.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

verifyProcs:
  versionMacros("TESTLIB_VERSION", header = "<tests/testlib_gates_version.h>")
  proc testlib_bare_drifted(a: ptr cint): cint
    {.cdecl, until: "2", header: "tests/testlib_bare.h".}
