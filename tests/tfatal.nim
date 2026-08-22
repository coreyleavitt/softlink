## RFC 0011 S0b, work item (ii): tests for the trusted-wrapper mode's fatal
## subsystem (`softlink/fatal`), standalone — no `dynlib` block, no
## wrapper codegen (work item (i)'s own subprocess pin,
## `tests/fatal_child_wrapper.nim`, exercises that integration separately).
##
## Two halves:
##
##   - An IN-PROCESS suite (compiled with `-d:softlinkTesting`, this file's
##     own required compile flag — see `task test` in softlink.nimble) that
##     drives the CAS reentrancy guard directly via `softlinkFatalTestEntry`/
##     `resetFatalGuardForTest` (`softlink/fatal`'s test-only seam), including
##     genuine concurrent entry from real OS threads — proving the guard's
##     "exactly one winner" property holds under actual concurrency, not
##     merely by inspection of the CAS call.
##
##   - A SUBPROCESS suite that compiles and runs `tests/fatal_child_basic.nim`
##     and `tests/fatal_child_race.nim` — both WITHOUT `-d:softlinkTesting`,
##     i.e. real production `softlinkFatal` — and inspects each child's
##     captured stdout/stderr and exit code. This is the only way to observe
##     `softlinkFatal`'s actual termination semantics (no exit procs, real
##     process death) from a test: `softlinkFatal` is `{.noreturn.}` and
##     really means it in production builds, so it cannot be called
##     in-process without ending the test runner itself.
##
## Run: `nim c -r -d:softlinkTesting --path:src tests/tfatal.nim` (see
## `task test` in softlink.nimble for the exact wiring).
import std/[unittest, os, osproc, streams, strutils]
import softlink/fatal

# ---------------------------------------------------------------------------
# In-process suite: the CAS guard itself.
# ---------------------------------------------------------------------------

suite "softlinkFatal's CAS reentrancy guard (in-process, -d:softlinkTesting)":
  setup:
    resetFatalGuardForTest()

  test "first entry wins the CAS and performs diagnostic work":
    check softlinkFatalTestEntry("first-entry diagnostic")

  test "a second, sequential entry loses the CAS and does no diagnostic work":
    check softlinkFatalTestEntry("winner diagnostic")
    check not softlinkFatalTestEntry("loser diagnostic — must not double-fire")

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
  let nimcacheDir = exePath & "_nc"
  if dirExists(nimcacheDir): removeDir(nimcacheDir)
  let cmd = "nim c -o:" & exePath & " --nimcache:" & nimcacheDir &
    " --threads:on --path:src " & extraFlags & " tests" / (fixture & ".nim")
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
