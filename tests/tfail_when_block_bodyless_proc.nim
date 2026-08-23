## Code-review finding L9: the SAME hazard as `tfail_when_bodyless_proc.nim`
## and `tfail_when_nested_bodyless_proc.nim`, but the bodyless proc sits
## inside a `block:` nested within a `when` branch — a pure
## statement-grouping construct, not another `when`. Before the fix,
## `collectBodylessProcDeclsInWhen`'s walk recognized a bodyless proc or a
## nested `when` directly inside a branch's statement list, but not one
## hidden one level deeper inside a `block:` — this exact shape silently
## slipped through as legitimate pass-through and failed later with Nim's
## own opaque "implementation expected" instead of naming the real mistake.
## Run by the nimble test task, which expects compilation to fail with the
## conditional-binding error.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "fakewhenblock":
  when defined(linux):
    block:
      proc testlib_block_bodyless(): cint {.cdecl, noverify.}
  else:
    discard
