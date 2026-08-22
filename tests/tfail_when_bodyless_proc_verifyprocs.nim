## RFC 0011 (softlink-authored diagnostic for conditional binding
## declarations), the `verifyProcs` leg: `verifyProcs` has no statement
## pass-through at all (`collectVProcs` rejects any non-`nnkProcDef`
## statement outright, `compatManifest`/`versionMacros` directives
## excepted) — so a `when` there, hiding a bodyless proc or not, already
## fails with the EXISTING generic "verifyProcs body must contain only
## proc declarations" error before the new dynlib-specific scan would ever
## be relevant. There is no blind spot to close here: `verifyProcs`'s
## narrower rule already catches this shape by construction. Run by the
## nimble test task, which expects the EXISTING generic error, NOT the new
## conditional-binding wording.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

verifyProcs:
  when defined(linux):
    proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
