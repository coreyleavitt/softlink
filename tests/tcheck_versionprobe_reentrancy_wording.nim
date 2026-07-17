## Finding #19.3 (code-review coverage gap): pins the EXACT wording of the
## versionProbe reentrancy guard's raised message
## (`reentrancyRaiseStmt` in src/softlink.nim: "<loadX/unloadX> called
## reentrantly from its own versionProbe").
##
## Every existing runtime test for this guard (test_softlink.nim's "reentrant
## loadC()"/"reentrant unloadTestlib()" tests) only proves the raise gets
## CONVERTED to a failed probe (`softlinkProbeFailed<Base> == true`) — by
## design the raise is always caught by the probe's own internal
## `try/except CatchableError`, so its message never escapes to any
## caller-visible exception object; there is no `getCurrentExceptionMsg()`
## or `e.msg` a runtime test could inspect. Macro-expansion inspection (the
## same `--expandMacro:dynlib` + substring technique softlink.nimble's
## `expectWrapperBeforeLoad` already uses for the wrapper/loadX ordering
## pin) is the only way to observe this text directly, so that's the
## approach used here instead of a runtime test.
##
## Base name "Foo" (from "libfoo.so") deliberately mirrors
## tests/thint_noverify.nim's fixture so both `loadFoo`/`unloadFoo` appear
## in the expansion the same way `expectWrapperBeforeLoad` already expects.
##
## Run by the nimble test task's `runVersionProbeChecks()`, which expects
## the compile to SUCCEED and its `--expandMacro:dynlib` hint output to
## contain both messages verbatim.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "libfoo.so":
  proc foo(x: cint): cint {.cdecl, noverify.}
  versionProbe:
    "1.0.0"
