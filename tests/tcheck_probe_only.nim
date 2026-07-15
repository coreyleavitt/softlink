## RFC-0001 §4 B.2: define-gated probe modes fixture.
##
## One `dynlib` block covering all four declaration-source/gating axes the
## brief asks for: `testlib_add` (header + prototype, cross-checked),
## `testlib_noop` (header only), `testlib_future` (optional + header),
## `testlib_gated` (verifyWhen-gated + header). Compiled --compileOnly by
## the nimble test task under five configurations:
##
##   M0  no defines                              — control, byte-identical
##       to pre-B2 emission (structurally guaranteed: the new probe-mode
##       branches are unreachable when both defines are at their zero value).
##   M1  -d:softlinkProbeOnly=-                   — ALL verification
##       suppressed (asserts + prototype decl), #includes still present.
##   M2  -d:softlinkProbeOnly=testlib_add         — only testlib_add's
##       verification (assert + prototype decl) survives; the other three
##       procs are fully suppressed.
##   M3  M2 + -d:softlinkProbeExistence           — testlib_add's call-based
##       assert AND its prototype extern decl are BOTH absent; only a bare
##       declaration-existence reference survives. Compiled under both
##       `nim c` (GCC/Clang `__typeof__` tier) and `nim cpp` (C++ `decltype`
##       tier).
##   M4  -d:softlinkProbeOnly=testlib_gated
##       -d:softlinkProbeExistence                — proves the existence
##       reference for a `{.verifyWhen.}`-gated proc stays inside that
##       proc's own `#if (EXPR)` gate (RFC §4 B.2 composition rule).
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "libprobeonly.so":
  proc testlib_add(a: cint, b: cint): cint
    {.cdecl, header: "tests/testlib.h", prototype: "int testlib_add(int a, int b)".}
  proc testlib_noop() {.cdecl, header: "tests/testlib.h".}
  proc testlib_future(): cint {.cdecl, optional, header: "tests/testlib.h".}
  proc testlib_gated(): cint
    {.cdecl, verifyWhen: "TESTLIB_VERSION >= 1", header: "tests/testlib.h".}
