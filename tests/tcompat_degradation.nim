## RFC-0001 §9/§C.2, slice C5 — degradation matrix, cell 2: "no probe +
## manifest attached". §C.2's own wording: "With no probe or no manifest,
## the report degrades field-by-field to empty." A `compatManifest` may be
## attached to a block that declares no `versionProbe` at all (the two
## directives are independent) — this file pins that combination: the
## load must succeed exactly as it would with no manifest present, and
## `fooCompat()` must report the zero state (`atNoProbe`, `""`, `missing`
## empty) EVEN THOUGH the attached manifest carries a `mismatch` fact for
## one of this block's own symbols (`testlib_gated`, bound REQUIRED here,
## reusing the identical fact shape `tests/tcompat_drift_required.nim`
## uses for the SAME underlying symbol) — a mismatch fact without a probe
## has no runtime version to compare against, so it must be completely
## inert: no partition, no refusal, load succeeds, the symbol stays
## callable. (Cell 1, "probe + no manifest", is already fully pinned in
## `tests/test_softlink.nim`'s own `TestLib` block — see that file's
## "CompatReport (RFC-0001 C2)" tests around `atNoManifest`/
## `atProbeFailed` — so it is not duplicated here.)
##
## Its own module (a SEPARATE `dynlib` block binding the same underlying
## `libtestlib.so`): the duplicate-block guard (#14) fires per-MODULE-
## scope, not globally, so this is legal — see
## `tests/tcompat_report_manifest.nim`'s own doc comment for the identical
## reasoning.
##
## `tests/manifests/testlib_degradation.tmpl.json` is materialized to its
## real, gitignored `*.compat.json` path by the nimble test task's
## `runDegradationChecks` immediately before this file is compiled (the
## same `${ABI}` templating `runCompatReportManifestChecks` uses for
## `tests/tcompat_report_manifest.nim`), and removed afterward.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import std/unittest
import softlink

dynlib "libtestlib.so":
  compatManifest "manifests/testlib_degradation.compat.json"
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
  # testlib_gated: bound REQUIRED here (a separate module from both
  # tests/tcompat_report_manifest.nim, which binds the identical .so
  # symbol optional, and tests/tcompat_drift_required.nim, which binds it
  # required WITH a probe) — the manifest's `mismatch` fact starting at
  # "4.0.0" would refuse this symbol if a probe existed to land inside
  # that interval; with NO versionProbe declared on this block at all,
  # there is no probed version for the fact to be checked against, so
  # refusal can never fire regardless of what the manifest says.
  proc testlib_gated(): cint {.cdecl, header: "tests/testlib.h".}
  # testlib_future: genuinely never implemented (see tests/testlib.c) —
  # kept in the mix so a real lrOkPartial for honest runtime absence stays
  # observable, distinct from (and unaffected by) the manifest's inert
  # facts.
  proc testlib_future(): cint {.cdecl, optional, header: "tests/testlib.h".}
  # Deliberately NO versionProbe — the entire point of this fixture.

suite "CompatReport degradation (RFC-0001 C5) — no probe, manifest attached (cell 2)":
  test "load succeeds unaffected by the manifest; report is the zero state despite a mismatch fact":
    unloadTestlib()
    let r = loadTestlib()
    # Only the genuinely-absent optional symbol may appear missing at the
    # LoadResult level — a drift-refused entry would ALSO land here, so
    # asserting on `missing`'s exact contents (not just `r.kind`) is the
    # real proof that refusal never fired.
    check r.kind == lrOkPartial
    check r.missing == @["testlib_future"]
    check testlibLoaded()
    check testlib_gated() == 21  # required, carries a manifest mismatch fact, never refused

    let c = testlibCompat()
    check c.attestation == atNoProbe
    check c.runtimeVersion == ""
    # No probe -> no partition at all: not even the honest "testlib_future
    # is genuinely absent" fact surfaces here, because the whole partition/
    # refusal machinery never runs without a probed version to reason
    # about (RFC-0001 §C.2: "no probe... degrades field-by-field to
    # empty" applies to the WHOLE report, not just attestation/version).
    check c.missingReasons.len == 0

  test "unload resets to the identical zero state (nothing to reset FROM, in this mode)":
    unloadTestlib()
    let c = testlibCompat()
    check c.attestation == atNoProbe
    check c.runtimeVersion == ""
    check c.missingReasons.len == 0
    check not testlibLoaded()
