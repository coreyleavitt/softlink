## Compile-diagnostic test: RFC-0001 §3 A.1 / slice A6 — a {.prototype.}-only
## proc (no {.header.}) whose prototype references an identifier outside
## the C builtin-type allowlist (found via the shared A1 tokenizer) must
## emit a compile-time hint naming it — "this prototype may need
## `header:` to resolve <T>" — upgraded to a warning under
## -d:softlinkStrictVerify, so the failure mode is a softlink diagnostic
## first and a raw C error second (RFC-0001 §3 A.1). The header-lift
## itself is NOT withdrawn — this proc still compiles; run by the nimble
## test task, which compiles this file with --compileOnly (macro-expansion-
## time diagnostics only; the fictitious C type below is never fed to a
## real C compiler) and greps the output for the hint text — plainly and
## with -d:softlinkStrictVerify.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "libfoo.so":
  proc softlink_a6_needs_header(ctx: pointer): cint
    {.cdecl, prototype: "int softlink_a6_needs_header(Foo_Context ctx)".}
