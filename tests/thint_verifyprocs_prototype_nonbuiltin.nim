## Compile-diagnostic test (RFC-0001 slice A8 — verifyProcs parity analog of
## slice A6's thint_prototype_nonbuiltin.nim): a {.prototype.}-only proc (no
## {.header.}) whose prototype references an identifier outside the C
## builtin-type allowlist (found via the shared A1 tokenizer) must emit a
## compile-time hint naming it in `verifyProcs` too — "this prototype may
## need `header:` to resolve <T>" — upgraded to a warning under
## -d:softlinkStrictVerify. The hint is emitted from the shared
## `parseProcPragmas` (mode-parameterized only in its macro-name prefix, e.g.
## "softlink: verifyProcs: proc ...' vs "softlink: dynlib: proc ..."), so
## this pins that verifyProcs actually reaches the same diagnostic, not just
## dynlib.
##
## Run by the nimble test task, which compiles this file with --compileOnly
## (macro-expansion-time diagnostics only; the fictitious C type below is
## never fed to a real C compiler) and greps the output for the hint text —
## plainly and with -d:softlinkStrictVerify.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

verifyProcs:
  proc softlink_a6_vp_needs_header(ctx: pointer): cint
    {.cdecl, prototype: "int softlink_a6_vp_needs_header(Foo_Context ctx)".}
