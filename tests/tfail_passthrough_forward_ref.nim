## RFC 0011 S0a item 4, round-2 test obligation: statement pass-through's one
## hard limit. Softlink emits each binding's wrapper proc IN SOURCE POSITION
## (interleaved with every passed-through statement, exactly as the author
## wrote them) — so a passed-through helper may call any BINDING declared
## EARLIER in the same block, the same ordinary Nim top-level forward-
## reference rule that already governs two hand-written procs. Calling one
## declared LATER is refused, for the identical reason two hand-written
## top-level procs would refuse it: Nim grants macro-spliced code no special
## forward-reference tolerance beyond what hand-written code already gets
## (confirmed by direct experiment before landing item 4 — see the
## `dynlib` macro's own doc comment on the wrapper-emission loop).
## `type`/`const` sections don't share this restriction (they are hoisted
## ahead of every binding, so a binding's signature may use one declared
## either before or after it — see tests/test_softlink.nim's
## ScaleFactor/TripleFactor pair) — only a helper calling a not-yet-declared
## PROC has no such escape hatch. Run by the nimble test task, which expects
## compilation to fail with "undeclared identifier" naming
## 'testlibForwardTarget'.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "fakepassthroughforward":
  proc helperCallsLater(): cint = testlibForwardTarget() + 1

  proc testlibForwardTarget(): cint {.cdecl, noverify.}
