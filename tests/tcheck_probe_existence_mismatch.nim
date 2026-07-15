## RFC-0001 §4 B.2: the heart of the classification table, proven directly —
## a deliberately WRONG Nim signature for a real, header-declared symbol.
##
## `testlib_add` is `int testlib_add(int a, int b)` in testlib.h (see
## tfail_prototype_mismatch.nim for the same trick via {.prototype.}); this
## fixture binds its return type as `cdouble` instead of `cint`. Compiled by
## the nimble test task two ways:
##
##   - verify mode (`-d:softlinkProbeOnly=testlib_add`, no existence): the
##     call-based assert chain runs at full strength and MUST FAIL with
##     softlink's own "signature mismatch" diagnostic — probing a single
##     symbol is not a weaker check than the ordinary compile.
##   - existence mode (same, `+ -d:softlinkProbeExistence`): the assert is
##     replaced by a bare declaration-existence reference that does not
##     depend on the declared signature, so this exact same mismatched
##     binding MUST SUCCEED to compile.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "libtestlib.so":
  proc testlib_add(a: cint, b: cint): cdouble
    {.cdecl, header: "tests/testlib.h".}
