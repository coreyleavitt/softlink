## RFC-0001 §B.5 check 9, slice B6a: when a compat manifest is attached,
## the verify TU's graceful `#else` fallback (the no-verification tier,
## e.g. default-mode MSVC) must carry a `#pragma message` noting that
## THIS compile did not re-verify the manifest's facts — a green manifest
## and a degraded verification tier must never blur into one "everything
## is fine" signal. This fixture attaches a clean manifest (no other
## diagnostics fire); its companion, `tcheck_manifest_degraded_without.nim`
## (identical binding, no directive), is the absence control. Run by the
## nimble test task via `expectAnchor` against the emitted C — the
## pragma-message text is checked for PRESENCE here and ABSENCE there.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  compatManifest "manifests/testlib.compat.json"
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
