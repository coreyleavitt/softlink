## RFC-0001 §B.5a, slice B6a: `verifyProcs` has no `loadX`/drift-refusal
## surface at all, so an ACCEPTED `refuse` argument would silently
## promise a policy knob that does nothing — "nothing to refuse on
## verifyProcs". Run by the nimble test task, which expects compilation
## to fail with "nothing to refuse on verifyProcs".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

verifyProcs:
  compatManifest("manifests/testlib.compat.json", refuse = true)
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
