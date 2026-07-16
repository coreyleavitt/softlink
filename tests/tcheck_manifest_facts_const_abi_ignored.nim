## RFC-0001 §B.5/§9, slice B6b: an ABI-mismatched manifest degrades to
## no-manifest behavior ENTIRELY (slice B6a) — including const embedding.
## Reuses `tests/manifests/testlib_abi_mismatch.compat.json` (fixed,
## never templated per-OS-leg, at `"abi": "nonesuch-ilp128"`, which never
## matches any real build target) from
## `tests/tcheck_manifest_abi_mismatch.nim`. Proving `declared()` is false
## here is the const-embedding half of that same "ignored really means
## ignored" proof — B6a already proved every OTHER check (since-
## contradiction, mismatch warning, hint) is skipped too.
##
## Run by the nimble test task via `runManifestChecks()`; expects
## compilation to SUCCEED with the ABI-ignored warning present.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "libtestlib.so":
  compatManifest "manifests/testlib_abi_mismatch.compat.json"
  proc testlib_add(a: cint, b: cint): cint {.cdecl, since: "1.0.0", header: "tests/testlib.h".}

static:
  doAssert not declared(softlinkCompatFactsTestlib)
