## RFC-0003 §5.3/§7 slice B3: MSVC-leg calibration-REFUSAL check, the
## `/std:clatest` VARIANT.
##
## NOT to be confused with the sibling `tests/tharvest_msvc_calibration_
## refusal.nim`, titled "RFC-0001 SS4 B.2 slice B3" (a pre-existing, DIFFERENT
## RFC's own slice-B3 label) — that file exercises MSVC's DEFAULT compile
## mode, where the `_Generic`/`__typeof__` verification tier itself never
## activates at all (no C23 gate), so EVERY probe degrades to a no-op and
## calibration refuses because the whole tier is dead. THIS file exercises
## the opposite corner named by RFC-0003 §5.3's "corollary lands free of
## charge" paragraph: `--passC:/std:clatest` (the C23 gate) DOES activate a
## live `_Generic`+`__typeof__` tier, so `calib_verified`/`calib_absent`/
## `calib_mismatched` all classify correctly — but MSVC treats a
## pointer-parameter-only mismatch as warning C4133 by DEFAULT, and
## understands none of the GCC/Clang `-Werror=` diagnostics-pin spellings
## `defaultHarvestOptions`/`clangHarvestOptions` add (RFC-0003 §5.2 i). The
## fourth calibration symbol, `calib_param_drifted` (slice B3), is exactly
## the known-answer probe that catches this: under `/std:clatest`, with no
## MSVC-recognized pin, it classifies `fkVerified` instead of the expected
## `fkMismatch` — so calibration refuses here too, for a DIFFERENT reason
## than the default-mode test above (a live-but-unpinned tier, not a dead
## one). Combined, the two tests prove MSVC harvest refuses in EVERY flag
## configuration this project ships an opts literal for, per RFC-0003 §5.3
## ("MSVC harvest now refuses in every flag configuration rather than ever
## silently misclassifying"). A caller could in principle restore MSVC
## teeth via `/we4133` in their own opts (documented as
## unsupported-but-principled, RFC-0003 §5.3/C2) — not tested here.
##
## Run ONLY by `task testMsvcExitCodes` (softlink.nimble), immediately after
## the sibling default-mode check — see that task's own doc comment for why
## MSVC gets this narrower nimble-task surface instead of the full `task
## test`. Structurally identical to the sibling file (same fixture, same
## `HarvestOptions` shape, `--passC:/std:clatest` appended to `extraFlags`)
## so the risk of this variant is mechanical only.
##
## CI-VALIDATED-ON-FIRST-PUSH: there is no local MSVC toolchain available
## during development (see this project's own MSVC handoff notes) — this
## test is written carefully against the calibration contract and RFC-0003
## §5.3's stated corollary, but its first real proof is the next CI run on
## the `windows-msvc` leg. The Linux/gcc Docker suite (this project's only
## locally-runnable leg) cannot exercise `--cc:vcc` at all; this file is not
## part of that suite for exactly that reason.
import std/[unittest, os, strutils]
import ../tools/harvest/harvester

let msvcClatestOpts = HarvestOptions(
  nimPaths: @["src"],
  extraFlags: @["--cc:vcc", "--passC:/std:clatest"],
  includeFlagPrefix: "/I",
  scratchDir: getTempDir(),
  # Same generous compile-time/output-size budget as the sibling test's
  # `msvcDefaultOpts` and `defaultHarvestOptions()` — this test isn't
  # exercising Finding F6, so it should behave exactly as it did before
  # that finding's fix.
  compileTimeoutMs: 300_000,
  maxOutputBytes: 16_777_216,
)

suite "runCalibration refuses under /std:clatest MSVC too (RFC-0003 §5.3, slice B3)":
  test "calibration reports failure, with a diagnosis naming calib_param_drifted":
    let outcome = runCalibration(msvcClatestOpts)
    check not outcome.ok
    check outcome.diagnosis.len > 0
    check "calib_param_drifted" in outcome.diagnosis

  test "harvest() refuses before probing the real corpus at all — no harvest performed":
    let dumpDir = getCurrentDir() / "tests" / "nimcache_tharvest_msvc_clatest_dump"
    if dirExists(dumpDir): removeDir(dumpDir)
    # Dump generation is a plain `--compileOnly` macro-expansion-time write
    # (RFC-0001 SS4 B.1) — it never invokes a C compiler at all, so this
    # step needs no `--cc:vcc` and behaves identically on every CI leg.
    let dumpCmd = "nim c --compileOnly --path:src -d:softlinkDumpProbes=" &
      dumpDir & " tests/tharvest_binding.nim"
    doAssert execShellCmd(dumpCmd) == 0,
      "softlink: RFC-0003 slice B3 (/std:clatest MSVC calibration-refusal " &
      "check): failed to generate the B.1 dump needed for this check: " & dumpCmd
    let dumpFile = dumpDir / "Corpuslib.probes.json"
    doAssert fileExists(dumpFile),
      "softlink: RFC-0003 slice B3 (/std:clatest MSVC calibration-refusal " &
      "check): expected dump file to exist: " & dumpFile

    var refused = false
    var diagnosis = ""
    try:
      discard harvest(dumpFile, "tests" / "corpus", msvcClatestOpts)
    except CalibrationRefusedError as e:
      refused = true
      diagnosis = e.msg
    check refused
    check diagnosis.len > 0
    removeDir(dumpDir)

echo "softlink: RFC-0003 slice B3: /std:clatest MSVC-leg calibration-refusal check complete"
