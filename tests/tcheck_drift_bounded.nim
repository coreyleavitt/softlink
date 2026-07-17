## Regression fixture for finding #20: the drift-story accumulator
## (`softlinkDriftStories<Base>`) must stay bounded across repeated FAILED
## `loadX()` retries, not grow by one entry per retry forever.
##
## Standalone single-file check (NOT wired into the shared nimble `test`
## task — that file is owned by a parallel agent). Reuses the same fixture
## shape as `tests/tcompat_drift_required.nim` (a REQUIRED symbol,
## `testlib_gated`, whose manifest records a `mismatch` interval starting at
## "4.0.0"): every `loadTestlib()` call while `corpusProbeMode == cpmMismatch`
## hits the required-drift-refusal unwind, which resets `handle` to nil —
## making the NEXT `loadTestlib()` call a genuine fresh attempt (not an
## idempotent cache hit), exactly the "repeated failed required-refusal load
## retries" scenario the finding describes.
##
## Requires `tests/manifests/testlib_drift_required.compat.json` to exist
## (gitignored; materialized from the tracked `.tmpl.json` twin by
## substituting `${ABI}` with `softlink/versions.abiTag()` — see
## `softlink.nimble`'s `writeManifestFromTemplate`). Run manually:
##   nim c -r --path:src tests/tcheck_drift_bounded.nim
import std/unittest
import softlink

dynlib "libtestlib.so":
  compatManifest "manifests/testlib_drift_required.compat.json"
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
  proc testlib_gated(): cint {.cdecl, header: "tests/testlib.h".}
  versionProbe:
    "4.0.0" ## always in `testlib_gated`'s mismatch interval -> every
            ## load attempt below hits the required-refusal unwind.

suite "Drift-story accumulator stays bounded (#20)":
  test "N repeated failed loadX() retries leave exactly one story, not N":
    unloadTestlib()
    const N = 25
    for i in 1 .. N:
      let r = loadTestlib()
      check r.kind == lrSymbolNotFound
      check r.symbol == "testlib_gated"
      # The macro-generated accumulator is an unexported module-level var,
      # but this test file IS that module (the `dynlib` block above expands
      # into it), so `softlinkDriftStoriesTestlib` is an ordinary in-scope
      # identifier here — not a public API, just a same-module regression
      # probe.
      check softlinkDriftStoriesTestlib.len == 1
      check softlinkDriftStoriesTestlib[0].symbol == "testlib_gated"
