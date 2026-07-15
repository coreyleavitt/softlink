## RFC-0001 §4 B.2: `verifyProcs` parity for the probe-mode fixture above —
## suppression/probing/existence classification is implemented once, in the
## shared `genVerifyBlock`, so `dynlib` and `verifyProcs` get it for free.
## This fixture proves that structurally, through `verifyProcs` alone (no
## `dynlib` block in this file).
##
## `testlib_magic` (header-verified) and `testlib_protoonly` (prototype-only,
## no header — both symbols reused verbatim from testlib.h/testlib.c, already
## proven correct by test_softlink.nim and tcheck_dump_probes.nim).
##
## Compiled --compileOnly by the nimble test task under:
##   V0  no defines                          — control
##   V1  -d:softlinkProbeOnly=testlib_magic  — only testlib_magic survives;
##       testlib_protoonly (assert AND prototype decl) is fully suppressed
##   V2  V1 + -d:softlinkProbeExistence      — testlib_magic's call-based
##       assert is replaced by a bare existence reference
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

verifyProcs:
  proc testlib_magic(): cint {.cdecl, header: "tests/testlib.h".}
  proc testlib_protoonly(): cint
    {.cdecl, prototype: "int testlib_protoonly(void)".}
