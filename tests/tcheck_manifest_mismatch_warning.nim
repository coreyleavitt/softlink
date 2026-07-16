## RFC-0001 §B.5, slice B6a: a bound symbol with any `mismatch` interval
## in the attached manifest must get a compile WARNING (not an error —
## the drift alarm/CI tripwire is `softlink harvest`'s job, not the
## compile's), naming the symbol. `tests/manifests/testlib.compat.json`
## records `testlib_noop` as `mismatch` across the whole corpus. Run by
## the nimble test task, which expects compilation to SUCCEED and its
## output to contain "recorded a 'mismatch' interval".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "libtestlib.so":
  compatManifest "manifests/testlib.compat.json"
  proc testlib_noop() {.cdecl, header: "tests/testlib.h".}
