## RFC-0001 §B.5a, slice B6a: `verifyProcs` gets the compile-time SUBSET
## of manifest consumption — since-error, mismatch warning,
## not-in-manifest hint, degraded-tier warning, ABI check — but no
## lib-identity check (no library identity to check against). This
## fixture exercises the mismatch warning (`testlib_add`, recorded
## `mismatch` in `tests/manifests/testlib_vp_subset.compat.json`) and the
## not-in-manifest hint (`testlib_noop`, absent from that manifest) in
## one `verifyProcs` block — proving both fire exactly like their
## `dynlib` counterparts despite there being no library identity here at
## all. Run by the nimble test task, which expects compilation to
## SUCCEED and its output to contain both "recorded a 'mismatch'
## interval" and "not in compat manifest".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

verifyProcs:
  compatManifest "manifests/testlib_vp_subset.compat.json"
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
  proc testlib_noop() {.cdecl, header: "tests/testlib.h".}
