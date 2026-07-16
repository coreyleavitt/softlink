## RFC-0001 SS4 B.2 slice B3: MSVC-leg calibration-REFUSAL check.
##
## Exercises the calibration preflight's structural guard directly against
## real MSVC in its DEFAULT compile mode — `--cc:vcc` WITHOUT
## `--passC:/std:clatest` (the C23 gate). Without that gate, MSVC never
## recognizes `_Generic`/`__typeof__` and src/softlink.nim's own
## `genVerifyBlock` falls all the way through to its documented graceful
## fallback for BOTH constructs it can emit for a probed symbol:
##
##   - the existence reference (`sizeof(__typeof__(&sym))` under the
##     MSVC/C23 tier) degrades to "emit nothing" — never a hard `#error`,
##     since `-d:softlinkStrictVerify` is deliberately NOT set here (this
##     targets the ORDINARY default-mode experience, not the CI-only
##     strict trap `ci.yaml`'s "Run tests (MSVC)" step exercises
##     separately with `/std:clatest` REQUIRED);
##   - the call-based `_Static_assert` degrades the same way.
##
## So EVERY probe compiles unconditionally, regardless of what the header
## actually declares — the known-mismatched fixture's assert never fires
## (false `verified`) AND the known-absent fixture's existence reference
## never fires either (also false `verified`, not the `absent` a working
## existence probe would report). Either deviation alone is enough to trip
## calibration; this fixture trio trips both, independently, so a real
## regression in only one of the two constructs would still be caught.
##
## Run ONLY by `task testMsvcExitCodes` (softlink.nimble) — see that task's
## own doc comment for why MSVC gets this narrower nimble-task surface
## instead of the full `task test`. The ORCHESTRATING compile of THIS file
## uses the runner's default compiler (bundled MinGW on the official
## Windows Nim zip `ci.yaml` installs) — this file is pure Nim + the
## harvester's own `osproc` plumbing, nothing here needs `cl.exe` itself;
## only the harvester's INTERNAL probe compiles (spawned as subprocesses,
## configured via `msvcDefaultOpts` below) target `--cc:vcc`.
##
## CI-VALIDATED-ON-FIRST-PUSH: there is no local MSVC toolchain available
## during development (see this project's own MSVC handoff notes) — this
## test is written carefully against the calibration contract but its
## first real proof is the next CI run on the `windows-msvc` leg.
import std/[unittest, os, strutils]
import ../tools/harvest/harvester

let msvcDefaultOpts = HarvestOptions(
  nimPaths: @["src"],
  extraFlags: @["--cc:vcc"],
  includeFlagPrefix: "/I",
  scratchDir: getTempDir(),
)

suite "runCalibration refuses under default-mode MSVC (RFC-0001 slice B3)":
  test "calibration reports failure, with a diagnosis naming the toolchain":
    let outcome = runCalibration(msvcDefaultOpts)
    check not outcome.ok
    check outcome.diagnosis.len > 0
    check "MSVC" in outcome.diagnosis

  test "harvest() refuses before probing the real corpus at all — no harvest performed":
    let dumpDir = getCurrentDir() / "tests" / "nimcache_tharvest_msvc_dump"
    if dirExists(dumpDir): removeDir(dumpDir)
    # Dump generation is a plain `--compileOnly` macro-expansion-time write
    # (RFC-0001 SS4 B.1) — it never invokes a C compiler at all, so this
    # step needs no `--cc:vcc` and behaves identically on every CI leg.
    let dumpCmd = "nim c --compileOnly --path:src -d:softlinkDumpProbes=" &
      dumpDir & " tests/tharvest_binding.nim"
    doAssert execShellCmd(dumpCmd) == 0,
      "softlink: RFC-0001 slice B3 (MSVC calibration-refusal check): " &
      "failed to generate the B.1 dump needed for this check: " & dumpCmd
    let dumpFile = dumpDir / "Corpuslib.probes.json"
    doAssert fileExists(dumpFile),
      "softlink: RFC-0001 slice B3 (MSVC calibration-refusal check): " &
      "expected dump file to exist: " & dumpFile

    var refused = false
    var diagnosis = ""
    try:
      discard harvest(dumpFile, "tests" / "corpus", msvcDefaultOpts)
    except CalibrationRefusedError as e:
      refused = true
      diagnosis = e.msg
    check refused
    check diagnosis.len > 0
    removeDir(dumpDir)

echo "softlink: RFC-0001 slice B3: MSVC-leg calibration-refusal check complete"
