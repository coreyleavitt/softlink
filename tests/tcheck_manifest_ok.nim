## RFC-0001 §B.5, slice B6a: a `compatManifest` directive attached to a
## `dynlib` block whose manifest agrees with everything (right schema,
## right `lib`, right ABI, every bound symbol `verified`, nothing
## mismatched, nothing missing) must compile with NO extra diagnostics —
## the clean-bill-of-health case. Run by the nimble test task, which
## asserts the compile succeeds AND its output contains none of the
## manifest-consumption diagnostic substrings (mismatch/hint/schema/abi/
## lib-identity) that the OTHER manifest fixtures in this suite each
## deliberately trigger.
##
## `tests/manifests/testlib.compat.json`'s `harvest.abi` is rewritten
## in-place by the nimble task (per-OS-leg-correct) immediately before
## this file is compiled — see `writeManifestFromTemplate` in softlink.nimble.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "libtestlib.so":
  compatManifest "manifests/testlib.compat.json"
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
