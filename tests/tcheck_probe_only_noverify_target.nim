## Code-review finding R2-3 (Medium, double-confirmed by design +
## correctness reviewers): `genVerifyBlock`'s F9 "no proc in this block"
## typo/stale-name warning (see `tcheck_probe_only.nim`'s own doc comment
## and `-d:softlinkProbeOnly=testlib_totally_bogus_name` there) was built
## from `blockCNames`, populated from `allProcs` — which INCLUDES
## `{.noverify.}` procs, even though a `{.noverify.}` proc is never
## verification-eligible (see `genVerifyBlock`'s `procs` filter: `not
## p.noVerify and (p.headerFile != "" or p.prototype.len > 0)`).
##
## Consequence: if `-d:softlinkProbeOnly=<name>` names ONLY a `{.noverify.}`
## proc's cname in this block, the warning never fired (the name IS in
## `allProcs`), yet `isSuppressed` still suppressed verification for every
## genuinely-verifiable proc in the block — silent, total verification
## suppression, exactly the failure mode the F9 warning exists to catch.
##
## `testlib_add` is header-verified (the "genuinely-verifiable" proc whose
## suppression must be flagged); `testlib_noverify_target` is `{.noverify.}`
## — a real symbol name in this block, but with no verification to gate.
## `-d:softlinkProbeOnly=testlib_noverify_target` below names ONLY that
## noverify proc.
##
## Before the fix: compiles with NO "no proc in this block" warning, and
## testlib_add's verification is silently suppressed. After the fix: the
## warning fires, naming `testlib_noverify_target`.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "libprobeonly.so":
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
  proc testlib_noverify_target(): cint {.cdecl, noverify.}
