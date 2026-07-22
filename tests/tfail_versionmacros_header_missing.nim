## RFC-0002 `versionMacros(header = ...)` extension: the Z3-shaped
## negative control this feature fixes — same proc/header shape as
## tests/tverify_synthesized_gate_header.nim, but with NO `header =`
## argument. tests/testlib_bare.h deliberately does not define or include
## TESTLIB_VERSION, so the `#ifndef`/`#error` visibility guard
## (`softlink/verify.emitVersionMacroGuards`) fires for real — proving the
## macro genuinely isn't in scope without the `header =` fix (this is
## exactly what breaks for Z3: z3.h does not include z3_version.h; users
## would otherwise have to hand-roll a bridge header + -I flag). Run by the
## nimble test task WITHOUT `--compileOnly` (a real C-level `#error`, same
## reasoning as tests/tfail_versionmacros_undefined_macro.nim's own doc
## comment), expecting the guard's exact wording naming TESTLIB_VERSION.
##
## This fixture requires NO source change to fail correctly — it pins the
## PRE-EXISTING `#ifndef`/`#error` guard behavior (RFC-0002 §4.5/§6, slice
## E2), which stays unconditionally in force; `header = ...` only ADDS a
## way to get the macro in scope, it never bypasses the guard.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

verifyProcs:
  versionMacros("TESTLIB_VERSION")
  proc testlib_bare_drifted(a: ptr cint): cint
    {.cdecl, until: "2", header: "tests/testlib_bare.h".}
