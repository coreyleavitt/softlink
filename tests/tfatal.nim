## RFC 0011 S0b, work item (ii): tests for the trusted-wrapper mode's fatal
## subsystem (`softlink/fatal`), standalone — no `dynlib` block, no
## wrapper codegen (work item (i)'s own subprocess pin,
## `tests/fatal_child_wrapper.nim`, exercises that integration separately).
##
## Three halves:
##
##   - An IN-PROCESS suite (compiled with `-d:softlinkTesting`, this file's
##     own required compile flag — see `task test` in softlink.nimble) that
##     drives ONLY the CAS reentrancy guard, via `softlinkFatalTestEntry`/
##     `resetFatalGuardForTest` (`softlink/fatal`'s test-only seam), including
##     genuine concurrent entry from real OS threads — proving the guard's
##     "exactly one winner" property holds under actual concurrency, not
##     merely by inspection of the CAS call. As of the CI incident below,
##     this suite deliberately never touches real diagnostic-sink I/O.
##
##   - A PURE-LOGIC suite for `shouldShowFatalDialog` (`softlink/fatal`) —
##     the dialog-gating DECISION, tested as a boolean truth table with no
##     environment dependency at all (runs identically on Linux/macOS/
##     Windows, and needs no `-d:softlinkTesting`-only seam of its own since
##     the function itself is always compiled, on every platform).
##
##   - A SUBPROCESS suite that compiles and runs `tests/fatal_child_basic.nim`,
##     `tests/fatal_child_race.nim`, and `tests/fatal_child_wrapper.nim` —
##     all WITHOUT `-d:softlinkTesting` (real production `softlinkFatal`)
##     AND WITH `-d:softlinkNoFatalDialog` (see `compileChild`'s own doc
##     comment for why that define is now non-negotiable for every child
##     this file compiles) — and inspects each child's captured stdout/
##     stderr and exit code. This is the only way to observe `softlinkFatal`'s
##     actual termination semantics (no exit procs, real process death) from
##     a test: `softlinkFatal` is `{.noreturn.}` and really means it in
##     production builds, so it cannot be called in-process without ending
##     the test runner itself.
##
## CI INCIDENT (RFC 0011 S0b, post-ship): the in-process suite used to call
## the FULL production sink path (`fatalCore`, sinks included) via
## `softlinkFatalTestEntry`, on the theory that "an in-process test hook is
## always safe because it never runs `_Exit`." That theory was wrong: a
## GitHub-hosted Windows CI runner's own interactive autologon session has a
## VISIBLE window station — the exact condition `shouldShowFatalDialog`
## treats as "a human is watching" — so the suite's very first test popped a
## REAL `MessageBoxW` dialog on a desktop nobody could see or click, and the
## CI job hung for 30 minutes until cancelled. No environment heuristic can
## distinguish "interactive desktop with a human" from "headless CI on a
## visible station," so the fix is structural: the in-process suite below
## never reaches real sink I/O at all (see `softlink/fatal.nim`'s
## `softlinkFatalTestEntry`/`performFatalSinks` doc comments), the dialog
## DECISION is pinned separately as pure logic (below), and every subprocess
## child this file spawns is compiled provably unable to open a dialog
## (`-d:softlinkNoFatalDialog`) rather than relying on the container's own
## window station happening to be non-visible.
##
## POSIX audit (same incident class): softlink/fatal has NO POSIX GUI/dialog
## code path at all — `MessageBoxW`/the window-station checks are declared
## only `when defined(windows)`. The subprocess suite's assertions (stderr
## content, exit code, exit-proc absence) depend only on process semantics
## POSIX guarantees identically in any environment (a terminal, a CI runner,
## a container) — there is no equivalent "visible session" axis on POSIX for
## this module to get wrong. Audited and found clean; no POSIX-side change
## was needed.
##
## Run: `nim c -r -d:softlinkTesting --path:src tests/tfatal.nim` (see
## `task test` in softlink.nimble for the exact wiring).
import std/[unittest, os, osproc, streams, strutils]
import softlink/fatal

# ---------------------------------------------------------------------------
# In-process suite: the CAS guard itself — NO real sink I/O (see the CI
# incident note above).
# ---------------------------------------------------------------------------

suite "softlinkFatal's CAS reentrancy guard (in-process, -d:softlinkTesting)":
  setup:
    resetFatalGuardForTest()

  test "first entry claims the CAS guard":
    check softlinkFatalTestEntry("first-entry diagnostic")

  test "a second, sequential entry loses the CAS and is not re-claimed":
    check softlinkFatalTestEntry("winner diagnostic")
    check not softlinkFatalTestEntry("loser diagnostic — must not double-claim")

  test "reset makes the guard usable again in the same process":
    check softlinkFatalTestEntry("round one")
    resetFatalGuardForTest()
    check softlinkFatalTestEntry("round two")

  test "exactly one of many concurrent threads wins the CAS":
    ## RFC 0011 S0b item (ii)(b): "the flag is an atomic compare-and-swap
    ## ... the short-circuit guarantee must also hold when two threads
    ## reach the fatal concurrently." Hammers the guard from a handful of
    ## real OS threads, all starting as close to simultaneously as
    ## `std/typedthreads` allows, and asserts the winner tally is exactly
    ## one no matter how the OS scheduler interleaves them.
    const threadCount = 8
    var results: array[threadCount, bool]

    proc worker(args: tuple[idx: int, results: ptr array[threadCount, bool]]) {.thread.} =
      args.results[][args.idx] = softlinkFatalTestEntry(
        "concurrent diagnostic from thread " & $args.idx)

    var threads: array[threadCount, Thread[tuple[idx: int, results: ptr array[threadCount, bool]]]]
    for i in 0 ..< threadCount:
      createThread(threads[i], worker, (i, addr results))
    for i in 0 ..< threadCount:
      joinThread(threads[i])

    var winners = 0
    for r in results:
      if r: inc winners
    check winners == 1

# ---------------------------------------------------------------------------
# Pure-logic suite: the dialog-gating DECISION, as a truth table — no
# environment dependency, no `-d:softlinkTesting` needed (the function is
# always compiled), runs identically on every platform.
# ---------------------------------------------------------------------------

suite "shouldShowFatalDialog — pure decision truth table (RFC 0011 S0b, post-CI-hang)":
  test "no console, visible station, dialog allowed -> SHOW (the one true case)":
    check shouldShowFatalDialog(hasConsole = false, stationVisible = true, noFatalDialogDefined = false)

  test "no console, station NOT visible -> skip (container/service session)":
    check not shouldShowFatalDialog(hasConsole = false, stationVisible = false, noFatalDialogDefined = false)

  test "console attached, visible station -> skip (stderr already visible)":
    check not shouldShowFatalDialog(hasConsole = true, stationVisible = true, noFatalDialogDefined = false)

  test "console attached, station NOT visible -> skip":
    check not shouldShowFatalDialog(hasConsole = true, stationVisible = false, noFatalDialogDefined = false)

  test "-d:softlinkNoFatalDialog wins over every other combination":
    ## The build-wide override always forces "skip," regardless of console/
    ## station state — this is the exact property `-d:softlinkNoFatalDialog`
    ## promises, and the property every subprocess child in this file's own
    ## `compileChild` now relies on to be provably dialog-free in ANY CI
    ## environment (interactive-desktop runner or headless container alike).
    check not shouldShowFatalDialog(hasConsole = false, stationVisible = true, noFatalDialogDefined = true)
    check not shouldShowFatalDialog(hasConsole = false, stationVisible = false, noFatalDialogDefined = true)
    check not shouldShowFatalDialog(hasConsole = true, stationVisible = true, noFatalDialogDefined = true)
    check not shouldShowFatalDialog(hasConsole = true, stationVisible = false, noFatalDialogDefined = true)

# ---------------------------------------------------------------------------
# Subprocess suite: real production softlinkFatal, real process termination.
# ---------------------------------------------------------------------------

type ChildResult = object
  stdoutText, stderrText: string
  exitCode: int

proc compileChild(fixture, exePath: string, extraFlags = ""): string =
  ## Compiles `tests/<fixture>.nim` (WITHOUT `-d:softlinkTesting` — this is
  ## always a production build of the child) into `exePath`, via a fresh
  ## `--nimcache`, and returns the compiler's combined output (for a
  ## diagnostic dump on failure). Mirrors this project's existing
  ## subprocess-compile precedent (`tests/tharvest_msvc_calibration_refusal.
  ## nim`'s own `execShellCmd` use, and the harvester's internal `osproc`
  ## plumbing it calls into) rather than inventing a new mechanism.
  ##
  ## `-d:softlinkNoFatalDialog` is ALWAYS added (unconditionally, not part
  ## of `extraFlags`) — post-CI-hang hardening: `task test` is the
  ## cross-platform gate that runs on every CI matrix leg, including a
  ## real, interactive-desktop Windows runner (confirmed: GitHub-hosted
  ## Windows runners run an autologon session with a VISIBLE window
  ## station). A child compiled WITHOUT this define is only safe to run
  ## where the window station is non-visible (this project's own container,
  ## or a real headless service) — see `tests/fatal_child_gui.nim`'s own
  ## doc comment for the ONE fixture that deliberately omits it, and why
  ## that fixture is confined to the container-only `task testWindows`
  ## instead of running here. Every child `compileChild` builds must be
  ## PROVABLY unable to open a dialog regardless of what environment
  ## `nimble test` happens to run under — this define is what makes that
  ## true (it compiles the `MessageBoxW` leg out of the generated C
  ## entirely, not merely "make it unlikely to fire").
  let nimcacheDir = exePath & "_nc"
  if dirExists(nimcacheDir): removeDir(nimcacheDir)
  let cmd = "nim c -o:" & exePath & " --nimcache:" & nimcacheDir &
    " -d:softlinkNoFatalDialog --threads:on --path:src " & extraFlags &
    " tests" / (fixture & ".nim")
  let (output, code) = execCmdEx(cmd)
  doAssert code == 0, "softlink: RFC 0011 S0b: failed to compile subprocess " &
    "fixture '" & fixture & "': " & cmd & "\n" & output
  output

proc runChild(exePath: string): ChildResult =
  ## Runs the already-compiled `exePath` and captures stdout/stderr
  ## SEPARATELY (not merged) — the RFC's own story (a) distinguishes
  ## "diagnostic present on stderr" from "sentinel ABSENT" (the sentinel
  ## goes to stdout in `fatal_child_basic.nim`, precisely so a merged
  ## stream couldn't launder a stray sentinel past a stderr-only check by
  ## accident). `poUsePath` only — no `poStdErrToStdOut` — is what keeps
  ## the two streams apart.
  var p = startProcess(exePath, options = {poUsePath})
  result.stdoutText = p.outputStream.readAll()
  result.stderrText = p.errorStream.readAll()
  result.exitCode = p.waitForExit()
  p.close()

suite "softlinkFatal end-to-end (subprocess, production build)":
  test "story (a): diagnostic on stderr, sentinel absent, nonzero exit, no exit procs":
    let exePath = getTempDir() / "softlink_fatal_child_basic"
    let compileLog = compileChild("fatal_child_basic", exePath)
    let r = runChild(exePath)
    removeFile(exePath)

    check r.exitCode != 0
    check "child fatal message naming a fictitious symbol foo_bar_baz" in r.stderrText
    check "SENTINEL_EXITPROC_RAN" notin r.stderrText
    check "SENTINEL_EXITPROC_RAN" notin r.stdoutText
    check "child: UNREACHABLE" notin r.stdoutText
    if r.exitCode == 0 or "SENTINEL_EXITPROC_RAN" in (r.stdoutText & r.stderrText):
      echo "compile log:\n", compileLog
      echo "stdout:\n", r.stdoutText
      echo "stderr:\n", r.stderrText

  test "story (b) subprocess leg: two concurrent entries produce exactly one diagnostic":
    let exePath = getTempDir() / "softlink_fatal_child_race"
    let compileLog = compileChild("fatal_child_race", exePath)
    let r = runChild(exePath)
    removeFile(exePath)

    check r.exitCode != 0
    let oneCount = r.stderrText.count("RACE_DIAGNOSTIC_ONE")
    let twoCount = r.stderrText.count("RACE_DIAGNOSTIC_TWO")
    # Exactly one of the two threads' diagnostics must appear, exactly
    # once — never both (that would mean the guard let both through) and
    # never neither (that would mean the process died — or hung — before
    # either finished writing, which `runChild`'s successful return here
    # already rules out).
    check oneCount + twoCount == 1
    check "UNREACHABLE" notin r.stdoutText
    if oneCount + twoCount != 1:
      echo "compile log:\n", compileLog
      echo "stdout:\n", r.stdoutText
      echo "stderr:\n", r.stderrText

  test "work item (i)(g): trusted wrapper's nil branch fatals with the full not-loaded diagnostic":
    ## Unlike the two tests above (the fatal subsystem in isolation), this
    ## exercises REAL wrapper codegen (`src/softlink.nim`'s
    ## `trustedWrappers` branch): `tests/fatal_child_wrapper.nim` declares a
    ## real `dynlib` block with `trustedWrappers`, never calls `loadTestlib()`,
    ## and calls the trusted wrapper anyway — its nil branch must call
    ## `softlinkFatal` with the SAME "<library>: library not loaded, cannot
    ## call: <symbol>" text an untrusted wrapper's raised `SoftlinkError.msg`
    ## would carry (see `raiseNotLoaded`, `src/softlink.nim`).
    let exePath = getTempDir() / "softlink_fatal_child_wrapper"
    let compileLog = compileChild("fatal_child_wrapper", exePath, "--passC:-I.")
    let r = runChild(exePath)
    removeFile(exePath)

    check r.exitCode != 0
    check "library not loaded, cannot call: testlib_add" in r.stderrText
    check "libtestlib" in r.stderrText or "testlib.dll" in r.stderrText
    check "SENTINEL_EXITPROC_RAN" notin (r.stdoutText & r.stderrText)
    check "child: UNREACHABLE" notin r.stdoutText
    if r.exitCode == 0 or "SENTINEL_EXITPROC_RAN" in (r.stdoutText & r.stderrText):
      echo "compile log:\n", compileLog
      echo "stdout:\n", r.stdoutText
      echo "stderr:\n", r.stderrText

echo "softlink: RFC 0011 S0b: fatal subsystem tests complete"
