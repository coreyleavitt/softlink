## Compile-diagnostic test: a `versionMacros(...)` block-level directive
## that no `{.until.}`-carrying proc actually consumes must emit a
## compile-time hint saying so (code-review finding CR1-12) — before this
## fix, the directive parsed fine and was silently inert: nothing downstream
## ever read `versionMacroNames` again. This fixture's block declares
## `versionMacros` but has no `{.until.}` proc at all, so gate synthesis
## (`synthesizeVersionGates`) never touches it — the directive is dead on
## arrival.
##
## Deliberately NOT escalated under -d:softlinkStrictVerify (unlike the
## {.noverify.}/drifted-but-required hints) — see
## `checkVersionMacrosConsumed`'s doc comment (src/softlink/pragmas.nim) for
## why this stays a plain hint at every verify tier. Run by the nimble test
## task, which compiles this file plainly AND with -d:softlinkStrictVerify
## and greps the compiler output for "declared but never used" — plainly as
## a Hint, and (to prove non-escalation) STILL as a Hint, never a Warning,
## under -d:softlinkStrictVerify.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "libfoo.so":
  versionMacros("FOO_VERSION")

  proc foo(x: cint): cint {.cdecl, noverify.}
