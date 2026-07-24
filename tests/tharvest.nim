## RFC-0001 SS4 B.2/B.3 slice B3: harvester classification loop —
## integration + pure-classifier tests.
##
## NOT compiled by the regular test suite target (`test_softlink.nim`); run
## explicitly (`nim c -r --path:src tests/tharvest.nim`) by the `nimble
## test` task's Linux branch (harvester probing is real `nim c` subprocess
## work — kept out of the main suite's hot path, mirrors this file's own
## dump-generation cost, one real compile per (version, symbol) probed).
import std/[unittest, os, osproc, tables, strutils, json, times, posix, tempfiles]
import ../tools/harvest/harvester
import ../tools/harvest/harvest_cli
import softlink/versions
import softlink/manifest

# ---------------------------------------------------------------------------
# loadDump: parses one <Base>.probes.json (RFC-0001 SS4 B.1 schema; see
# softlink.nimble's validateProbeJson for the schema this mirrors, and
# src/softlink.nim's probeFactsJson for the emission side). RFC-0002 §6
# slice A1b adds `until` — mirroring `since` exactly, a per-proc value
# carried through ProbeFact but not yet consumed by any classification
# logic.
# ---------------------------------------------------------------------------
suite "loadDump — probe-facts dump parsing (RFC-0001 SS4 B.1, RFC-0002 §6 slice A1b)":
  test "since and until both roundtrip through ProbeFact":
    let dir = getTempDir() / "sl_harvest_loaddump_test"
    if dirExists(dir): removeDir(dir)
    createDir(dir)
    let dumpFile = dir / "Loaddumptest.probes.json"
    writeFile(dumpFile, """{
      "schemaVersion": 1,
      "kind": "dynlib",
      "modulePath": "tests/loaddumptest.nim",
      "libPattern": "libloaddumptest.so",
      "baseName": "Loaddumptest",
      "procs": [
        {
          "nimName": "foo",
          "cName": "foo",
          "header": "foo.h",
          "prototype": "",
          "verifyWhen": "",
          "optional": false,
          "noverify": false,
          "noverifyReason": "",
          "since": "1.2.3",
          "until": "4.5.6"
        }
      ]
    }""")
    let dump = loadDump(dumpFile)
    removeDir(dir)
    check dump.procs.len == 1
    check dump.procs[0].since == "1.2.3"
    check dump.procs[0].until == "4.5.6"

  test "an absent until pragma dumps as \"\", same as since":
    let dir = getTempDir() / "sl_harvest_loaddump_test_absent"
    if dirExists(dir): removeDir(dir)
    createDir(dir)
    let dumpFile = dir / "Loaddumptest.probes.json"
    writeFile(dumpFile, """{
      "schemaVersion": 1,
      "kind": "dynlib",
      "modulePath": "tests/loaddumptest.nim",
      "libPattern": "libloaddumptest.so",
      "baseName": "Loaddumptest",
      "procs": [
        {
          "nimName": "foo",
          "cName": "foo",
          "header": "foo.h",
          "prototype": "",
          "verifyWhen": "",
          "optional": false,
          "noverify": false,
          "noverifyReason": "",
          "since": "",
          "until": ""
        }
      ]
    }""")
    let dump = loadDump(dumpFile)
    removeDir(dir)
    check dump.procs[0].since == ""
    check dump.procs[0].until == ""

  # CR1-11 (code review): a pre-RFC-0002 probes.json — one written by an
  # older softlink that never emitted the `until` key at all (not even as
  # "", the RFC-0001 reserved-empty convention `since` used) — used to blow
  # up `loadDump` with a raw `json.KeyError` on `p["until"]` instead of a
  # helpful `HarvestError` telling the user to re-run the probe dump.
  test "a pre-RFC-0002 dump missing the 'until' key raises HarvestError, not KeyError":
    let dir = getTempDir() / "sl_harvest_loaddump_test_preuntil"
    if dirExists(dir): removeDir(dir)
    createDir(dir)
    let dumpFile = dir / "Loaddumptest.probes.json"
    # Deliberately omits "until" (and, for good measure, mirrors a genuinely
    # pre-RFC-0002 dump by leaving every other RFC-0001 key present) —
    # exactly what an older softlink's `probeFactsJson` produced before
    # RFC-0002 slice A1b added the `until` key.
    writeFile(dumpFile, """{
      "schemaVersion": 1,
      "kind": "dynlib",
      "modulePath": "tests/loaddumptest.nim",
      "libPattern": "libloaddumptest.so",
      "baseName": "Loaddumptest",
      "procs": [
        {
          "nimName": "foo",
          "cName": "foo",
          "header": "foo.h",
          "prototype": "",
          "verifyWhen": "",
          "optional": false,
          "noverify": false,
          "noverifyReason": "",
          "since": ""
        }
      ]
    }""")
    var raised = false
    var isHarvestError = false
    var msg = ""
    try:
      discard loadDump(dumpFile)
    except HarvestError as e:
      raised = true
      isHarvestError = true
      msg = e.msg
    except KeyError as e:
      raised = true
      isHarvestError = false
      msg = e.msg
    removeDir(dir)
    check raised
    check isHarvestError
    check dumpFile in msg
    check "schema" in msg or "re-run" in msg or "predates" in msg

  test "a dump missing several RFC-0001/RFC-0002 proc keys raises HarvestError, not KeyError":
    let dir = getTempDir() / "sl_harvest_loaddump_test_minimal"
    if dirExists(dir): removeDir(dir)
    createDir(dir)
    let dumpFile = dir / "Loaddumptest.probes.json"
    # An even older/hand-trimmed dump missing several keys at once
    # (verifyWhen, noverifyReason, since, until) — proves loadDump's
    # hardening isn't limited to the one `until` key RFC-0002 added.
    writeFile(dumpFile, """{
      "schemaVersion": 1,
      "kind": "dynlib",
      "modulePath": "tests/loaddumptest.nim",
      "libPattern": "libloaddumptest.so",
      "baseName": "Loaddumptest",
      "procs": [
        {
          "nimName": "foo",
          "cName": "foo",
          "header": "foo.h",
          "prototype": "",
          "optional": false,
          "noverify": false
        }
      ]
    }""")
    var raised = false
    var isHarvestError = false
    try:
      discard loadDump(dumpFile)
    except HarvestError:
      raised = true
      isHarvestError = true
    except KeyError:
      raised = true
      isHarvestError = false
    removeDir(dir)
    check raised
    check isHarvestError

# ---------------------------------------------------------------------------
# Pure classifier: every arm of RFC-0003 §5.2(ii)'s stage-enum + evidence-set
# `ProbeOutcomes` shape, superseding RFC-0001 SS4 B.2's original boolean-bag
# table (`baselineOk`/`existenceOk`/`verifyOk`/`assertMsgSeen`) — including
# the FLIPPED pin below, where RFC-0001 round-2's fall-through-to-`unknown`
# design ("a verify failure for some other reason is not a signature
# mismatch") is narrowed by RFC-0003's isolation argument (§3.1): an isolated
# verify failure that is NOT confirmed non-decisive (`veUnavailable`) IS now
# `fkMismatch`, not `fkUnknown`.
# ---------------------------------------------------------------------------
suite "classify — pure decision table (RFC-0003 §5.2 ii)":
  test "psBaselineFailed -> unknown, regardless of evidence":
    check classify(ProbeOutcomes(stage: psBaselineFailed)) == fkUnknown

  test "psAbsent -> absent":
    check classify(ProbeOutcomes(stage: psAbsent)) == fkAbsent

  test "psVerified -> verified":
    check classify(ProbeOutcomes(stage: psVerified)) == fkVerified

  test "psVerifyFailed, empty evidence -> mismatch (FLIPPED PIN, RFC-0003 §5.2 ii)":
    ## RFC-0001 round-2 pinned this exact case ("verify fails WITHOUT the
    ## assert message") to `fkUnknown` — the old design's blanket
    ## fall-through for any non-assert-confirmed verify failure. RFC-0003's
    ## per-symbol isolation argument (§3.1) narrows that: the verify TU's
    ## ONLY delta over the already-green existence TU is the probed
    ## symbol's own assert chain, dummy call, and dummy parameter
    ## declarations, so a failure here that carries no `veUnavailable`
    ## evidence (i.e. verification was NOT structurally unavailable, and
    ## the failure reproduced deterministically — orchestration's job, not
    ## classify's) really is a signature problem, whether or not softlink's
    ## own fixed assert text happened to also fire (RFC-0003 §5's
    ## hard-incompatible-pointer-argument case never reaches the assert at
    ## all, yet is exactly as decisive).
    check classify(ProbeOutcomes(stage: psVerifyFailed, evidence: {})) == fkMismatch

  test "psVerifyFailed, veAssertMsg only -> mismatch (confirming evidence, not the verdict)":
    check classify(ProbeOutcomes(stage: psVerifyFailed,
                                  evidence: {veAssertMsg})) == fkMismatch

  test "psVerifyFailed, veUnavailable only -> unknown":
    check classify(ProbeOutcomes(stage: psVerifyFailed,
                                  evidence: {veUnavailable})) == fkUnknown

  test "psVerifyFailed, veAssertMsg AND veUnavailable -> unknown (veUnavailable wins)":
    ## Representable (the assert text can textually appear in the same
    ## output as the strict-mode needle, e.g. a mismatch that ALSO happens
    ## to degrade tier) but `veUnavailable`'s "no trustworthy evidence
    ## exists" reading takes priority — `classify`'s case checks it first.
    check classify(ProbeOutcomes(stage: psVerifyFailed,
                                  evidence: {veAssertMsg, veUnavailable})) == fkUnknown

# ---------------------------------------------------------------------------
# verifyEvidence — pure evidence extraction from a failed verify compile's
# output (RFC-0003 §5.2 ii/iii). No I/O: exercised entirely against
# synthetic strings, independent of ever forcing a real degraded-tier or
# mismatched compile.
# ---------------------------------------------------------------------------
suite "verifyEvidence — pure evidence extraction (RFC-0003 §5.2 ii/iii)":
  test "neither needle present -> empty evidence set":
    check verifyEvidence("some unrelated compiler error") == {}

  test "softlink's own assert text present -> veAssertMsg only":
    check verifyEvidence("error: softlink: foo signature mismatch vs foo.h") ==
      {veAssertMsg}

  test "the strict-mode unavailability needle present -> veUnavailable only":
    check verifyEvidence("#error \"softlink: signature verification " &
      "unavailable here (need C++, GCC/Clang, or MSVC /std:clatest)\"") ==
      {veUnavailable}

  test "both needles present -> both evidence bits set":
    let output = "softlink: foo signature mismatch vs foo.h\n" &
      "softlink: signature verification unavailable here"
    check verifyEvidence(output) == {veAssertMsg, veUnavailable}

# ---------------------------------------------------------------------------
# infraFailureReason — pure detection of a transient INFRASTRUCTURE failure
# (OOM-killed cc1, ICE, signal-terminated compiler exit) vs. a genuine
# compile failure (RFC-0003 §5.2 ii, "decisive requires deterministic").
# Purely string/int-driven — no real OOM or ICE is ever forced in CI.
# ---------------------------------------------------------------------------
suite "infraFailureReason — pure infra-failure detection (RFC-0003 §5.2 ii)":
  test "ordinary failure output, ordinary exit code -> empty (not infra-shaped)":
    check infraFailureReason("foo.h:3: error: unknown type name 'bar'", 1) == ""

  test "\"internal compiler error\" in output -> non-empty reason":
    check infraFailureReason("gcc: internal compiler error: Segmentation fault", 1).len > 0

  test "\"Killed signal terminated program\" in output -> non-empty reason":
    check infraFailureReason(
      "gcc: internal compiler error: Killed signal terminated program cc1", 1).len > 0

  test "a signal-terminated exit code (128+signum) -> non-empty reason, even with clean output":
    # 137 == 128 + SIGKILL(9), the shell/exitStatusLikeShell convention a
    # POSIX-killed child reports.
    check infraFailureReason("", 137).len > 0

  test "exit code 128 itself (not > 128) is NOT treated as signal-terminated":
    check infraFailureReason("", 128) == ""

  test "an ordinary large-but-not-signal-shaped exit code is not infra-shaped":
    check infraFailureReason("", 1) == ""

# ---------------------------------------------------------------------------
# resolveVerifyRetry — the retry-once decision (RFC-0003 §5.2 ii), pure:
# given the first (already known to have failed, non-infra) and retry
# compiles' raw exit codes/output, decide abort / flaky-warn / decisive.
# `probeOutcomes` is the only caller that actually RUNS the retry compile;
# this function's job is fully exercisable with synthetic inputs.
# ---------------------------------------------------------------------------
suite "resolveVerifyRetry — pure retry-once decision (RFC-0003 §5.2 ii)":
  test "retry succeeds -> flaky: non-decisive outcome (fkUnknown via veUnavailable) + warning":
    let d = resolveVerifyRetry("foo", "/corpus/1.0.0", 1, 0, "")
    check not d.abort
    check d.outcome.stage == psVerifyFailed
    check d.outcome.evidence == {veUnavailable}
    check classify(d.outcome) == fkUnknown
    check d.warning.len > 0
    check "foo" in d.warning
    check "FLAKY" in d.warning

  test "retry fails again, infra-shaped -> abort":
    let d = resolveVerifyRetry("foo", "/corpus/1.0.0", 1, 1,
      "gcc: internal compiler error: Segmentation fault")
    check d.abort
    check d.abortReason.len > 0
    check "foo" in d.abortReason

  test "retry fails again, deterministic, WITH softlink's assert text -> decisive mismatch":
    let d = resolveVerifyRetry("foo", "/corpus/1.0.0", 1, 1,
      "softlink: foo signature mismatch vs foo.h")
    check not d.abort
    check d.outcome.stage == psVerifyFailed
    check d.outcome.evidence == {veAssertMsg}
    check classify(d.outcome) == fkMismatch
    check d.warning.len == 0

  test "retry fails again, deterministic, NO assert text, NO strict needle -> decisive mismatch (FLIPPED)":
    let d = resolveVerifyRetry("foo", "/corpus/1.0.0", 1, 1,
      "error: incompatible pointer types passing 'int *' to parameter of type 'bool *'")
    check not d.abort
    check d.outcome.stage == psVerifyFailed
    check d.outcome.evidence == {}
    check classify(d.outcome) == fkMismatch

  test "retry fails again, deterministic, strict needle present -> decisive unknown (tier unavailable)":
    let d = resolveVerifyRetry("foo", "/corpus/1.0.0", 1, 1,
      "softlink: signature verification unavailable here")
    check not d.abort
    check d.outcome.stage == psVerifyFailed
    check d.outcome.evidence == {veUnavailable}
    check classify(d.outcome) == fkUnknown

# ---------------------------------------------------------------------------
# bisectPlan — pure bisection helper (RFC-0001 SS4 B.2, optional fast-path
# slice B7). No I/O: driven entirely by synthetic "does this group pass?"
# callbacks, so every shape of bisection (all-pass, one-fail, all-fail,
# two-fail-in-different-halves, odd-sized groups, singleton input) is
# unit-tested here without a single real compile — `harvest`'s fast path
# supplies the real, compile-backed callback (`groupVerifies` in
# `tools/harvest/harvester.nim`), never re-implements this recursion.
# ---------------------------------------------------------------------------
suite "bisectPlan — pure bisection (RFC-0001 SS4 B.2, slice B7)":
  test "empty input -> empty plan, callback never invoked":
    var calls: seq[seq[string]] = @[]
    let plan = bisectPlan(@[], proc(g: seq[string]): bool =
      calls.add g
      true)
    check plan.verified.len == 0
    check plan.needsStandard.len == 0
    check calls.len == 0

  test "singleton input, passing -> verified, one call":
    var calls: seq[seq[string]] = @[]
    let plan = bisectPlan(@["a"], proc(g: seq[string]): bool =
      calls.add g
      true)
    check plan.verified == @["a"]
    check plan.needsStandard.len == 0
    check calls == @[@["a"]]

  test "singleton input, failing -> needsStandard, one call":
    var calls: seq[seq[string]] = @[]
    let plan = bisectPlan(@["a"], proc(g: seq[string]): bool =
      calls.add g
      false)
    check plan.verified.len == 0
    check plan.needsStandard == @["a"]
    check calls == @[@["a"]]

  test "all-pass group -> every symbol verified, exactly ONE call (the whole group)":
    var calls = 0
    let plan = bisectPlan(@["a", "b", "c", "d"], proc(g: seq[string]): bool =
      inc calls
      true)
    check plan.verified == @["a", "b", "c", "d"]
    check plan.needsStandard.len == 0
    check calls == 1

  test "all-fail group -> every symbol recurses down to needsStandard, none dropped":
    let plan = bisectPlan(@["a", "b", "c"], proc(g: seq[string]): bool = false)
    check plan.verified.len == 0
    check plan.needsStandard.len == 3
    for s in ["a", "b", "c"]:
      check s in plan.needsStandard

  test "one symbol fails among several -> only it lands in needsStandard":
    let bad = "c"
    let plan = bisectPlan(@["a", "b", "c", "d"], proc(g: seq[string]): bool =
      bad notin g)
    check plan.needsStandard == @["c"]
    check "a" in plan.verified
    check "b" in plan.verified
    check "d" in plan.verified
    check plan.verified.len == 3

  test "two failures in DIFFERENT halves -> both isolated, rest verified":
    let bads = ["b", "g"]  # symbol at index 1 (left half) and index 6 (right half) of 8
    let syms = @["a", "b", "c", "d", "e", "f", "g", "h"]
    let plan = bisectPlan(syms, proc(g: seq[string]): bool =
      for b in bads:
        if b in g: return false
      true)
    check plan.needsStandard.len == 2
    check "b" in plan.needsStandard
    check "g" in plan.needsStandard
    check plan.verified.len == 6
    for s in syms:
      if s notin bads:
        check s in plan.verified

  test "odd-sized group (5 symbols), one failure -> correct split, none dropped or duplicated":
    let syms = @["a", "b", "c", "d", "e"]
    let plan = bisectPlan(syms, proc(g: seq[string]): bool = "e" notin g)
    check plan.needsStandard == @["e"]
    check plan.verified.len == 4
    for s in ["a", "b", "c", "d"]:
      check s in plan.verified
    # Exhaustiveness/no-duplication: verified + needsStandard is exactly
    # the input set, each symbol exactly once.
    check (plan.verified & plan.needsStandard).len == syms.len

# ---------------------------------------------------------------------------
# Integration: real `nim c --noLinking` compiles against the B3a fixture
# corpus, driven by an actual B.1 dump of tests/tharvest_binding.nim — the
# dump-driven flow is exactly the real one (RFC-0001 SS4 B.2 design
# guidance point 5).
# ---------------------------------------------------------------------------
let dumpDir = getCurrentDir() / "tests" / "nimcache_tharvest_dump"
if dirExists(dumpDir): removeDir(dumpDir)
let dumpCmd = "nim c --compileOnly --path:src -d:softlinkDumpProbes=" &
  dumpDir & " tests/tharvest_binding.nim"
let (dumpOutput, dumpCode) = execCmdEx(dumpCmd)
doAssert dumpCode == 0,
  "softlink: RFC-0001 slice B3: failed to generate the B.1 probe-facts " &
  "dump for tests/tharvest_binding.nim, needed before the harvester " &
  "integration test can run:\n" & dumpOutput
let dumpFile = dumpDir / "Corpuslib.probes.json"
doAssert fileExists(dumpFile),
  "softlink: RFC-0001 slice B3: expected dump file to exist: " & dumpFile

# RFC-0003 slice B2c: which per-family diagnostic pin set to probe with is
# CALLER-controlled (§8 resolution 1 — no auto-detection anywhere in
# `harvester.nim` itself); softlink.nimble's `runHarvesterCheck` is the
# caller here, and it decides via this ONE `-d:` define, passed only on the
# macOS/clang CI leg (`clangLeg = true`) — mirroring every other
# `{.booldefine.}` switch this suite already uses
# (`softlinkProbeGroundTruth`, `softlinkHarvestSession`, etc. in
# `src/softlink.nim`). On every other leg this stays false and `harvest()`/
# `runCalibration()` get the gcc/clang-shared `defaultHarvestOptions()`
# exactly as before this slice.
const softlinkHarvestClangOpts {.booldefine.} = false
let baseOpts = if softlinkHarvestClangOpts: clangHarvestOptions()
               else: defaultHarvestOptions()

# Hoisted to file scope (rather than a suite-local `let`) so BOTH the
# "harvest — full classification matrix" suite below AND the slice-B5
# "driftAlarm — integration" suite further down can reuse this ONE real
# harvest — `unittest.suite` is `{.dirty.}` but still wraps its body in a
# `block:`, so a suite-local `let` is invisible from a sibling suite; only
# a genuinely file-scope binding is shared. Never re-harvested (real `nim
# c --noLinking` subprocess work, ~1 minute wall time — see
# `runHarvesterCheck`'s doc comment in softlink.nimble).
let r = harvest(dumpFile, "tests" / "corpus", baseOpts)

# RFC-0001 SS4 B.2, optional fast-path (slice B7): a SECOND real harvest of
# the IDENTICAL dump/corpus, with `opts.fastPath = true` — yes, this roughly
# doubles this file's already ~1-minute wall time; acceptable, since it's
# the only way to prove the fast path's `facts` are byte-for-byte identical
# to the standard path's on a real toolchain, not merely by inspection.
var fastOpts = baseOpts
fastOpts.fastPath = true
let rFast = harvest(dumpFile, "tests" / "corpus", fastOpts)

suite "harvest fastPath — identical facts to the standard path (RFC-0001 SS4 B.2, slice B7)":
  # RFC-0003 §7 slice A2 introduced three hand-written-gate fixture symbols
  # (`corpuslib_gated_until`, `corpuslib_gated_since`,
  # `corpuslib_gated_crosscheck` — see tests/corpus/README.md's "RFC-0003
  # slice A2" section) for which this invariant temporarily did NOT hold: A2
  # wired ground truth into `probeOutcomes` (shared by the standard path AND
  # the fast path's `plan.needsStandard`/`recordAlwaysProbed`-shaped
  # fallbacks) but deliberately left the fast path's OWN whole-module/
  # bisection-group compile sites untouched, so a closed gate was still
  # RESPECTED there — a bisection group (or the whole-module compile)
  # containing only a masked symbol compiled cleanly and `bisectPlan`
  # shortcut it straight to `verified` without ever calling `probeOutcomes`
  # at all. This slice (A3) wires the same two ground-truth defines into
  # BOTH of those fast-path sites (`harvest`'s own doc comment has the full
  # design), which is what makes the invariant below hold unconditionally
  # again, over EVERY probed symbol including the three gated ones — no
  # withoutGatedSymbols carve-out needed anymore.
  test "facts are deep-equal between the standard and fast-path harvests, " &
       "for every probed symbol (RFC-0003 §7 slice A3: ground truth now " &
       "reaches the fast path's own whole-module/bisection-group compiles " &
       "too, so no gated-symbol carve-out is needed)":
    check rFast.facts == r.facts

  test "baselineOk is deep-equal between the standard and fast-path harvests":
    check rFast.baselineOk == r.baselineOk

  test "skipped (corpus-invariant procs) is deep-equal between the two harvests":
    check rFast.skipped == r.skipped

  test "compile-count arithmetic on this fixture corpus (honest, derived, not assumed)":
    ## This fixture corpus has 10 probed symbols across 3 versions: the
    ## original 4 (code-review Finding #19.7 added `corpuslib_crosscheck`),
    ## RFC-0003 slice A2's three hand-written-gate fixtures
    ## (`corpuslib_gated_until`, `corpuslib_gated_since`,
    ## `corpuslib_gated_crosscheck`), RFC-0003 slice B2b's Gap B
    ## (parameter-drift) end-to-end fixture (`corpuslib_param_drift`,
    ## UNGATED — see tests/corpus/README.md), and RFC-0003 slice B2c's TWO
    ## tolerance-regression-control symbols (`corpuslib_const_return`,
    ## `corpuslib_const_param`, both UNGATED and non-drifting) — still far
    ## below the scale where O(k·log n) bisection wins over "up to 2
    ## compiles per symbol per version" (the standard path's own cost
    ## shape). Worked by hand and then confirmed against a real run.
    ## `probeTargets`' order (dump.procs order, `corpuslib_protoonly`
    ## excluded as corpus-invariant) is
    ## [stable, changed, added, crosscheck, gated_until, gated_since,
    ## gated_crosscheck, param_drift, const_return, const_param];
    ## `bisectPlan` splits a group of n into a left half of `n div 2` and a
    ## right half of the remainder.
    ##
    ## RFC-0003 §7 slice B2b's ONE new symbol, `corpuslib_param_drift`,
    ## drifts a POINTER PARAMETER only (`int *` -> `unsigned char *`,
    ## RETURN type held fixed at `int`), UNGATED. Existence mode
    ## (`sizeof(__typeof__(&sym))`) never calls the symbol, so it is
    ## completely signature-blind — existence passes at BOTH corpus
    ## versions regardless of the parameter drift, exactly like
    ## `corpuslib_changed`'s return-type-only drift before it. The verify
    ## probe's dummy call, however, passes the pinned `ptr cint` argument
    ## against 2.0.0's `unsigned char *` parameter — an incompatible-
    ## pointer-types diagnostic at the call site, pinned to a hard error by
    ## `defaultHarvestOptions`'s `-Werror=incompatible-pointer-types`
    ## (slice B2a) — so this symbol's own per-version accounting is
    ## IDENTICAL in shape to `corpuslib_changed`'s: verified@1.0.0 (2:
    ## existence+verify, both pass) and MISMATCH@2.0.0 (2 + 1 retry = 3:
    ## deterministic incompatible-pointer-types failure, confirmed on
    ## retry, no assert text needed — RFC-0003 §5.2 ii's FLIPPED pin).
    ##
    ## RFC-0003 §7 slice A2 wires `-d:softlinkProbeGroundTruth
    ## -d:softlinkHarvestSession` into every `probeOutcomes` compile
    ## (existence, verify, retry) AND the standard path's own baseline
    ## compile (inert there — `softlinkProbeOnly=-` suppresses every gate
    ## regardless). Slice A3 additionally wires the SAME two defines into
    ## the fast path's own whole-module compile and `groupVerifies`'
    ## bisection-group compiles (`harvest`'s own doc comment has the full
    ## design and the stamp-exclusion rationale for `header`+`prototype`
    ## procs). Neither slice changes the NUMBER of compiles `probeOutcomes`
    ## itself issues for a given classification — the defines are
    ## additional `-d:` text on the same compiler invocations, not an extra
    ## one — so the STANDARD path's compile count grows over the pre-A2
    ## count ONLY via the three new symbols' own existence/verify/retry
    ## compiles, using the exact same "up to 2 + 1 retry for a deterministic
    ## verify failure" accounting slice B1 established:
    ##
    ## - `corpuslib_gated_until`: verified@1.0.0 (2: existence+verify, both
    ##   pass — gate naturally open there, groundtruth doesn't change the
    ##   outcome), MISMATCH@2.0.0 (2 + 1 retry = 3: groundtruth defeats the
    ##   closed gate, the real return-type drift surfaces, deterministic).
    ## - `corpuslib_gated_since`: ABSENT@1.0.0 (1: existence only —
    ##   groundtruth defeats the closed gate, the header genuinely doesn't
    ##   declare it, existence fails, no verify attempted), verified@2.0.0
    ##   (2: existence+verify, both pass — gate naturally open there).
    ## - `corpuslib_gated_crosscheck`: verified@1.0.0 (2: existence+verify;
    ##   groundtruth ALSO suppresses this proc's own vendored {.prototype.}
    ##   decl in the verify probe per RFC-0003 §5.2(iv)/A1's `isProbedTarget`,
    ##   so the stale `double(int)` decl never conflicts with the header's
    ##   real `int(int)` — verified from the header alone), MISMATCH@2.0.0
    ##   (2 + 1 retry = 3: groundtruth defeats the closed gate, the real
    ##   return-type drift at 2.0.0 surfaces, deterministic).
    ##
    ## None of the three new symbols is ever probed at 3.0.0 (the shared
    ## baseline compile already fails there for every symbol, exactly as
    ## for the original four).
    ##
    ## STANDARD path, per version (the first 7 symbols' accounting is
    ## unchanged from A2/A3 — restated here for a self-contained derivation
    ## — plus B2b's `param_drift` line, derived above):
    ##   1.0.0: baseline(1) + stable verified(2) + changed verified(2) +
    ##          added ABSENT(1, existence only) + crosscheck verified(2) +
    ##          gated_until verified(2) + gated_since ABSENT(1) +
    ##          gated_crosscheck verified(2) + param_drift verified(2) = 15
    ##   2.0.0: baseline(1) + stable verified(2) +
    ##          changed MISMATCH(2 + 1 retry = 3) + added verified(2) +
    ##          crosscheck verified(2) + gated_until MISMATCH(3) +
    ##          gated_since verified(2) + gated_crosscheck MISMATCH(3) +
    ##          param_drift MISMATCH(3) = 21
    ##   3.0.0: baseline FAILS(1); every symbol unknown, 0 extra = 1
    ##   TOTAL = 15 + 21 + 1 = 37 (this was the standard-path total as of
    ##   slice B2b, i.e. before B2c's two additions — see the "RFC-0003
    ##   slice B2c" section below this derivation for the updated total).
    ##
    ## RFC-0003 slice B2c adds `corpuslib_const_return` and
    ## `corpuslib_const_param`, appended after `param_drift` in
    ## `tests/tharvest_binding.nim`. Both are UNGATED and declared with the
    ## BYTE-IDENTICAL signature at every reachable corpus version (see
    ## tests/corpus/README.md) — pure regression controls, never drifting —
    ## so each costs exactly the SAME "2: existence+verify, both pass" as
    ## `corpuslib_stable` at BOTH 1.0.0 and 2.0.0, and 0 extra at 3.0.0
    ## (shared baseline failure, same as every other symbol):
    ##   1.0.0: 15 (above) + const_return verified(2) + const_param
    ##          verified(2) = 19
    ##   2.0.0: 21 (above) + const_return verified(2) + const_param
    ##          verified(2) = 25
    ##   3.0.0: 1 (unchanged)
    ##   STANDARD TOTAL (post-B2c) = 19 + 25 + 1 = 45
    ##
    ## FAST path, per version. The A3 mechanism is unchanged (ground truth
    ## reaches BOTH fast-path compile sites — the whole-module define-free
    ## compile AND every `groupVerifies` bisection-group compile — and the
    ## `header`+`prototype` stamp exclusion still applies to `crosscheck`/
    ## `gated_crosscheck`, RFC-0003 §4.3) — see A3's own slice notes in
    ## RFC-0003.handoff.md for that mechanism's rationale, restated only
    ## briefly here. What DOES change with an 8th symbol is the bisection
    ## TREE ITSELF: `bisectPlan` splits n=8 at mid = 8 div 2 = 4 (not the
    ## previous n=7's mid=3), so `probeTargets`' unfiltered order
    ## [stable, changed, added, crosscheck, gated_until, gated_since,
    ## gated_crosscheck, param_drift] now splits into
    ## left{stable,changed,added,crosscheck} (4) and
    ## right{gated_until,gated_since,gated_crosscheck,param_drift} (4) —
    ## `crosscheck` moves from the old right group into the new left group,
    ## and `param_drift` joins the new right group. The whole tree is
    ## re-derived from first principles below rather than patched, since
    ## group membership genuinely shifted, not just grew.
    ##
    ## Per-member pass/fail WITHIN a group compile naming it (ground truth
    ## defeats every gate unconditionally and suppresses each named
    ## member's own vendored decl, per A3):
    ##   1.0.0: stable PASS, changed PASS (pinned to the true 1.0.0
    ##          signature), added FAIL (header never declares it),
    ##          crosscheck PASS (header alone, decl suppressed), gated_until
    ##          PASS (gate defeated but genuinely valid — 100 < 200 was true
    ##          anyway), gated_since FAIL (gate defeated, header truly
    ##          doesn't declare it), gated_crosscheck PASS (decl suppressed,
    ##          header alone matches the pinned 1.0.0 int(int) signature),
    ##          param_drift PASS (header's `int *` matches the pinned
    ##          `ptr cint` exactly at 1.0.0 — no drift here yet). Two
    ##          failures: added, gated_since.
    ##   2.0.0: stable PASS, changed FAIL (real unconditional mismatch),
    ##          added PASS (now declared, matches the pinned 2.0.0
    ##          signature), crosscheck PASS, gated_until FAIL (gate
    ##          defeated, real drift surfaces), gated_since PASS (gate open
    ##          at 200 anyway, genuinely valid), gated_crosscheck FAIL (gate
    ##          defeated, decl suppressed, header's own real double(int)
    ##          drift vs the pinned int(int) binding), param_drift FAIL
    ##          (header's `unsigned char *` vs the pinned `ptr cint` —
    ##          incompatible-pointer-types, pinned to a hard error by
    ##          B2a). FOUR failures: changed, gated_until, gated_crosscheck,
    ##          param_drift.
    ##
    ##   1.0.0 tree: define-free FAILS(1) [added, gated_since] -> baseline
    ##          ok(1) -> bisect{stable,changed,added,crosscheck,gated_until,
    ##          gated_since,gated_crosscheck,param_drift} (8 elems; root
    ##          splits mid=4 into left{stable,changed,added,crosscheck} (4),
    ##          right{gated_until,gated_since,gated_crosscheck,param_drift}
    ##          (4)):
    ##            root FAILS(1) [added, gated_since]
    ##            left{stable,changed,added,crosscheck} FAILS(1) [added],
    ##            splits mid=2 into {stable,changed} (2) and
    ##            {added,crosscheck} (2):
    ##              {stable,changed} PASSES together(1) [both fine at
    ##              1.0.0] -> both verified, no further split
    ##              {added,crosscheck} FAILS(1) [added], splits into
    ##              {added} FAILS(1) singleton -> needsStandard,
    ##              {crosscheck} PASSES(1) singleton -> verified
    ##            right{gated_until,gated_since,gated_crosscheck,
    ##            param_drift} FAILS(1) [gated_since], splits mid=2 into
    ##            {gated_until,gated_since} (2) and
    ##            {gated_crosscheck,param_drift} (2):
    ##              {gated_until,gated_since} FAILS(1) [gated_since], splits
    ##              into {gated_until} PASSES(1) singleton -> verified,
    ##              {gated_since} FAILS(1) singleton -> needsStandard
    ##              {gated_crosscheck,param_drift} PASSES together(1) [both
    ##              fine at 1.0.0 — decl suppression keeps gated_crosscheck
    ##              matching the header alone, param_drift hasn't drifted
    ##              yet] -> both verified, no further split
    ##          = 11 group compiles -> needsStandard{added,gated_since} ->
    ##          added existence-only(1, absent) + gated_since
    ##          existence-only(1, absent) = 2
    ##          1.0.0 TOTAL = 1 + 1 + 11 + 2 = 15
    ##
    ##   2.0.0 tree: define-free FAILS(1) [changed, gated_until,
    ##          gated_crosscheck, param_drift] -> baseline ok(1) -> bisect
    ##          (same 8, same order; root splits mid=4 into
    ##          left{stable,changed,added,crosscheck} (4),
    ##          right{gated_until,gated_since,gated_crosscheck,param_drift}
    ##          (4)):
    ##            root FAILS(1) [changed, gated_until, gated_crosscheck,
    ##            param_drift]
    ##            left{stable,changed,added,crosscheck} FAILS(1) [changed],
    ##            splits mid=2 into {stable,changed} (2) and
    ##            {added,crosscheck} (2):
    ##              {stable,changed} FAILS(1) [changed], splits into
    ##              {stable} PASSES(1) singleton -> verified, {changed}
    ##              FAILS(1) singleton -> needsStandard
    ##              {added,crosscheck} PASSES together(1) [both fine at
    ##              2.0.0] -> both verified, no further split
    ##            right{gated_until,gated_since,gated_crosscheck,
    ##            param_drift} FAILS(1) [gated_until, gated_crosscheck,
    ##            param_drift] — THIS is where the ≥2-gate-masked-culprits-
    ##            at-one-version requirement (RFC-0003 §4.3) is exercised,
    ##            now with THREE culprits sharing one group instead of two
    ##            — splits mid=2 into {gated_until,gated_since} (2) and
    ##            {gated_crosscheck,param_drift} (2):
    ##              {gated_until,gated_since} FAILS(1) [gated_until], splits
    ##              into {gated_until} FAILS(1) singleton -> needsStandard,
    ##              {gated_since} PASSES(1) singleton -> verified
    ##              {gated_crosscheck,param_drift} FAILS(1) [both — decl
    ##              suppression is irrelevant here since gated_crosscheck's
    ##              drift is real and header-visible regardless, and
    ##              param_drift's pointer drift is independent of it],
    ##              splits into {gated_crosscheck} FAILS(1) singleton ->
    ##              needsStandard, {param_drift} FAILS(1) singleton ->
    ##              needsStandard
    ##          = 13 group compiles -> needsStandard{changed,gated_until,
    ##          gated_crosscheck,param_drift} -> changed
    ##          existence+verify+retry(3, mismatch) + gated_until
    ##          existence+verify+retry(3, mismatch) + gated_crosscheck
    ##          existence+verify+retry(3, mismatch) + param_drift
    ##          existence+verify+retry(3, mismatch — the SAME "up to 2 + 1
    ##          retry for a deterministic verify failure" accounting as
    ##          every other mismatch here) = 12
    ##          2.0.0 TOTAL = 1 + 1 + 13 + 12 = 27
    ##   3.0.0: define-free FAILS(1) [broken #include] -> baseline ALSO
    ##          FAILS(1); every symbol unknown, no bisection = 1 + 1 = 2
    ##   TOTAL = 15 + 27 + 2 = 44 (this was the fast-path total as of slice
    ##   B2b, before B2c's two additions — see immediately below for the
    ##   n=10 re-derivation).
    ##
    ## RFC-0003 slice B2c: with `corpuslib_const_return`/
    ## `corpuslib_const_param` appended, n grows from 8 to 10 — the
    ## bisection TREE ITSELF changes (not just grows): `bisectPlan` now
    ## splits n=10 at mid = 10 div 2 = 5 (not the previous n=8's mid=4), so
    ## `probeTargets`' unfiltered order [stable, changed, added, crosscheck,
    ## gated_until, gated_since, gated_crosscheck, param_drift,
    ## const_return, const_param] now splits into
    ## left{stable,changed,added,crosscheck,gated_until} (5) and
    ## right{gated_since,gated_crosscheck,param_drift,const_return,
    ## const_param} (5) — `gated_until` moves from the old right group into
    ## the new left group (pulled in by the mid shift), and both new
    ## symbols join the new right group. Re-derived from first principles
    ## (both new symbols PASS at every reachable version, by construction):
    ##
    ##   1.0.0 tree: define-free FAILS(1) [added, gated_since] -> baseline
    ##          ok(1) -> bisect (10 elems; root splits mid=5):
    ##            root FAILS(1) [added, gated_since]
    ##            left{stable,changed,added,crosscheck,gated_until} FAILS(1)
    ##            [added], splits mid=2 into {stable,changed} (2) and
    ##            {added,crosscheck,gated_until} (3):
    ##              {stable,changed} PASSES together(1) -> both verified
    ##              {added,crosscheck,gated_until} FAILS(1) [added], splits
    ##              mid=1 into {added} (1) and {crosscheck,gated_until} (2):
    ##                {added} FAILS(1) singleton -> needsStandard
    ##                {crosscheck,gated_until} PASSES together(1) [both fine
    ##                at 1.0.0] -> both verified
    ##              left subtotal = 1 + 1 + (1 + 1 + 1) = 5
    ##            right{gated_since,gated_crosscheck,param_drift,
    ##            const_return,const_param} FAILS(1) [gated_since], splits
    ##            mid=2 into {gated_since,gated_crosscheck} (2) and
    ##            {param_drift,const_return,const_param} (3):
    ##              {gated_since,gated_crosscheck} FAILS(1) [gated_since],
    ##              splits mid=1 into {gated_since} FAILS(1) singleton ->
    ##              needsStandard, {gated_crosscheck} PASSES(1) singleton ->
    ##              verified
    ##              {param_drift,const_return,const_param} PASSES
    ##              together(1) [all three fine at 1.0.0 — param_drift
    ##              hasn't drifted yet, the two new symbols never drift] ->
    ##              all three verified
    ##              right subtotal = 1 + (1 + 1 + 1) + 1 = 5
    ##          = 1(root) + 5(left) + 5(right) = 11 group compiles ->
    ##          needsStandard{added,gated_since} -> added existence-only(1,
    ##          absent) + gated_since existence-only(1, absent) = 2
    ##          1.0.0 TOTAL = 1 + 1 + 11 + 2 = 15 (UNCHANGED from n=8 — the
    ##          two new always-passing symbols land inside an
    ##          already-all-pass leaf and need no extra splits here).
    ##
    ##   2.0.0 tree: define-free FAILS(1) [changed, gated_until,
    ##          gated_crosscheck, param_drift] -> baseline ok(1) -> bisect
    ##          (same 10, same order; root splits mid=5):
    ##            root FAILS(1) [changed, gated_until, gated_crosscheck,
    ##            param_drift]
    ##            left{stable,changed,added,crosscheck,gated_until} FAILS(1)
    ##            [changed, gated_until], splits mid=2 into {stable,changed}
    ##            (2) and {added,crosscheck,gated_until} (3):
    ##              {stable,changed} FAILS(1) [changed], splits mid=1 into
    ##              {stable} PASSES(1) singleton -> verified, {changed}
    ##              FAILS(1) singleton -> needsStandard
    ##              {added,crosscheck,gated_until} FAILS(1) [gated_until],
    ##              splits mid=1 into {added} (1) and
    ##              {crosscheck,gated_until} (2):
    ##                {added} PASSES(1) singleton -> verified
    ##                {crosscheck,gated_until} FAILS(1) [gated_until],
    ##                splits mid=1 into {crosscheck} PASSES(1) singleton ->
    ##                verified, {gated_until} FAILS(1) singleton ->
    ##                needsStandard
    ##                subtotal = 1 + 1 + (1 + 1 + 1) = 5
    ##              left subtotal = 1 + (1+1+1) + 5 = 9
    ##            right{gated_since,gated_crosscheck,param_drift,
    ##            const_return,const_param} FAILS(1) [gated_crosscheck,
    ##            param_drift] — THIS is where the ≥2-gate-masked-culprits-
    ##            at-one-version requirement (RFC-0003 §4.3) is exercised —
    ##            splits mid=2 into {gated_since,gated_crosscheck} (2) and
    ##            {param_drift,const_return,const_param} (3):
    ##              {gated_since,gated_crosscheck} FAILS(1)
    ##              [gated_crosscheck], splits mid=1 into {gated_since}
    ##              PASSES(1) singleton -> verified, {gated_crosscheck}
    ##              FAILS(1) singleton -> needsStandard
    ##              {param_drift,const_return,const_param} FAILS(1)
    ##              [param_drift], splits mid=1 into {param_drift} FAILS(1)
    ##              singleton -> needsStandard, {const_return,const_param}
    ##              (2) PASSES together(1) [both fine at 2.0.0, never
    ##              drift] -> both verified
    ##              right subtotal = 1 + (1+1+1) + (1+1+1) = 7
    ##          = 1(root) + 9(left) + 7(right) = 17 group compiles ->
    ##          needsStandard{changed,gated_until,gated_crosscheck,
    ##          param_drift} -> changed existence+verify+retry(3, mismatch)
    ##          + gated_until existence+verify+retry(3, mismatch) +
    ##          gated_crosscheck existence+verify+retry(3, mismatch) +
    ##          param_drift existence+verify+retry(3, mismatch) = 12
    ##          2.0.0 TOTAL = 1 + 1 + 17 + 12 = 31 (up from n=8's 27 — the
    ##          +4 comes entirely from the LEFT group: the mid shift (4->5)
    ##          pulled `gated_until` into the left group, which now needs an
    ##          extra split it didn't before; the right group's own subtotal
    ##          is unchanged at 7 despite gaining the two new members,
    ##          because they land in an already-failing-then-passing-
    ##          together leaf that costs the same either way).
    ##   3.0.0: define-free FAILS(1) [broken #include] -> baseline ALSO
    ##          FAILS(1); every symbol unknown, no bisection = 1 + 1 = 2
    ##          (unchanged — independent of symbol count).
    ##   FAST TOTAL (post-B2c) = 15 + 31 + 2 = 48
    ##
    ## So on THIS fixture the fast path continues to cost MORE real
    ## compiles than the standard path (48 > 45, up from B2b's 44 > 37) —
    ## consistent with every prior slice's finding here: ground truth's
    ## per-symbol correctness cost keeps outpacing bisection's savings on a
    ## fixture this small. This assertion pins the CONCRETE,
    ## derived-then-confirmed counts rather than a directional
    ## "fewer"/"more" claim.
    check r.compileCount == 45
    check rFast.compileCount == 48

# ---------------------------------------------------------------------------
# RFC-0003 stage-4 review, finding M1: the fast-path STAMP EXCLUSION
# (`harvester.nim`'s `harvest`, the `fast.exitCode == 0` block — see that
# proc's own doc comment, "Stamp exclusion", and RFC-0003-ground-truth-
# harvest.md §4.3) is UNREACHABLE against the committed `tests/corpus`
# fixture: every one of its three versions fails the whole-module
# define-free compile (1.0.0/2.0.0 via `corpuslib_added`/`corpuslib_gated_
# since` being absent and multiple symbols drifting, 3.0.0 via the broken
# `#include`), so `fast.exitCode == 0` — the ONLY branch that stamps
# anything for free at all, and the branch the exclusion lives inside of —
# never happens anywhere in this file's `r`/`rFast` harvests above. A
# regression that deletes the exclusion (stamping header+prototype procs
# `fkVerified` for free too, exactly like every other prototype-free proc)
# would pass the whole suite silently.
#
# This suite reaches the branch directly: a DEDICATED, single-version
# synthetic corpus + a minimal binding module (its own dump, deliberately
# NOT `tests/tharvest_binding.nim`) whose header cleanly satisfies every
# probed symbol — the one shape that actually drives `fast.exitCode == 0`.
#
# Reusing the full `tests/tharvest_binding.nim` (this finding's own FIRST
# recommendation) turns out to be structurally impossible, not merely
# inconvenient: `corpuslib_gated_crosscheck`'s vendored
# `{.prototype: "double corpuslib_gated_crosscheck(int a)".}` string is
# permanently stale relative to the Nim proc's OWN declared `cint` return
# type, at every corpus version. The whole-module compile shape (no
# `softlinkProbeOnly` at all) makes `isProbedTarget` false for every proc
# unconditionally (§4.3), so the standard path's vendored-decl suppression
# never applies there and BOTH the header's real declaration and the
# vendored prototype declaration are always emitted together: a header
# state that agrees with the Nim-declared `cint` type conflicts with the
# stale `double` prototype (hard redeclaration error), and a header state
# that agrees with the stale prototype instead fails softlink's own
# generated assert against the Nim-declared `cint` type. No header state
# makes that PARTICULAR fixture's whole module compile cleanly, at any
# version — so a fresh, minimal binding (one header-only proc, one
# header+prototype proc whose vendored prototype is NOT stale) is used
# instead, per this finding's documented fallback.
# ---------------------------------------------------------------------------
suite "harvest fastPath — stamp exclusion (RFC-0003 stage-4 review finding M1)":
  test "a header+prototype proc is individually probed, never free-stamped, when the whole-module compile passes cleanly":
    # RFC-0003 round-2 review R2-4: race-free `createTempDir` (production
    # `freshDir`'s own precedent) instead of a predictable fixed name under
    # the shared, world-writable `getTempDir()`. Prefix avoids the
    # `sl_harvest_` substring on the same principle as the M4 suite's own
    # documented pitfall further down this file (that suite's gcc-wrapper
    # grep genuinely depends on it; this suite doesn't, but there's no
    # reason to risk a future refactor colliding with it either).
    let dir = createTempDir("sl_faststamp_", "")

    # Single-version synthetic corpus whose header declares BOTH probed
    # symbols with the exact signature the binding below pins — nothing
    # here ever drifts, so the whole-module compile is clean by
    # construction (no gates, no absent symbols, no baseline breakage).
    let corpusDir = dir / "corpus"
    let v1 = corpusDir / "1.0.0"
    createDir(v1)
    writeFile(v1 / "fastpathlib.h", """
#ifndef FASTPATHLIB_H
#define FASTPATHLIB_H
#ifdef __cplusplus
extern "C" {
#endif
int fp_stable(int a);
int fp_crosscheck(int a);
#ifdef __cplusplus
}
#endif
#endif
""")

    let modulePath = dir / "fastpath_binding.nim"
    writeFile(modulePath, """
import softlink

dynlib "libfastpathprobe.so":
  proc fp_stable(a: cint): cint {.cdecl, header: "fastpathlib.h".}
  proc fp_crosscheck(a: cint): cint
    {.cdecl, header: "fastpathlib.h", prototype: "int fp_crosscheck(int a)".}
""")

    let dumpDir = dir / "dump"
    let dumpCmd = "nim c --compileOnly --path:src -d:softlinkDumpProbes=" &
      dumpDir & " " & modulePath
    let (dumpOutput, dumpCode) = execCmdEx(dumpCmd)
    doAssert dumpCode == 0,
      "softlink: RFC-0003 M1 fixture: failed to generate the B.1 probe-facts " &
      "dump for the minimal fast-path binding:\n" & dumpOutput
    let dumpFile = dumpDir / "Fastpathprobe.probes.json"
    doAssert fileExists(dumpFile),
      "softlink: RFC-0003 M1 fixture: expected dump file to exist: " & dumpFile

    var opts = baseOpts
    opts.fastPath = true
    let r = harvest(dumpFile, corpusDir, opts)
    removeDir(dir)

    # Compile-count arithmetic (this file's own convention — see the
    # "harvest fastPath" suite above for the fuller derivation style):
    #   1: the whole-module define-free compile itself
    #      (`fast.exitCode == 0` — proving the fast path's own shortcut is
    #      what actually ran here, unlike the committed 3-version corpus
    #      where this branch is never reached at all).
    #   `fp_stable` (header-only, no `{.prototype.}`): +0 — stamped
    #      `fkVerified` directly off the clean whole-module compile, the
    #      intended fast-path shortcut this finding is NOT about.
    #   `fp_crosscheck` (header+prototype): +2 — the §4.3 stamp exclusion
    #      falls through to an individual `probeOutcomes` call (existence
    #      compile + verify compile; both pass outright, so no retry-once
    #      compile is needed) instead of a free stamp.
    #   TOTAL = 1 + 0 + 2 = 3.
    #
    # This is the assertion that actually pins the exclusion: `fp_crosscheck`
    # genuinely DOES verify (its vendored prototype isn't stale), so a
    # regression that deletes the exclusion and free-stamps it anyway would
    # still produce the SAME `fkVerified` fact below — only the compile
    # count exposes that the individual probe never ran.
    check r.compileCount == 3
    check r.baselineOk.getOrDefault("1.0.0", false)
    check r.facts["fp_stable"]["1.0.0"] == fkVerified
    check r.facts["fp_crosscheck"]["1.0.0"] == fkVerified

suite "runCalibration — preflight (RFC-0001 SS4 B.2)":
  test "the dev toolchain's own known-answer quad classifies correctly":
    # RFC-0003 slice B2c: uses the SAME leg-selected `baseOpts` as `r`/
    # `rFast` above (not the bare `defaultHarvestOptions()` default this
    # call relied on before this slice) — so slice B3's
    # `calib_param_drifted` symbol (the fixture's fourth member as of this
    # slice) is exercised against `clangHarvestOptions()` on the macOS/clang
    # CI leg too, not silently against gcc's pin set there.
    let outcome = runCalibration(baseOpts)
    check outcome.ok
    check outcome.diagnosis.len == 0

suite "HarvestOptions pins (RFC-0003 5.2 i/B2a)":
  ## Pure checks over the opts LITERALS/constructions — no compiler
  ## invoked. `defaultHarvestOptions` is the gcc/clang-shared leg;
  ## `clangHarvestOptions` layers the clang-specific pin on top for the
  ## clang CI leg. Caller-controlled per SS8 resolution 1 — no auto-
  ## detection anywhere; the actual macOS/clang CI wiring that PASSES
  ## `clangHarvestOptions()` to a real clang compile is slice B2c's job,
  ## not this one's.
  test "defaultHarvestOptions carries the shared incompatible-pointer-types pin":
    check "--passC:-Werror=incompatible-pointer-types" in defaultHarvestOptions().extraFlags

  test "clangHarvestOptions layers the clang-only incompatible-function-pointer-types pin on top of the shared pin":
    let opts = clangHarvestOptions()
    check "--passC:-Werror=incompatible-pointer-types" in opts.extraFlags
    check "--passC:-Werror=incompatible-function-pointer-types" in opts.extraFlags

  test "clangHarvestOptions otherwise matches defaultHarvestOptions (nimPaths/includeFlagPrefix/timeouts)":
    let base = defaultHarvestOptions()
    let clang = clangHarvestOptions()
    check clang.nimPaths == base.nimPaths
    check clang.includeFlagPrefix == base.includeFlagPrefix
    check clang.compileTimeoutMs == base.compileTimeoutMs
    check clang.maxOutputBytes == base.maxOutputBytes

suite "runCalibration — baseline retry-without-pins diagnosis (RFC-0003 5.2 i)":
  ## Splits the calibration BASELINE failure diagnosis into two shapes:
  ## a diagnostics pin flag this toolchain doesn't recognize (retry
  ## WITHOUT the pins succeeds) vs. a genuinely broken toolchain/PATH
  ## (retry WITHOUT the pins ALSO fails). Both refuse identically
  ## (`CalibrationOutcome(ok: false, ...)`) — only the diagnosis TEXT
  ## differs, so an operator is pointed at the right layer.
  test "baseline fails WITH an unrecognized -Werror pin, succeeds WITHOUT it -> 'pin rejected' diagnosis":
    var opts = defaultHarvestOptions()
    opts.extraFlags.add("--passC:-Werror=softlink-rfc0003-b2a-bogus-diagnostic-does-not-exist")
    let outcome = runCalibration(opts)
    check not outcome.ok
    check "pin" in outcome.diagnosis
    check "rejected by this toolchain" in outcome.diagnosis
    check "toolchain/PATH itself" notin outcome.diagnosis

  test "baseline fails WITH and WITHOUT pins (broken --cc) -> unchanged genuinely-broken-toolchain diagnosis":
    var opts = defaultHarvestOptions()
    opts.extraFlags.add("--cc:softlinkDoesNotExistBogusCompilerB2a")
    let outcome = runCalibration(opts)
    check not outcome.ok
    check "toolchain/PATH itself" in outcome.diagnosis
    check "pin" notin outcome.diagnosis

suite "calib_param_drifted — pin load-bearing proof (RFC-0003 §5.2 i, §5.3, §7 B3)":
  ## Mirrors the `corpuslib_param_drift` "pin load-bearing proof" suite
  ## (B2b, above) but exercises the CALIBRATION fixture's own fourth
  ## known-answer symbol through `runCalibration` end to end, rather than a
  ## bare `probeOutcomes` call against a corpus fixture — B3 makes the
  ## pin↔classify coupling itself self-verifying (§5.3): a toolchain where
  ## the diagnostics-severity pin is absent, stripped, or ineffective must
  ## REFUSE TO HARVEST AT ALL (`CalibrationOutcome(ok: false, ...)`, naming
  ## `calib_param_drifted`), never silently revert to Gap B.
  test "PINNED (default/leg) opts: runCalibration passes; calib_param_drifted classifies fkMismatch":
    let outcome = runCalibration(baseOpts)
    check outcome.ok
    check outcome.observed.getOrDefault("calib_param_drifted", fkUnknown) == fkMismatch

  test "SIMULATED-PERMISSIVE opts (pin explicitly downgraded to a warning, " &
       "the B2b counterfactual): runCalibration REFUSES, diagnosis naming " &
       "calib_param_drifted":
    var permissiveOpts = baseOpts
    permissiveOpts.extraFlags.add("--passC:-Wno-error=incompatible-pointer-types")
    let outcome = runCalibration(permissiveOpts)
    check not outcome.ok
    check "calib_param_drifted" in outcome.diagnosis

suite "compressFacts — interval compression (RFC-0001 SS4 B.3, slice B4)":
  ## Pure compression edge cases. `compressFacts` walks an already-
  ## `cmpVersion`-ordered `versions` seq and a per-version `FactKind` table
  ## (every version carries EXACTLY one `FactKind` — total by construction,
  ## since `harvest`'s loop always assigns one) into the four half-open
  ## `VersionInterval` seqs. Disjoint+exhaustive falls out of the run-
  ## grouping construction itself (see the doc comment on `compressFacts`);
  ## these tests pin the boundary-omission rules and the shared-boundary
  ## property directly.
  test "all-same-kind over the whole corpus -> one interval, BOTH bounds omitted":
    let versions = @["1.0.0", "2.0.0", "3.0.0"]
    let perVersion = {"1.0.0": fkVerified, "2.0.0": fkVerified, "3.0.0": fkVerified}.toTable
    let compressed = compressFacts(versions, perVersion)
    check compressed[fkVerified] == @[VersionInterval(lo: "", hi: "")]
    check compressed[fkAbsent].len == 0
    check compressed[fkMismatch].len == 0
    check compressed[fkUnknown].len == 0

  test "single-version corpus -> one interval, both bounds omitted":
    let versions = @["1.0.0"]
    let perVersion = {"1.0.0": fkAbsent}.toTable
    let compressed = compressFacts(versions, perVersion)
    check compressed[fkAbsent] == @[VersionInterval(lo: "", hi: "")]

  test "alternating A/B/A -> three intervals; the middle one has BOTH bounds":
    let versions = @["1.0.0", "2.0.0", "3.0.0"]
    let perVersion = {"1.0.0": fkVerified, "2.0.0": fkMismatch, "3.0.0": fkVerified}.toTable
    let compressed = compressFacts(versions, perVersion)
    check compressed[fkVerified] == @[VersionInterval(lo: "", hi: "2.0.0"),
                                       VersionInterval(lo: "3.0.0", hi: "")]
    check compressed[fkMismatch] == @[VersionInterval(lo: "2.0.0", hi: "3.0.0")]
    check compressed[fkAbsent].len == 0
    check compressed[fkUnknown].len == 0

  test "adjacent runs share the boundary version EXACTLY once (disjointness proof)":
    # One run's exclusive `hi` must equal the NEXT run's inclusive `lo`,
    # verbatim as a string — this is the property that makes the emitted
    # intervals disjoint (never off-by-one on which side owns the boundary).
    let versions = @["1.0.0", "2.0.0", "3.0.0", "4.0.0"]
    let perVersion = {"1.0.0": fkVerified, "2.0.0": fkVerified,
                       "3.0.0": fkMismatch, "4.0.0": fkUnknown}.toTable
    let compressed = compressFacts(versions, perVersion)
    check compressed[fkVerified] == @[VersionInterval(lo: "", hi: "3.0.0")]
    check compressed[fkMismatch] == @[VersionInterval(lo: "3.0.0", hi: "4.0.0")]
    check compressed[fkUnknown] == @[VersionInterval(lo: "4.0.0", hi: "")]
    # The shared boundaries, spelled out:
    check compressed[fkVerified][0].hi == compressed[fkMismatch][0].lo
    check compressed[fkMismatch][0].hi == compressed[fkUnknown][0].lo

  # Finding #19.6 (code-review coverage gap): `compressFacts`' own
  # `if versions.len == 0: return` early-out (an empty corpus — no version
  # directories at all) had no test at all; every existing case above has
  # at least one version. A truly empty corpus should compress to the
  # ZERO value: all four FactKind interval seqs empty, no runs, no
  # `perVersion` lookups ever attempted (an empty `Table` here would
  # `KeyError` on any lookup, so this also proves the function returns
  # before indexing `perVersion` at all).
  test "empty corpus (no versions at all) -> every FactKind interval seq is empty":
    let compressed = compressFacts(@[], initTable[string, FactKind]())
    check compressed[fkVerified].len == 0
    check compressed[fkAbsent].len == 0
    check compressed[fkMismatch].len == 0
    check compressed[fkUnknown].len == 0

suite "buildManifest — pure manifest JSON (RFC-0001 SS4 B.3, slice B4)":
  ## Small synthetic `HarvestResult`s — no real compiles — to pin the
  ## structural rules design guidance calls out: `lib` derivation,
  ## omit-empty-fact-keys, and skipped (corpus-invariant) procs never
  ## getting a `symbols` entry. The full real-corpus shape is the golden
  ## fixture test below (reuses the already-harvested `r`, doesn't re-harvest).
  let meta = HarvestMeta(toolchain: "test-cc", tier: "builtin-compat",
                          abi: "linux-lp64", date: "2026-01-01")

  test "lib field is toLowerAscii(baseName)":
    var hr: HarvestResult
    hr.baseName = "Corpuslib"
    hr.versions = @["1.0.0"]
    hr.probedSymbols = @[]
    let j = buildManifest(hr, @[], meta)
    check j["lib"].getStr == "corpuslib"
    check j["schema"].getInt == 1

  test "only non-empty fact keys are emitted under header":
    var hr: HarvestResult
    hr.baseName = "Foo"
    hr.versions = @["1.0.0", "2.0.0"]
    hr.probedSymbols = @["foo_sym"]
    hr.facts["foo_sym"] = {"1.0.0": fkVerified, "2.0.0": fkVerified}.toTable
    let j = buildManifest(hr, @[], meta)
    let header = j["symbols"]["foo_sym"]["header"]
    check header.hasKey("verified")
    check not header.hasKey("absent")
    check not header.hasKey("mismatch")
    check not header.hasKey("unknown")
    check header["verified"] == %*[{}]  # whole-corpus run: both bounds omitted

  test "skipped (corpus-invariant) procs never get a symbols entry":
    var hr: HarvestResult
    hr.baseName = "Foo"
    hr.versions = @["1.0.0"]
    hr.probedSymbols = @["foo_probed"]
    hr.facts["foo_probed"] = {"1.0.0": fkVerified}.toTable
    hr.skipped = @[SkipNote(cname: "foo_protoonly", reason: "prototype-only")]
    let j = buildManifest(hr, @[], meta)
    check j["symbols"].hasKey("foo_probed")
    check not j["symbols"].hasKey("foo_protoonly")

  test "corpus provenance carries version+source, in order":
    var hr: HarvestResult
    hr.baseName = "Foo"
    hr.versions = @["1.0.0", "2.0.0"]
    let corpus = @[("1.0.0", "git:example/foo@aaaa"), ("2.0.0", "git:example/foo@bbbb")]
    let j = buildManifest(hr, corpus, meta)
    check j["corpus"].len == 2
    check j["corpus"][0]["version"].getStr == "1.0.0"
    check j["corpus"][0]["source"].getStr == "git:example/foo@aaaa"
    check j["corpus"][1]["version"].getStr == "2.0.0"

  # RFC-0003 §2/§7 slice C1: `HarvestMeta.harvesterVersion` -- provenance
  # metadata, "omit unless present" (same convention `header`'s interval
  # bounds already use).
  test "harvesterVersion omitted from the harvest object when meta doesn't set it " &
       "(backward-compatible default -- `meta` above, like every pre-C1 pinned " &
       "HarvestMeta literal, never sets this field)":
    var hr: HarvestResult
    hr.baseName = "Foo"
    hr.versions = @["1.0.0"]
    let j = buildManifest(hr, @[], meta)
    check not j["harvest"].hasKey("harvesterVersion")

  test "harvesterVersion emitted verbatim when meta sets it":
    var hr: HarvestResult
    hr.baseName = "Foo"
    hr.versions = @["1.0.0"]
    let stampedMeta = HarvestMeta(toolchain: "test-cc", tier: "builtin-compat",
                                   abi: "linux-lp64", date: "2026-01-01",
                                   harvesterVersion: "9.9.9-test")
    let j = buildManifest(hr, @[], stampedMeta)
    check j["harvest"]["harvesterVersion"].getStr == "9.9.9-test"

  test "defaultHarvestMeta() stamps harvesterVersion == softlink/versions.softlinkVersion":
    check defaultHarvestMeta().harvesterVersion == softlinkVersion

suite "driftAlarm — pure decision (RFC-0001 SS4 B.4, slice B5)":
  ## Synthetic `HarvestResult`s — no real compiles. Pins the spec-gap
  ## resolution the slice brief hands down: the default support range is
  ## the ENTIRE harvested corpus (an unbounded `VersionInterval`), and an
  ## explicit narrowed range uses the SAME half-open, ""-unbounded
  ## semantics as B0/B4 (`cmpVersion`-compared, lo inclusive, hi exclusive).

  test "no mismatch anywhere -> not tripped, empty diagnosis":
    var hr: HarvestResult
    hr.probedSymbols = @["foo"]
    hr.versions = @["1.0.0", "2.0.0"]
    hr.facts["foo"] = {"1.0.0": fkVerified, "2.0.0": fkVerified}.toTable
    let (tripped, diag) = driftAlarm(hr)
    check not tripped
    check diag.len == 0

  test "one mismatch, default (whole-corpus) range -> tripped; names symbol + version + verbatim F3 sentence":
    var hr: HarvestResult
    hr.probedSymbols = @["foo"]
    hr.versions = @["1.0.0", "2.0.0"]
    hr.facts["foo"] = {"1.0.0": fkVerified, "2.0.0": fkMismatch}.toTable
    let (tripped, diag) = driftAlarm(hr)
    check tripped
    check "foo" in diag
    check "2.0.0" in diag
    check f3Sentence in diag

  test "mismatch OUTSIDE an explicit narrowed range -> not tripped":
    var hr: HarvestResult
    hr.probedSymbols = @["foo"]
    hr.versions = @["1.0.0", "2.0.0", "3.0.0"]
    hr.facts["foo"] = {"1.0.0": fkVerified, "2.0.0": fkMismatch, "3.0.0": fkVerified}.toTable
    let (tripped, diag) = driftAlarm(hr, VersionInterval(hi: "2.0.0"))
    check not tripped
    check diag.len == 0

  test "mismatch exactly AT lo (inclusive) -> tripped":
    var hr: HarvestResult
    hr.probedSymbols = @["foo"]
    hr.versions = @["1.0.0", "2.0.0"]
    hr.facts["foo"] = {"1.0.0": fkVerified, "2.0.0": fkMismatch}.toTable
    let (tripped, _) = driftAlarm(hr, VersionInterval(lo: "2.0.0"))
    check tripped

  test "mismatch exactly AT hi (exclusive) -> NOT tripped":
    var hr: HarvestResult
    hr.probedSymbols = @["foo"]
    hr.versions = @["1.0.0", "2.0.0"]
    hr.facts["foo"] = {"1.0.0": fkVerified, "2.0.0": fkMismatch}.toTable
    let (tripped, _) = driftAlarm(hr, VersionInterval(hi: "2.0.0"))
    check not tripped

  test "unknown inside range -> not tripped (inconclusive is not an alarm)":
    var hr: HarvestResult
    hr.probedSymbols = @["foo"]
    hr.versions = @["1.0.0", "2.0.0"]
    hr.facts["foo"] = {"1.0.0": fkVerified, "2.0.0": fkUnknown}.toTable
    let (tripped, _) = driftAlarm(hr)
    check not tripped

  test "multiple offending symbols -> all named in the diagnosis":
    var hr: HarvestResult
    hr.probedSymbols = @["foo", "bar"]
    hr.versions = @["1.0.0", "2.0.0"]
    hr.facts["foo"] = {"1.0.0": fkVerified, "2.0.0": fkMismatch}.toTable
    hr.facts["bar"] = {"1.0.0": fkMismatch, "2.0.0": fkVerified}.toTable
    let (tripped, diag) = driftAlarm(hr)
    check tripped
    check "foo" in diag
    check "bar" in diag

suite "harvest — full classification matrix against the B3a fixture corpus":
  ## `r` is the file-scope real harvest defined above (shared with the
  ## slice-B5 `driftAlarm` integration suite further down) — not a
  ## suite-local `let` (see that binding's own doc comment for why).

  test "corpus versions enumerated in version order":
    check r.versions == @["1.0.0", "2.0.0", "3.0.0"]

  test "baseline compiles: 1.0.0/2.0.0 ok, 3.0.0 (broken include) fails":
    check r.baselineOk["1.0.0"]
    check r.baselineOk["2.0.0"]
    check not r.baselineOk["3.0.0"]

  test "corpuslib_stable: verified at 1.0.0 and 2.0.0, unknown at 3.0.0":
    check r.facts["corpuslib_stable"]["1.0.0"] == fkVerified
    check r.facts["corpuslib_stable"]["2.0.0"] == fkVerified
    check r.facts["corpuslib_stable"]["3.0.0"] == fkUnknown

  test "corpuslib_changed: verified at 1.0.0 (pinned signature), mismatch at 2.0.0, unknown at 3.0.0":
    check r.facts["corpuslib_changed"]["1.0.0"] == fkVerified
    check r.facts["corpuslib_changed"]["2.0.0"] == fkMismatch
    check r.facts["corpuslib_changed"]["3.0.0"] == fkUnknown

  test "corpuslib_added: absent at 1.0.0, verified at 2.0.0, unknown at 3.0.0":
    check r.facts["corpuslib_added"]["1.0.0"] == fkAbsent
    check r.facts["corpuslib_added"]["2.0.0"] == fkVerified
    check r.facts["corpuslib_added"]["3.0.0"] == fkUnknown

  # Finding #19.7 (code-review coverage gap): `corpuslib_crosscheck` is
  # bound with BOTH `header` AND `prototype` together (softlink's
  # cross-check mode) — no prior harvester fixture combined the two. Same
  # true, unchanging signature/classification story as `corpuslib_stable`
  # above; the point of this test is that it gets PROBED at all (`else:
  # probeTargets.add(p)` in `harvest`'s skip-classification loop only
  # skips a symbol as "prototype-only, corpus-invariant" when `header` is
  # ABSENT — a symbol carrying both never takes that branch).
  test "corpuslib_crosscheck (header + prototype together): verified at 1.0.0 and 2.0.0, unknown at 3.0.0":
    check "corpuslib_crosscheck" in r.probedSymbols
    check r.facts["corpuslib_crosscheck"]["1.0.0"] == fkVerified
    check r.facts["corpuslib_crosscheck"]["2.0.0"] == fkVerified
    check r.facts["corpuslib_crosscheck"]["3.0.0"] == fkUnknown

  # RFC-0003 §7 slice A2's Gap A fixture: `corpuslib_gated_until` drifts
  # 1.0.0 -> 2.0.0 exactly like `corpuslib_changed`, but ALSO carries a
  # hand `{.verifyWhen: "CORPUSLIB_VERSION < 200".}` gate + `{.until:
  # "2.0.0".}` that CLOSES precisely at the drift version. BEFORE this
  # slice wired ground truth into `probeOutcomes`, the harvester recorded
  # `fkVerified` at 2.0.0 (RED evidence, captured against the harvester as
  # it existed before this slice's change to `tools/harvest/harvester.nim`:
  # the closed gate elided the assert entirely, the verify probe compiled
  # trivially, and the real drift was masked) — a false confirmation at
  # exactly the version the gate exists to protect against. Ground truth
  # defeats the gate inside the probe TU, so the real drift now surfaces.
  test "corpuslib_gated_until (RFC-0003 Gap A): verified at 1.0.0 (gate open), " &
       "MISMATCH at 2.0.0 (gate closed but ground truth defeats it), unknown at 3.0.0":
    check r.facts["corpuslib_gated_until"]["1.0.0"] == fkVerified
    check r.facts["corpuslib_gated_until"]["2.0.0"] == fkMismatch
    check r.facts["corpuslib_gated_until"]["3.0.0"] == fkUnknown

  # RFC-0003 §4.5's since+hand-verifyWhen companion: `corpuslib_gated_since`
  # is absent from 1.0.0's header entirely, added at 2.0.0, and gated OPEN
  # starting at 2.0.0 (`{.verifyWhen: "CORPUSLIB_VERSION >= 200".}` +
  # `{.since: "2.0.0".}`). BEFORE this slice, the closed gate at 1.0.0
  # elided BOTH the existence reference and the assert, so the probe
  # trivially compiled even though the header never declares the symbol at
  # all — RED evidence: `fkVerified` at 1.0.0 (should be `fkAbsent`).
  # Ground truth defeats the gate, so the existence probe genuinely runs
  # and correctly fails at 1.0.0.
  test "corpuslib_gated_since (RFC-0003 sec4.5): ABSENT at 1.0.0 (gate closed but " &
       "ground truth defeats it), verified at 2.0.0 (gate open), unknown at 3.0.0":
    check r.facts["corpuslib_gated_since"]["1.0.0"] == fkAbsent
    check r.facts["corpuslib_gated_since"]["2.0.0"] == fkVerified
    check r.facts["corpuslib_gated_since"]["3.0.0"] == fkUnknown

  # RFC-0003 §5.2(iv)'s stale-vendored-prototype fixture:
  # `corpuslib_gated_crosscheck` pins 1.0.0's TRUE signature (`int(int)`)
  # via `header`, but its vendored `{.prototype.}` string
  # ("double corpuslib_gated_crosscheck(int a)") matches 2.0.0's (drifted)
  # signature instead — stale at 1.0.0, the version the binding claims
  # validity for. BEFORE A1's verify-probe suppression of the probed
  # symbol's own vendored decl was actually WIRED INTO A REAL PROBE COMPILE
  # (this slice, A2 — A1 alone built the mechanism but nothing in the
  # harvester exercised it), the stale ungated `extern double(...)` decl
  # conflicted with the header's real `int(int)` declaration at file scope
  # — RED evidence: `fkMismatch` at 1.0.0, a false mismatch from scaffolding
  # freshness, not from the header's own truth. With ground truth actually
  # wired in, only the header's declaration is checked at 1.0.0, and it
  # matches the binding's pinned signature: `fkVerified`, from the header
  # alone — exactly §5.2(iv)'s claim. This symbol also carries the same
  # closing gate + `until: "2.0.0"` as `corpuslib_gated_until` (its own true
  # signature drifts at 2.0.0 too), so it doubles as a second Gap A proof.
  test "corpuslib_gated_crosscheck (RFC-0003 sec5.2 iv): verified at 1.0.0 " &
       "(header alone, stale vendored decl suppressed), MISMATCH at 2.0.0 " &
       "(gate closed but ground truth defeats it), unknown at 3.0.0":
    check "corpuslib_gated_crosscheck" in r.probedSymbols
    check r.facts["corpuslib_gated_crosscheck"]["1.0.0"] == fkVerified
    check r.facts["corpuslib_gated_crosscheck"]["2.0.0"] == fkMismatch
    check r.facts["corpuslib_gated_crosscheck"]["3.0.0"] == fkUnknown

  # RFC-0003 §7 slice B2b's Gap B (parameter-drift) end-to-end fixture:
  # `corpuslib_param_drift` holds its RETURN type fixed (`int`) across both
  # corpus versions and drifts ONLY the parameter's pointee type (`int *` ->
  # `unsigned char *`) — the nim-z3 `Z3_fpa_get_numeral_sign` shape (RFC-0003
  # §1/§2). Originally UNGATED (no verifyWhen/since/until) to isolate Gap B
  # from Gap A. softlink's own return-type-only `_Static_assert` chain has
  # nothing to catch here at all; the ONLY place the drift can surface is
  # the C compiler's own incompatible-pointer-types diagnostic at the dummy
  # call site inside the verify probe (Gap B), which `defaultHarvestOptions`'s
  # `-Werror=incompatible-pointer-types` pin (slice B2a) makes a hard error,
  # reclassified `fkMismatch` by the isolation argument (RFC-0003 §5.2 ii).
  # This is real end-to-end proof against `r` (the standard-path harvest);
  # the identical assertions against `rFast` immediately below prove the
  # fast path lands on the SAME decisive fact (not merely inheriting it via
  # the "facts are deep-equal" invariant test, which this symbol also feeds).
  #
  # RFC-0003 §7 slice C1 composes a hand `{.verifyWhen: "CORPUSLIB_VERSION <
  # 200".}` gate + `{.until: "2.0.0".}` onto THIS symbol (tests/
  # tharvest_binding.nim) — the SAME identifiers/facts asserted below are
  # the regression proof that composing a gate changes NOTHING about what
  # ground truth records here: gate-defeat (§4) is unconditional regardless
  # of which fix (A or B) makes the underlying drift decisive, so these two
  # tests are byte-for-byte identical to their pre-C1 form. See
  # tests/tharvest.nim's "checkUntil confirms the declared bound for
  # corpuslib_param_drift" test (below, same suite) for what's actually NEW
  # at the manifest-consumption layer.
  test "corpuslib_param_drift (RFC-0003 Gap B, standard path): verified at " &
       "1.0.0 (pinned signature matches exactly), MISMATCH at 2.0.0 " &
       "(pointer parameter drift, caught only via the dummy call), unknown at 3.0.0":
    check r.facts["corpuslib_param_drift"]["1.0.0"] == fkVerified
    check r.facts["corpuslib_param_drift"]["2.0.0"] == fkMismatch
    check r.facts["corpuslib_param_drift"]["3.0.0"] == fkUnknown

  test "corpuslib_param_drift (RFC-0003 Gap B, FAST path): identical facts " &
       "to the standard path — verified at 1.0.0, MISMATCH at 2.0.0, " &
       "unknown at 3.0.0":
    check rFast.facts["corpuslib_param_drift"]["1.0.0"] == fkVerified
    check rFast.facts["corpuslib_param_drift"]["2.0.0"] == fkMismatch
    check rFast.facts["corpuslib_param_drift"]["3.0.0"] == fkUnknown

  # RFC-0003 §7 slice B2c's tolerance regression controls (RFC-0003 §5.2 i:
  # the B2a/B2b diagnostic-severity pins must NOT reverse GH #11's
  # const-tolerance — if either of these two symbols ever classified
  # `fkMismatch`, that would be a genuine RFC-invalidating finding, not
  # something to patch around). Both are UNGATED and declared with the
  # BYTE-IDENTICAL signature at every reachable corpus version (see
  # tests/corpus/README.md's "RFC-0003 slice B2c" section) — `fkUnknown` at
  # 3.0.0 is the SAME broken-baseline story every other symbol in this
  # fixture shares (tests/corpus/3.0.0/testlib.h's broken `#include`), not
  # anything specific to these two.
  #
  # `corpuslib_const_return`: RETURN-position GH #11 shape — the header
  # declares `const char *corpuslib_const_return(void);`, bound with Nim
  # return type `cstring`. This is the exact GH #11 shape (see
  # `src/softlink/verify.nim`'s `retIsPointerLike`/dereference-based
  # tolerance and `tests/test_softlink.nim`'s pre-existing
  # `testlib_const_string`/`testlib_const_lookup` unit-level regressions),
  # extended into the harvest/corpus world for the first time: proves
  # ground truth (which defeats every gate unconditionally) and the B2a/
  # B2b pins don't somehow make the RETURN-position tolerance mechanism
  # regress under a real harvest.
  test "corpuslib_const_return (RFC-0003 B2c, GH #11 return-position): " &
       "verified at 1.0.0 and 2.0.0, unknown at 3.0.0":
    check "corpuslib_const_return" in r.probedSymbols
    check r.facts["corpuslib_const_return"]["1.0.0"] == fkVerified
    check r.facts["corpuslib_const_return"]["2.0.0"] == fkVerified
    check r.facts["corpuslib_const_return"]["3.0.0"] == fkUnknown

  test "corpuslib_const_return (RFC-0003 B2c, FAST path): identical facts " &
       "to the standard path":
    check rFast.facts["corpuslib_const_return"]["1.0.0"] == fkVerified
    check rFast.facts["corpuslib_const_return"]["2.0.0"] == fkVerified
    check rFast.facts["corpuslib_const_return"]["3.0.0"] == fkUnknown

  # `corpuslib_const_param`: PARAMETER-position tolerance shape — the
  # mirror of #11 for `verify.nim`'s OTHER const-tolerant code path (the
  # dummy-call mechanism, doc comment: "enabling const-tolerant param
  # checking (int* implicitly converts to const int* in C)"), never
  # previously covered by ANY fixture in this repo. The header declares
  # `int corpuslib_const_param(const char *s);`; the binding declares Nim
  # param type `cstring`, so the emitted (non-const) `char *` dummy var is
  # passed into the header's `const char *` parameter at the verify
  # probe's call site — a standard, warning-free C qualifier ADDITION
  # (char* -> const char*), never a "discards qualifiers" diagnostic (that
  # reverse direction would need a const-qualified Nim-side dummy var,
  # which Nim's type system has no way to produce — see
  # tests/corpus/README.md for the full derivation of why this, not a
  # literal "discards qualifiers" shape, is the mechanically-achievable
  # regression control).
  test "corpuslib_const_param (RFC-0003 B2c, param-position tolerance): " &
       "verified at 1.0.0 and 2.0.0, unknown at 3.0.0":
    check "corpuslib_const_param" in r.probedSymbols
    check r.facts["corpuslib_const_param"]["1.0.0"] == fkVerified
    check r.facts["corpuslib_const_param"]["2.0.0"] == fkVerified
    check r.facts["corpuslib_const_param"]["3.0.0"] == fkUnknown

  test "corpuslib_const_param (RFC-0003 B2c, FAST path): identical facts " &
       "to the standard path":
    check rFast.facts["corpuslib_const_param"]["1.0.0"] == fkVerified
    check rFast.facts["corpuslib_const_param"]["2.0.0"] == fkVerified
    check rFast.facts["corpuslib_const_param"]["3.0.0"] == fkUnknown

  test "corpuslib_protoonly is skipped, never probed":
    check r.skipped.len == 1
    check r.skipped[0].cname == "corpuslib_protoonly"
    check "prototype-only" in r.skipped[0].reason
    check "corpuslib_protoonly" notin r.probedSymbols

  test "the human-readable report mentions every probed symbol and the skip":
    check "corpuslib_stable" in r.report
    check "corpuslib_changed" in r.report
    check "corpuslib_added" in r.report
    check "corpuslib_crosscheck" in r.report
    check "corpuslib_gated_until" in r.report
    check "corpuslib_gated_since" in r.report
    check "corpuslib_gated_crosscheck" in r.report
    check "corpuslib_param_drift" in r.report
    check "corpuslib_const_return" in r.report
    check "corpuslib_const_param" in r.report
    check "SKIPPED corpuslib_protoonly" in r.report

  test "checkSince confirms the declared bound for corpuslib_gated_since " &
       "(RFC-0003 sec4.5 acceptance: rule lands on the confirming arm)":
    ## Uses the REAL harvested manifest built further down this file (the
    ## golden-fixture test immediately below constructs `m` the same way;
    ## duplicated narrowly here rather than hoisting `m` to file scope,
    ## since every other consumer of a parsed manifest in this suite
    ## already re-derives it locally too). `checkSince` has no "unknown at
    ## or above since" rule (unlike `checkUntil`'s rule (b')) — it only
    ## flags `fkAbsent` at-or-above `since` and `verified`/`mismatch`/
    ## `unknown` below it — so this fixture corpus's persistent 3.0.0
    ## broken-baseline tail (every symbol unknown there) does not
    ## contaminate this check the way it would `checkUntil`'s (see the
    ## corpuslib_changed "checkUntil against the REAL harvested manifest"
    ## test below for that asymmetry). Ground truth's fix is what makes
    ## this a genuine confirmation rather than an accident: pre-A2, the
    ## masked `fkVerified` at 1.0.0 would ALSO have passed this exact
    ## check (checkSince only looks for the WRONG kind of evidence below
    ## `since` — verified/mismatch/unknown — and a masked false-`verified`
    ## there would have been just as absent from that list as a correct
    ## `fkAbsent` is), so this test alone cannot distinguish the fix; the
    ## classification-matrix test above (RED-evidenced against the
    ## pre-slice harvester) is what proves the underlying fact is now
    ## actually correct, not merely accidentally passing this rule.
    let meta = HarvestMeta(toolchain: "gcc (pinned for golden test)",
                            tier: "builtin-compat", abi: "linux-lp64",
                            date: "2026-01-01")
    let corpus = loadCorpusProvenance("tests" / "corpus")
    let manifestJson = buildManifest(r, corpus, meta)
    let m = parseManifest($manifestJson, "tests/corpus/expected.compat.json")
    let sc = checkSince(m, "corpuslib_gated_since", "2.0.0")
    check not sc.contradicted

  test "checkUntil confirms the declared bound for corpuslib_gated_until " &
       "(RFC-0003 Gap A acceptance: rule lands on the confirming arm)":
    ## This fixture corpus's OWN 3.0.0 entry never classifies decisively
    ## for ANY symbol (broken baseline, see the harvest-classification
    ## suite above) — `checkUntil`'s rule (b')/R2-A therefore contradicts
    ## EVERY `until <= "2.0.0"` declaration on ANY symbol in the FULL
    ## 3-version manifest, as the pre-existing `corpuslib_changed`
    ## "checkUntil against the REAL harvested manifest" test above
    ## demonstrates directly — that is an orthogonal, pre-existing
    ## artifact of THIS corpus's broken 3.0.0 tail, not something RFC-0003
    ## introduces or needs to fix. To isolate THIS acceptance bullet's
    ## actual claim (§1/§9: "checkUntil then confirms until: ... —
    ## mismatch at-or-above the bound is the expected outcome, verified-
    ## below the supporting evidence") from that unrelated artifact, this
    ## test repackages the SAME real, ground-truth-corrected fact VALUES
    ## `r` already harvested (`r.facts["corpuslib_gated_until"]` at 1.0.0
    ## and 2.0.0 — no re-harvest) into a synthetic 2-version
    ## `HarvestResult`/manifest whose corpus stops at 2.0.0, exactly
    ## mirroring the real Z3 4.13.3->4.16.0 two-version-transition example
    ## the RFC's own §1/§5.3 walks through.
    var hr: HarvestResult
    hr.baseName = "Corpuslib"
    hr.versions = @["1.0.0", "2.0.0"]
    hr.probedSymbols = @["corpuslib_gated_until"]
    hr.facts["corpuslib_gated_until"] = {
      "1.0.0": r.facts["corpuslib_gated_until"]["1.0.0"],
      "2.0.0": r.facts["corpuslib_gated_until"]["2.0.0"],
    }.toTable
    let meta = HarvestMeta(toolchain: "gcc (pinned for golden test)",
                            tier: "builtin-compat", abi: "linux-lp64",
                            date: "2026-01-01")
    let corpus = @[("1.0.0", "git:example/testlib@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
                    ("2.0.0", "git:example/testlib@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")]
    let manifestJson = buildManifest(hr, corpus, meta)
    let m = parseManifest($manifestJson, "<synthetic 2-version corpuslib_gated_until manifest>")
    let uc = checkUntil(m, "corpuslib_gated_until", "", "2.0.0")
    check not uc.contradicted

  test "checkUntil confirms the declared bound for corpuslib_param_drift " &
       "(RFC-0003 slice C1: the confirmation loop, end to end, composed onto " &
       "Gap B's param-drift symbol -- no fourth from-scratch drift symbol)":
    ## RFC-0003 §7 C1 composes `until: \"2.0.0\"` + the identical closing
    ## `{.verifyWhen: \"CORPUSLIB_VERSION < 200\".}` gate `corpuslib_gated_
    ## until` already carries onto B2b's ALREADY-committed `corpuslib_param_
    ## drift` symbol (tests/tharvest_binding.nim) — the RFC's own
    ## instruction is to reuse this symbol rather than invent a fourth
    ## from-scratch drift fixture. Unlike `corpuslib_gated_until` above
    ## (a Gap A / return-type drift), this symbol's drift is Gap B-shaped
    ## (parameter-only — the return type never changes, only the pointer
    ## parameter's pointee type), so this is the first fixture to compose
    ## BOTH fixes on one symbol: ground truth (Gap A's fix) defeats the
    ## gate in the probe TU exactly as it does for `corpuslib_gated_until`,
    ## and the underlying fact it uncovers is decisive only because of Gap
    ## B's fix (the `-Werror=incompatible-pointer-types` pin + isolation
    ## reclassify, B2a/B1). The classification-matrix suite above already
    ## proves the harvested FACTS are byte-for-byte unchanged from B2b's
    ## ungated shape (`fkVerified@1.0.0`, `fkMismatch@2.0.0`,
    ## `fkUnknown@3.0.0`) — this test is the NEW claim C1 adds: with a real
    ## `until` now declared, `checkUntil` POSITIVELY CONFIRMS it. Same
    ## synthetic-2-version-corpus isolation as the `corpuslib_gated_until`
    ## test immediately above, for the identical reason (this fixture
    ## corpus's own unclassified 3.0.0 tail would otherwise trip rule (b')
    ## unconditionally for ANY until <= "2.0.0", masking this acceptance
    ## bullet's actual claim) — repackages the SAME real, already-harvested
    ## fact values (`r.facts["corpuslib_param_drift"]` at 1.0.0/2.0.0, no
    ## re-harvest) into a synthetic 2-version manifest.
    var hr: HarvestResult
    hr.baseName = "Corpuslib"
    hr.versions = @["1.0.0", "2.0.0"]
    hr.probedSymbols = @["corpuslib_param_drift"]
    hr.facts["corpuslib_param_drift"] = {
      "1.0.0": r.facts["corpuslib_param_drift"]["1.0.0"],
      "2.0.0": r.facts["corpuslib_param_drift"]["2.0.0"],
    }.toTable
    let meta = HarvestMeta(toolchain: "gcc (pinned for golden test)",
                            tier: "builtin-compat", abi: "linux-lp64",
                            date: "2026-01-01")
    let corpus = @[("1.0.0", "git:example/testlib@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
                    ("2.0.0", "git:example/testlib@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")]
    let manifestJson = buildManifest(hr, corpus, meta)
    let m = parseManifest($manifestJson, "<synthetic 2-version corpuslib_param_drift manifest>")
    let uc = checkUntil(m, "corpuslib_param_drift", "", "2.0.0")
    check not uc.contradicted

  test "classifyAbsence yields mrExpected (acExpected) for corpuslib_gated_since's " &
       "absent symbol, against the REAL harvested manifest (RFC-0003 slice C1: " &
       "reusing A2's removal/absence fixture, no new symbol)":
    ## RFC-0003 §7 C1's second acceptance claim: `classifyAbsence` yields
    ## `mrExpected` for "the removal fixture's absent symbol" — reusing A2's
    ## `corpuslib_gated_since` (absent@1.0.0 under ground truth, added at
    ## 2.0.0, gated `{.since: "2.0.0".}`) rather than inventing a new
    ## symbol. Driven off the REAL harvested manifest (not a hand-built
    ## `mkManifest`, unlike test_softlink.nim's own classifyAbsence suite),
    ## so this is genuine end-to-end proof that ground truth's real,
    ## defeated-gate `fkAbsent@1.0.0` fact (not a masked false `fkVerified`
    ## a pre-RFC-0003 harvest would have recorded) drives the runtime
    ## absence partition to the correct classification.
    ## `computeMissingPartition` (src/softlink.nim) maps `acExpected` ->
    ## `mrExpected` 1:1 (manifest.nim's own `AbsenceClass` doc comment).
    let meta = HarvestMeta(toolchain: "gcc (pinned for golden test)",
                            tier: "builtin-compat", abi: "linux-lp64",
                            date: "2026-01-01")
    let corpus = loadCorpusProvenance("tests" / "corpus")
    let manifestJson = buildManifest(r, corpus, meta)
    let m = parseManifest($manifestJson, "tests/corpus/expected.compat.json")
    check classifyAbsence(m.symbols, "corpuslib_gated_since", "1.0.0", "2.0.0", "") == acExpected

  test "compat manifest matches the golden fixture (RFC-0001 SS4 B.3, slice B4)":
    ## Reuses the real `r` harvested above — no second harvest. `meta` is
    ## PINNED (not `defaultHarvestMeta()`) so this comparison is stable
    ## across machines/dates; `corpus` provenance comes from the real
    ## `tests/corpus/corpus.json` via `loadCorpusProvenance`, which IS
    ## deterministic already. Structural comparison (`parseJson` equality
    ## ignores JObject key order, per std/json) sidesteps whitespace/key-
    ## order brittleness — see softlink.nimble's own preference for exit-
    ## code/structural checks over prose-brittle ones.
    let meta = HarvestMeta(toolchain: "gcc (pinned for golden test)",
                            tier: "builtin-compat", abi: "linux-lp64",
                            date: "2026-01-01")
    let corpus = loadCorpusProvenance("tests" / "corpus")
    let manifest = buildManifest(r, corpus, meta)
    let golden = parseJson(readFile("tests" / "corpus" / "expected.compat.json"))
    check golden == manifest

  test "checkUntil against the REAL harvested manifest (RFC-0002 §6, slice C3a)":
    ## Every `checkUntil` test in test_softlink.nim's own suite runs
    ## against a hand-built `mkManifest` (synthetic `SymbolFacts`) — this
    ## is the harvest END-TO-END proof the slice brief asks for: parse the
    ## SAME manifest JSON `buildManifest` produces from a REAL harvest of
    ## the B3a fixture corpus (golden-tested immediately above) back into
    ## a `CompatManifest` via `parseManifest`, then drive `checkUntil`
    ## against `corpuslib_changed` — the fixture's one genuine drift
    ## (RFC-0001 slice B3a; tests/corpus/README.md): header-verified below
    ## 2.0.0, mismatched AT 2.0.0 (return type changes `int`->`double`),
    ## unknown at 3.0.0 (broken baseline).
    let meta = HarvestMeta(toolchain: "gcc (pinned for golden test)",
                            tier: "builtin-compat", abi: "linux-lp64",
                            date: "2026-01-01")
    let corpus = loadCorpusProvenance("tests" / "corpus")
    let manifestJson = buildManifest(r, corpus, meta)
    let m = parseManifest($manifestJson, "tests/corpus/expected.compat.json")

    # checkSince trivially passes: corpuslib_changed carries no {.since.}
    # ("" means unbounded) and the manifest has no `fkAbsent` fact for it
    # at all, so there is nothing rule checkSince could contradict.
    check not checkSince(m, "corpuslib_changed", "").contradicted

    # until: "2.0.0" matches the real drift onset EXACTLY — the header is
    # `fkVerified` for every corpus version strictly below 2.0.0 and the
    # manifest shows no re-verification at or above it, so rule (a)
    # (over-claim) and rule (c) (positive evidence, 1.0.0 is verified) both
    # pass. Finding R2-A, however: this corpus's own 3.0.0 entry never
    # classifies decisively (`tests/corpus`'s baseline deliberately FAILS
    # there — "broken include", see this suite's own harvest-classification
    # tests above — so EVERY symbol, not just this one, is `fkUnknown` at
    # 3.0.0), and 3.0.0 is inside `until`'s declared-invalid region
    # (at-or-above "2.0.0"). Rule (b) now requires a DECISIVE fact
    # throughout that whole region, not just "no fkVerified" — an
    # unclassified corpus version there is exactly the gap R2-A closes: a
    # real probe landing on "3.0.0" would otherwise sail through the
    # runtime attested-path exemption with no cross-check at all. This is
    # the real-harvest end-to-end proof that the fix fires against genuine
    # harvester output, not merely hand-built `mkManifest` data (contrast
    # `test_softlink.nim`'s own synthetic R2-A cases).
    let ucUnknownTail = checkUntil(m, "corpuslib_changed", "", "2.0.0")
    check ucUnknownTail.contradicted
    check "corpuslib_changed" in ucUnknownTail.message
    check "3.0.0" in ucUnknownTail.message
    check "no decisive classification" in ucUnknownTail.message

    # until: "3.0.0" claims the signature is still valid through 2.0.0 —
    # but the manifest shows it already `fkMismatch` AT 2.0.0, INSIDE the
    # declared window. Rule (a) (over-claim) must catch this, naming the
    # real drift version.
    let uc = checkUntil(m, "corpuslib_changed", "", "3.0.0")
    check uc.contradicted
    check "corpuslib_changed" in uc.message
    check "2.0.0" in uc.message

  test "checkUntil vacuous-pass escape hatch: until beyond corpus max (RFC-0002 §4.2, Finding R2-A)":
    ## Companion to the test immediately above, isolating the corpus-tip
    ## effect on a single clean symbol instead of contrasting across two
    ## symbols. `corpuslib_stable` never drifts anywhere in this fixture
    ## corpus (verified at 1.0.0 and 2.0.0, unknown at 3.0.0 — same broken-
    ## baseline story as `corpuslib_changed`'s 3.0.0, see the harvest suite
    ## above) — so it isolates rule (b′) from rule (a)'s mismatch check:
    ## any contradiction below is attributable to corpus-tip placement of
    ## `until` alone, not a genuine drift. (An `until` of "2.0.0" would trip
    ## rule (b) FIRST instead — the symbol is still `verified` AT 2.0.0, i.e.
    ## at-or-above that bound — so "3.0.0", the corpus max itself, is the
    ## one bound whose at-or-above region contains ONLY the unclassified
    ## tip.)
    let meta = HarvestMeta(toolchain: "gcc (pinned for golden test)",
                            tier: "builtin-compat", abi: "linux-lp64",
                            date: "2026-01-01")
    let corpus = loadCorpusProvenance("tests" / "corpus")
    let manifestJson = buildManifest(r, corpus, meta)
    let m = parseManifest($manifestJson, "tests/corpus/expected.compat.json")

    # until: "3.0.0" places ONLY the corpus's unclassified tip (3.0.0)
    # at-or-above the declared bound — rule (b′) fires exactly as it does
    # for `corpuslib_changed` above, even though `corpuslib_stable` never
    # drifts: the corpus simply never decisively confirmed the declared-
    # invalid region holds.
    let ucWithinCorpus = checkUntil(m, "corpuslib_stable", "", "3.0.0")
    check ucWithinCorpus.contradicted
    check "corpuslib_stable" in ucWithinCorpus.message
    check "3.0.0" in ucWithinCorpus.message
    check "no decisive classification" in ucWithinCorpus.message

    # until: "4.0.0" is strictly beyond the corpus's max harvested version
    # (3.0.0) — the documented-by-design escape hatch (manifest.nim's
    # rule (b) doc comment, README's "Troubleshooting" callout): rule (b)/
    # (b′)'s at-or-above-`until` scan finds no corpus version to examine at
    # all (m.corpus's max is 3.0.0 < 4.0.0), so it passes vacuously by
    # construction rather than by any decisive fact. Rule (a) (no mismatch
    # ever) and rule (c) (1.0.0/2.0.0 both verified, below 4.0.0) both pass
    # too, so the declaration is accepted overall.
    let ucBeyondCorpus = checkUntil(m, "corpuslib_stable", "", "4.0.0")
    check not ucBeyondCorpus.contradicted

    # Flip-check (not left in the suite): temporarily asserting
    # `ucBeyondCorpus.contradicted` here and re-running the suite fails,
    # confirming this assertion actually exercises live `checkUntil` logic
    # rather than passing vacuously itself.

# ---------------------------------------------------------------------------
# RFC-0003 §7 slice B2b's RED-evidence discipline: demonstrate the
# counterfactual before trusting the pinned (default) behavior. `probeOutcomes`
# is called directly (no dump/JSON needed — it just needs a module path), so
# this drives the EXACT same per-symbol pipeline `harvest` uses, isolated to
# ONE symbol and ONE version, under two different caller-supplied
# `HarvestOptions`.
#
# Empirically, on this project's own GCC 15.2.1 CI toolchain, GCC's OWN
# GCC-14+ default already treats `incompatible-pointer-types` as a hard
# error even WITHOUT `defaultHarvestOptions`'s explicit `-Werror=
# incompatible-pointer-types` pin — confirmed directly against bare `gcc`
# (outside Nim entirely) while writing this fixture: `gcc -I 2.0.0 -c pd.c`
# (no `-Werror` flag at all) already errors "passing argument 1 ... from
# incompatible pointer type", and Nim's own probe compile (which passes `-w`
# to gcc, suppressing ORDINARY warnings) still errors identically without the
# pin present in `extraFlags`. So simply REMOVING the pin flag from
# `extraFlags` cannot demonstrate the pin's severity control on THIS
# toolchain — both configurations already land on decisive `fkMismatch`, for
# the same real underlying reason (GCC's own newer default), and a test
# built that way would prove nothing about the pin itself.
#
# The counterfactual that DOES isolate the severity-pinning mechanism's
# actual job is a caller opts literal that explicitly DOWNGRADES the
# diagnostic back to a mere warning — `--passC:-Wno-error=incompatible-
# pointer-types` — simulating exactly the "permissive toolchain" scenario
# `defaultHarvestOptions`'s own doc comment names (an older pre-GCC-14
# toolchain, or a Clang invocation carrying no equivalent `-Werror=`).
# Confirmed empirically (bare `gcc -Wno-error=incompatible-pointer-types`
# against the SAME v2 header): the compile then SUCCEEDS with only a
# warning. Under that simulated-permissive opts, `probeOutcomes` records the
# WRONG fact, `fkVerified`, at 2.0.0 — the exact false-positive RFC-0003 §1
# Gap B describes ("a mere warning on permissive toolchains" -> the dummy
# call's own diagnostic never fires as an error -> the verify TU compiles
# clean -> `fkVerified`). This is the permanent regression proof that the
# severity-pinning mechanism (whichever of GCC's own default or
# `defaultHarvestOptions`'s explicit pin is doing the work on a given
# toolchain) is genuinely load-bearing, not merely assumed.
# ---------------------------------------------------------------------------
suite "corpuslib_param_drift — pin load-bearing proof (RFC-0003 §5.2 i, §7 B2b)":
  let scratch = getTempDir() / "sl_harvest_b2b_pin_proof"

  test "PINNED (default) opts: corpuslib_param_drift decisively fkMismatch at 2.0.0":
    if dirExists(scratch): removeDir(scratch)
    createDir(scratch)
    let outcome = probeOutcomes("nim", "tests" / "tharvest_binding.nim",
      "tests" / "corpus" / "2.0.0", "corpuslib_param_drift", scratch,
      defaultHarvestOptions())
    removeDir(scratch)
    check classify(outcome) == fkMismatch

  test "SIMULATED-PERMISSIVE opts (diagnostic explicitly downgraded to a " &
       "warning): false fkVerified at 2.0.0 — the counterfactual RFC-0003 " &
       "sec1 Gap B describes":
    if dirExists(scratch): removeDir(scratch)
    createDir(scratch)
    var permissiveOpts = defaultHarvestOptions()
    permissiveOpts.extraFlags.add("--passC:-Wno-error=incompatible-pointer-types")
    let outcome = probeOutcomes("nim", "tests" / "tharvest_binding.nim",
      "tests" / "corpus" / "2.0.0", "corpuslib_param_drift", scratch,
      permissiveOpts)
    removeDir(scratch)
    check classify(outcome) == fkVerified

suite "driftAlarm — integration against the real harvest (RFC-0001 SS4 B.4, slice B5)":
  ## Reuses the real `r` harvested in the suite above — no second harvest.
  ## `tests/corpus/README.md`: `corpuslib_changed` is `mismatch` at 2.0.0,
  ## the only mismatch anywhere in this fixture corpus.

  test "default (whole-corpus) range trips on corpuslib_changed's 2.0.0 mismatch":
    let (tripped, diag) = driftAlarm(r)
    check tripped
    check "corpuslib_changed" in diag
    check "2.0.0" in diag
    check f3Sentence in diag

  test "narrowed range excluding the mismatch version -> not tripped":
    let (tripped, diag) = driftAlarm(r, VersionInterval(hi: "2.0.0"))
    check not tripped
    check diag.len == 0

suite "softlink_harvest CLI — packaged entry, drift alarm exit code (RFC-0001 SS4 B.8, integration)":
  ## RFC-0001 SS4 B.8 packages the CLI as its own nimble package
  ## (`tools/harvest/softlink_harvest.nimble`, `bin = @["softlink_harvest"]`)
  ## with `tools/harvest/softlink_harvest.nim` as its thin I/O entry point
  ## over the SAME `harvester.harvest`/`driftAlarm` this file already
  ## exercises directly. This suite used to compile+run
  ## `tools/harvest/harvester.nim`'s bare positional dev shim instead; it
  ## now targets the packaged entry so the integration proof covers the
  ## surface a real binding author actually installs and runs, per the
  ## slice brief's explicit "may switch...if that keeps cost flat" note —
  ## one `nim c -r` invocation either way, same ~1-minute-suite budget.
  ## `harvester.nim`'s own bare shim is unchanged and still directly
  ## runnable for dev-loop convenience (see its doc comment); it just isn't
  ## what this integration test targets anymore.
  ##
  ## Scoping (per the slice brief, same as before): only the nonzero-exit
  ## path is checked here — see the prior version of this comment (git
  ## history) for why a second no-mismatch fixture isn't worth doubling
  ## this suite's wall time for a fact already covered at the `driftAlarm`
  ## unit level above.
  ##
  ## `--nim-path:src` is required here (but NOT by a real installed
  ## consumer) because the packaged CLI's own default `nimPaths` is empty
  ## (see `harvest_cli.defaultCliConfig`'s doc comment) — this repo's
  ## `tests/tharvest_binding.nim` fixture does `import softlink` from a
  ## checkout, not an installed nimble package, exactly the case that flag
  ## exists for.
  test "running the packaged CLI against the dump + corpus exits with exitDriftAlarm and prints the F3 diagnosis":
    let cliModule = "tools" / "harvest" / "softlink_harvest.nim"
    let cliCmd = "nim c -r --path:src " & cliModule & " " & dumpFile &
      " " & ("tests" / "corpus") & " --nim-path:src"
    let (output, exitCode) = execCmdEx(cliCmd)
    check exitCode == exitDriftAlarm
    check f3Sentence in output

  # Finding #19.5 (code-review coverage gap): `harvest_cli.exitCalibrationRefused`'s
  # own doc comment states the contract in so many words — "NO manifest
  # written" — but until now nothing asserted that FILESYSTEM fact; every
  # existing calibration-refusal test (this suite's sibling
  # tests/tharvest_msvc_calibration_refusal.nim, and `runCalibration`'s own
  # unit tests) only checks the returned/raised diagnosis, never that a
  # manifest file failed to appear on disk. This is the portable (no real
  # MSVC needed) version: `--extra-flag:--cc:<bogus>` makes the calibration
  # preflight's own BASELINE compile fail immediately (Nim rejects an
  # unrecognized `--cc` value before touching any header), which is a
  # different sub-diagnosis than the MSVC no-op-tier scenario but exercises
  # the IDENTICAL "calibration refused -> harvest() raises before
  # `softlink_harvest.run()` ever reaches its `writeManifest` call" path —
  # the one this finding is actually about. A fresh, never-before-used
  # `--out:` path (rather than the default next to `dumpFile`, which the
  # test directly above THIS one legitimately writes to) keeps this
  # assertion unambiguous: nothing else in this suite could have created
  # this exact file.
  #
  # Deliberately builds the CLI binary with a plain `nim c -o:<path>` and
  # then runs THAT binary directly, rather than `nim c -r` (the pattern the
  # drift-alarm test directly above uses) — empirically, `nim c -r`
  # collapses ANY nonzero child exit code to its own generic wrapper exit
  # code 1 ("Error: execution of an external program failed"), so it can't
  # actually distinguish `exitCalibrationRefused` (2) from any other
  # failure. Running the compiled binary directly yields the real exit
  # code.
  test "calibration refusal (broken --cc toolchain) -> exitCalibrationRefused, and NO manifest file is written":
    let cliModule = "tools" / "harvest" / "softlink_harvest.nim"
    let cliBin = dumpDir / "softlink_harvest_finding19_5"
    let (buildOutput, buildCode) = execCmdEx(
      "nim c --path:src -o:" & cliBin & " " & cliModule)
    doAssert buildCode == 0,
      "softlink: Finding #19.5: failed to build the softlink_harvest CLI " &
      "binary:\n" & buildOutput

    let refusalOutPath = dumpDir / "finding19_5_should_not_exist.compat.json"
    if fileExists(refusalOutPath): removeFile(refusalOutPath)
    let runCmd = cliBin & " " & dumpFile & " " & ("tests" / "corpus") &
      " --nim-path:src --out:" & refusalOutPath &
      " --extra-flag:--cc:softlinkDoesNotExistBogusCompiler"
    let (output, exitCode) = execCmdEx(runCmd)
    check exitCode == exitCalibrationRefused
    check not fileExists(refusalOutPath)

removeDir(dumpDir)

# ---------------------------------------------------------------------------
# RFC-0003 §5.2(iii): integration-level proof that the strict-mode `#error`
# needle is producible by a REAL compile — not merely asserted synthetically
# via `resolveVerifyRetry`'s unit tests above. On Linux, GCC *and* Clang
# both define `__GNUC__`, so `verify.nim`'s tier chain's final `#else`
# fallback (the strict `#error`) is structurally unreachable in the ordinary
# Docker/gcc loop this whole suite otherwise runs in.
# ---------------------------------------------------------------------------
suite "strict-needle integration proof (RFC-0003 §5.2 iii)":
  test "forcing the fallback tier via -U__GNUC__/-U__clang__ produces the needle end-to-end":
    ## `-U__GNUC__ -U__clang__` must be scoped to ONLY this fixture's own
    ## generated C file, via `{.localPassc.}` INSIDE the fixture module —
    ## NOT passed as a global `HarvestOptions.extraFlags`/`--passC:` (tried
    ## and rejected empirically while writing this test): a global
    ## `--passC:-U__GNUC__` applies to EVERY C file `nim c` compiles for
    ## this program, including Nim's own runtime (`system.nim` and
    ## friends) — whose generated code and `nimbase.h` both rely on
    ## `__GNUC__` being defined (e.g. `N_INLINE`'s raw `__inline` expansion,
    ## and glibc's own `__GNUC__`-conditional `_Float32`/`_Float64`
    ## typedefs pulled in transitively via `<stdio.h>`) — undefining it
    ## globally breaks the unrelated runtime compile before ever reaching
    ## this fixture's own verify block (confirmed empirically: the whole
    ## build fails with glibc/nimbase parse errors, never reaching our
    ## needle, if the flags are passed via `HarvestOptions.extraFlags`
    ## instead). `{.localPassc.}` scopes the flag to just the fixture
    ## module's own C file, which — being genuinely self-contained (no
    ## system includes in ITS OWN header) — tolerates the undefine
    ## cleanly, exactly matching RFC-0003 §5.2(iii)'s "self-contained
    ## fixture header" framing; only the MECHANISM by which the flag
    ## reaches just that one file needed to be worked out empirically.
    let dir = getTempDir() / "sl_harvest_stricttest"
    if dirExists(dir): removeDir(dir)
    createDir(dir)
    writeFile(dir / "b1needle.h", """
#ifndef SOFTLINK_B1_NEEDLE_H
#define SOFTLINK_B1_NEEDLE_H
int softlink_b1_needle_fn(int a);
#endif
""")
    writeFile(dir / "b1needle_binding.nim", """
{.localPassc: "-U__GNUC__ -U__clang__".}
import softlink

dynlib "libsoftlinkb1needle.so":
  proc softlink_b1_needle_fn(a: cint): cint {.cdecl, header: "b1needle.h".}
""")
    let opts = defaultHarvestOptions()
    let verify = compileProbe("nim", dir / "b1needle_binding.nim", dir, opts,
      @[dir], @["softlinkProbeOnly=softlink_b1_needle_fn"])
    removeDir(dir)

    check verify.exitCode != 0
    check strictVerifyUnavailableNeedle in verify.output

    # The end-to-end path RFC-0003 §5.2(iii) requires proven: needle ->
    # veUnavailable -> fkUnknown, against THIS REAL compile's output (not a
    # hand-written string, as `verifyEvidence`'s own unit tests use).
    let evidence = verifyEvidence(verify.output)
    check evidence == {veUnavailable}
    check classify(ProbeOutcomes(stage: psVerifyFailed, evidence: evidence)) == fkUnknown

# ---------------------------------------------------------------------------
# RFC-0003 review (stage 4, round 1, M6/M2/L1): the ground-truth define pair
# was assembled at three independent call sites (probeOutcomes's and the
# fast path's own local `groundTruthDefines` lets, plus one inline literal)
# instead of inside `compileProbe` itself — the exact smearing
# `effectiveVerifyWhen` (verify.nim) was built to prevent for `p.verifyWhen`
# reads. This suite proves the FIXED shape: `compileProbe*`, the one
# exported primitive that shells out to the real compiler, is ground-truth
# BY CONSTRUCTION, exactly the way it already bakes in
# `-d:softlinkStrictVerify` unconditionally (RFC-0003 §5.2 iii/§7 B1) — no
# caller, in-tree or third-party, can build a Gap-A-vulnerable probe through
# it (closing L1).
# ---------------------------------------------------------------------------
suite "compileProbe is ground-truth by construction (RFC-0003 review M6/M2/L1)":
  test "compileProbe alone, called directly with no hand-passed ground-truth " &
       "defines, defeats corpuslib_gated_until's closing gate at 2.0.0":
    ## Mirrors the strict-needle integration test's own nimExe/module/
    ## nimcache plumbing (above), but drives the ALREADY-committed corpus
    ## fixture `corpuslib_gated_until` (tests/tharvest_binding.nim) instead
    ## of a bespoke needle fixture. That binding declares
    ## `proc corpuslib_gated_until(a: cint): cint {.verifyWhen:
    ## "CORPUSLIB_VERSION < 200", until: "2.0.0".}`; at 2.0.0
    ## (tests/corpus/2.0.0/testlib.h) the header declares `double
    ## corpuslib_gated_until(int a);` — a genuine return-type drift — while
    ## `CORPUSLIB_VERSION` is 200 there, so the hand gate (`< 200`) is
    ## CLOSED: a gate-RESPECTING probe skips the verify assert entirely and
    ## compiles clean, exactly reconstructing Gap A.
    ##
    ## Calling the exported `compileProbe` primitive DIRECTLY, in verify
    ## mode (`softlinkProbeOnly=corpuslib_gated_until`, no
    ## `softlinkProbeExistence`), with NO hand-passed ground-truth defines:
    ## - Pre-fix: the primitive itself carries no ground-truth guarantee
    ##   (only `probeOutcomes`'s and the fast path's own call sites added
    ##   the defines) — the gate is respected, the drift stays masked, the
    ##   compile is CLEAN (`exitCode == 0`). This is the RED this test
    ##   captures against the unmodified harvester.nim.
    ## - Post-fix: `compileProbe` unconditionally adds both
    ##   `-d:softlinkProbeGroundTruth` and `-d:softlinkHarvestSession` to
    ##   EVERY compile it issues, the same way it already does for
    ##   `-d:softlinkStrictVerify` — the gate is defeated regardless of what
    ##   the caller passed, the real drift surfaces, and the compile FAILS
    ##   (`exitCode != 0`).
    let scratch = getTempDir() / "sl_harvest_compileprobe_groundtruth_test"
    if dirExists(scratch): removeDir(scratch)
    createDir(scratch)
    let opts = defaultHarvestOptions()
    let verify = compileProbe("nim", "tests" / "tharvest_binding.nim", scratch,
      opts, @["tests" / "corpus" / "2.0.0"],
      @["softlinkProbeOnly=corpuslib_gated_until"])
    removeDir(scratch)

    check verify.exitCode != 0

# ---------------------------------------------------------------------------
# RFC-0003 round-2 review R2-1 (High): Nim silently honors the LAST
# `-d:NAME[=VALUE]` occurrence on a command line (confirmed empirically
# against the pinned toolchain: `-d:foo -d:foo=false` -> `foo` is `false`).
# `compileProbe` used to append caller `defines`/`opts.extraFlags` AFTER its
# own three invariant `-d:...` lines, so a caller's own
# `-d:softlinkProbeGroundTruth=false` -- exactly the shipped CLI's own
# documented `--extra-flag:-d:softlinkProbeGroundTruth=false` spelling --
# silently won the last-wins race and defeated ground truth on every probe,
# reopening Gap A through `compileProbe`'s own front door (the suite above,
# "compileProbe is ground-truth by construction", proved only that a caller
# who passes NO defines at all can't omit the guarantee -- it never covered
# a caller who actively tries to override it).
#
# The fix is two independent mechanisms (`compileProbe`'s own doc comment
# has the full argument): (a) `rejectReservedDefineOverrides`, a scan run
# before any compile, raising a loud `HarvestError` naming the offending
# flag; (b) moving the three invariant `args.add("-d:...")` lines to AFTER
# `defines`/`opts.extraFlags` are appended, so last-wins favors the
# invariants even for a spelling the scan's exact-match style might miss.
# This suite exercises (a) directly, since (b) is not independently
# observable from outside `compileProbe` once (a) refuses the same inputs
# first.
#
# RED (pre-fix, hand-verified against the unmodified `harvester.nim` by
# temporarily restoring the old append-order/removing the scan call, then
# hand-restoring the fix and re-confirming GREEN): the first test below
# raised NO `HarvestError` at all, and the resulting `CompileOutcome`'s
# `exitCode` was `0` -- the extraFlags override silently won and
# `corpuslib_gated_until`'s genuine 2.0.0 return-type drift stayed masked,
# exactly reproducing Gap A end-to-end through the exported primitive.
# ---------------------------------------------------------------------------
suite "compileProbe — rejects reserved-define overrides (RFC-0003 round-2 review R2-1)":
  test "an extraFlags -d:softlinkProbeGroundTruth=false attempt (the shipped CLI's " &
       "own documented --extra-flag spelling) is rejected with a HarvestError " &
       "naming the offending flag, never silently reconstructing Gap A":
    # RFC-0003 round-3 review R3-3: race-free `createTempDir` (R2-4's own
    # precedent) instead of a predictable fixed name; prefix avoids the
    # `sl_harvest_` substring per the M4 suite's documented pitfall further
    # down this file.
    let scratch = createTempDir("sl_r21reject_", "")
    var opts = defaultHarvestOptions()
    opts.extraFlags.add("--passC:-Wall")
    opts.extraFlags.add("-d:softlinkProbeGroundTruth=false")
    var raised = false
    var msg = ""
    try:
      discard compileProbe("nim", "tests" / "tharvest_binding.nim", scratch,
        opts, @["tests" / "corpus" / "2.0.0"],
        @["softlinkProbeOnly=corpuslib_gated_until"])
    except HarvestError as e:
      raised = true
      msg = e.msg
    removeDir(scratch)

    check raised
    check "-d:softlinkProbeGroundTruth=false" in msg
    check "softlinkProbeGroundTruth" in msg

  test "extraFlags smuggling the internal-only softlinkProbeExistence define is also rejected":
    ## Part (a)'s extraFlags scan additionally covers `softlinkProbeOnly`/
    ## `softlinkProbeExistence` -- `compileProbe`'s OWN internal `defines`-
    ## parameter vocabulary -- because an operator setting either via
    ## `--extra-flag` corrupts probe identity the same way overriding an
    ## invariant does, even though internal callers remain free to pass
    ## them through the `defines` parameter itself (see the next test).
    let scratch = createTempDir("sl_r21reject_", "")
    var opts = defaultHarvestOptions()
    opts.extraFlags.add("-d:softlinkProbeExistence")
    var raised = false
    try:
      discard compileProbe("nim", "tests" / "tharvest_binding.nim", scratch,
        opts, @["tests" / "corpus" / "1.0.0"], @["softlinkProbeOnly=corpuslib_stable"])
    except HarvestError:
      raised = true
    removeDir(scratch)
    check raised

  test "a reserved define smuggled via the defines parameter is rejected too":
    ## Internal callers legitimately pass `softlinkProbeOnly`/
    ## `softlinkProbeExistence` through the `defines` parameter (every
    ## `probeOutcomes`/`runCalibration`/fast-path call site does), so the
    ## `defines`-parameter scan covers ONLY the three ground-truth
    ## invariants, never those two -- this test targets one of the three.
    let scratch = createTempDir("sl_r21reject_", "")
    let opts = defaultHarvestOptions()
    var raised = false
    try:
      discard compileProbe("nim", "tests" / "tharvest_binding.nim", scratch,
        opts, @["tests" / "corpus" / "1.0.0"],
        @["softlinkProbeOnly=corpuslib_stable", "softlinkHarvestSession=false"])
    except HarvestError:
      raised = true
    removeDir(scratch)
    check raised

  test "a benign -d: extraFlag a user might legitimately pass (-d:release) is NOT rejected":
    ## Positive control: the scan must not be so broad that it rejects
    ## ordinary, unrelated `-d:` usage a caller has every right to pass.
    let scratch = createTempDir("sl_r21benign_", "")
    var opts = defaultHarvestOptions()
    opts.extraFlags.add("-d:release")
    var raised = false
    var outcome: CompileOutcome
    try:
      outcome = compileProbe("nim", "tests" / "tharvest_binding.nim", scratch,
        opts, @["tests" / "corpus" / "1.0.0"], @["softlinkProbeOnly=corpuslib_stable"])
    except HarvestError:
      raised = true
    removeDir(scratch)
    check not raised
    check outcome.exitCode == 0

  test "an extraFlags -d=softlinkProbeGroundTruth=false attempt (Nim's `=`-for-`:` " &
       "spelling of --define) is rejected with a HarvestError naming the offending flag":
    ## RFC-0003 round-3 review R3-1: Nim's `parseopt` treats `:` and `=` as
    ## interchangeable separators for long/short options alike, so
    ## `-d=NAME=val` is a fully legitimate, Nim-native spelling of
    ## `-d:NAME=val` -- pre-fix, `extraFlagSetsDefine` only recognized the
    ## `-d:`/`--define:` prefixes and silently let this spelling through,
    ## reopening exactly the Gap A this whole mechanism exists to close.
    let scratch = createTempDir("sl_r21reject_", "")
    var opts = defaultHarvestOptions()
    opts.extraFlags.add("-d=softlinkProbeGroundTruth=false")
    var raised = false
    var msg = ""
    try:
      discard compileProbe("nim", "tests" / "tharvest_binding.nim", scratch,
        opts, @["tests" / "corpus" / "2.0.0"],
        @["softlinkProbeOnly=corpuslib_gated_until"])
    except HarvestError as e:
      raised = true
      msg = e.msg
    removeDir(scratch)

    check raised
    check "-d=softlinkProbeGroundTruth=false" in msg
    check "softlinkProbeGroundTruth" in msg

  test "an extraFlags --define=softlinkHarvestSession=false attempt (the `=`-for-`:` " &
       "spelling of the long option) is rejected with a HarvestError naming the flag":
    let scratch = createTempDir("sl_r21reject_", "")
    var opts = defaultHarvestOptions()
    opts.extraFlags.add("--define=softlinkHarvestSession=false")
    var raised = false
    var msg = ""
    try:
      discard compileProbe("nim", "tests" / "tharvest_binding.nim", scratch,
        opts, @["tests" / "corpus" / "1.0.0"],
        @["softlinkProbeOnly=corpuslib_stable"])
    except HarvestError as e:
      raised = true
      msg = e.msg
    removeDir(scratch)

    check raised
    check "--define=softlinkHarvestSession=false" in msg
    check "softlinkHarvestSession" in msg

  # -------------------------------------------------------------------------
  # RFC-0003 round-4 review R4-1 (Medium): the round-3 fix's 4-spelling
  # prefix list (`-d:`/`-d=`/`--define:`/`--define=`) is not what Nim
  # actually dispatches on. `compiler/commands.nim` normalizes the SWITCH
  # name itself via `strutils.normalize` (full lowercase + strip
  # underscores) before comparing it to "d"/"define", so `-D:`, `--Define:`,
  # `--DEFINE=`, `--de_fine:` are all equally live spellings the 4-prefix
  # list silently missed (`-D` is C-preprocessor muscle memory — the most
  # realistic miss). Nim's define NAMES are matched via the `-d:` symbol
  # table's OWN style-insensitive relation too (`cmpIgnoreStyle`, which
  # folds EVERY character including the first — see round-5 review R5-1
  # below; round 4 mistakenly modeled this as the first-char-SENSITIVE
  # SOURCE-identifier rule instead), so `softlink_probe_ground_truth` is a
  # live spelling of `softlinkProbeGroundTruth` the old exact-match
  # `defineSpecSetsName` missed. These misses silently no-op the scan
  # (ordering defense still keeps ground truth SAFE — ordering is defense
  # in depth for exactly this) instead of raising the loud refusal the
  # mechanism exists to give.
  #
  # RED (captured live against the round-3 implementation, hand-verified
  # then hand-restored): all three negative tests below raised no
  # `HarvestError` and the resulting `CompileOutcome.exitCode` was `0` —
  # each spelling silently bypassed the scan exactly like the round-3
  # finding's own `-d=`/`--define=` miss did pre-round-3.
  # -------------------------------------------------------------------------
  test "an extraFlags -D:softlinkProbeGroundTruth=false attempt (capital-D switch, " &
       "Nim's own normalize dispatch treats -D the same as -d) is rejected":
    let scratch = createTempDir("sl_r21reject_", "")
    var opts = defaultHarvestOptions()
    opts.extraFlags.add("-D:softlinkProbeGroundTruth=false")
    var raised = false
    var msg = ""
    try:
      discard compileProbe("nim", "tests" / "tharvest_binding.nim", scratch,
        opts, @["tests" / "corpus" / "2.0.0"],
        @["softlinkProbeOnly=corpuslib_gated_until"])
    except HarvestError as e:
      raised = true
      msg = e.msg
    removeDir(scratch)

    check raised
    check "-D:softlinkProbeGroundTruth=false" in msg
    check "softlinkProbeGroundTruth" in msg

  test "an extraFlags --De_Fine:softlinkHarvestSession=false attempt (mixed-case, " &
       "underscored long-switch spelling Nim's normalize dispatch also accepts) " &
       "is rejected":
    let scratch = createTempDir("sl_r21reject_", "")
    var opts = defaultHarvestOptions()
    opts.extraFlags.add("--De_Fine:softlinkHarvestSession=false")
    var raised = false
    var msg = ""
    try:
      discard compileProbe("nim", "tests" / "tharvest_binding.nim", scratch,
        opts, @["tests" / "corpus" / "1.0.0"],
        @["softlinkProbeOnly=corpuslib_stable"])
    except HarvestError as e:
      raised = true
      msg = e.msg
    removeDir(scratch)

    check raised
    check "--De_Fine:softlinkHarvestSession=false" in msg
    check "softlinkHarvestSession" in msg

  test "an extraFlags -d:softlink_probe_ground_truth=false attempt (underscored " &
       "define-NAME spelling — same Nim identifier as softlinkProbeGroundTruth " &
       "since Nim identifiers are style-insensitive except the first character) " &
       "is rejected":
    let scratch = createTempDir("sl_r21reject_", "")
    var opts = defaultHarvestOptions()
    opts.extraFlags.add("-d:softlink_probe_ground_truth=false")
    var raised = false
    var msg = ""
    try:
      discard compileProbe("nim", "tests" / "tharvest_binding.nim", scratch,
        opts, @["tests" / "corpus" / "2.0.0"],
        @["softlinkProbeOnly=corpuslib_gated_until"])
    except HarvestError as e:
      raised = true
      msg = e.msg
    removeDir(scratch)

    check raised
    check "softlink_probe_ground_truth=false" in msg
    check "softlinkProbeGroundTruth" in msg

  # -------------------------------------------------------------------------
  # RFC-0003 round-5 review R5-1 (High): the round-4 fix compared define
  # NAMES via `nimIdentNormalize` -- the SOURCE-identifier rule, which keeps
  # the first character's case (first-char SENSITIVE). But Nim's actual
  # `-d:`/`--define` SYMBOL TABLE (`options.nim`'s `modeStyleInsensitive`
  # strtable) dispatches via `cmpIgnoreStyle`, which folds case on EVERY
  # character INCLUDING the first, and strips underscores -- empirically
  # confirmed: `-d:Foo`, `-d:FOO=true`, and `-d:f_o_o` all set the SAME
  # booldefine `foo`. So `-d:SoftlinkProbeGroundTruth=false` (capital-S) IS
  # the reserved `softlinkProbeGroundTruth` define as far as Nim itself is
  # concerned, yet the round-4 comparison treated it as a genuinely
  # different identifier and let it through -- round 4's own positive-
  # control test asserted that miss as CORRECT, baking the wrong model into
  # the suite. Ground truth stayed safe throughout (the ordering defense
  # overwrites the same style-insensitive table entry regardless of scan
  # misses), but the loud-refusal mechanism silently no-opped on a spelling
  # the code explicitly blessed.
  #
  # Fix: `defineSpecSetsName` now compares the name portion via
  # `strutils.normalize` full-string equality (mirroring Nim's own `-d:`
  # table relation) instead of `nimIdentNormalize`. The boundary property
  # still holds for free -- proven by the positive control below.
  #
  # RED (captured live against the round-4 `nimIdentNormalize` comparison,
  # hand-verified then hand-restored): both negative tests below raised no
  # `HarvestError` (the capital-S test was, pre-fix, a POSITIVE control
  # asserting `not raised` -- exactly the wrong-model assertion this finding
  # is about). GREEN after the one-line comparison change in
  # `defineSpecSetsName`.
  # -------------------------------------------------------------------------
  test "an extraFlags -d:SoftlinkProbeGroundTruth=false attempt (capital-S first " &
       "character) is rejected -- Nim's -d: symbol table is style-insensitive on " &
       "EVERY character including the first (cmpIgnoreStyle), so this IS the " &
       "reserved softlinkProbeGroundTruth define to Nim regardless of source-" &
       "identifier first-char sensitivity":
    let scratch = createTempDir("sl_r21reject_", "")
    var opts = defaultHarvestOptions()
    opts.extraFlags.add("-d:SoftlinkProbeGroundTruth=false")
    var raised = false
    var msg = ""
    try:
      discard compileProbe("nim", "tests" / "tharvest_binding.nim", scratch,
        opts, @["tests" / "corpus" / "1.0.0"],
        @["softlinkProbeOnly=corpuslib_stable"])
    except HarvestError as e:
      raised = true
      msg = e.msg
    removeDir(scratch)
    check raised
    check "SoftlinkProbeGroundTruth" in msg
    check "softlinkProbeGroundTruth" in msg

  test "an extraFlags --define=SOFTLINKHARVESTSESSION=false attempt (ALL-CAPS, a " &
       "first-char-varying spelling distinct from the capital-S case above) is " &
       "rejected":
    let scratch = createTempDir("sl_r21reject_", "")
    var opts = defaultHarvestOptions()
    opts.extraFlags.add("--define=SOFTLINKHARVESTSESSION=false")
    var raised = false
    var msg = ""
    try:
      discard compileProbe("nim", "tests" / "tharvest_binding.nim", scratch,
        opts, @["tests" / "corpus" / "1.0.0"],
        @["softlinkProbeOnly=corpuslib_stable"])
    except HarvestError as e:
      raised = true
      msg = e.msg
    removeDir(scratch)
    check raised
    check "SOFTLINKHARVESTSESSION" in msg
    check "softlinkHarvestSession" in msg

  test "an extraFlags -d:softlinkProbeGroundTruthX=false attempt (unrelated name " &
       "merely sharing a prefix with a reserved define) is NOT rejected":
    ## Positive control (boundary proof, RFC-0003 round-5 review R5-1): full-
    ## string style-insensitive equality never matches a prefix-sharing but
    ## genuinely different name.
    let scratch = createTempDir("sl_r21benign_", "")
    var opts = defaultHarvestOptions()
    opts.extraFlags.add("-d:softlinkProbeGroundTruthX=false")
    var raised = false
    var outcome: CompileOutcome
    try:
      outcome = compileProbe("nim", "tests" / "tharvest_binding.nim", scratch,
        opts, @["tests" / "corpus" / "1.0.0"], @["softlinkProbeOnly=corpuslib_stable"])
    except HarvestError:
      raised = true
    removeDir(scratch)
    check not raised
    check outcome.exitCode == 0

# ---------------------------------------------------------------------------
# RFC-0003 stage-4 review, Finding M4: `resolveVerifyRetry`'s "flaky ->
# fkUnknown + loud warning" arm and `infraFailureReason`'s abort arm were,
# before this suite, unit-tested only against hand-written synthetic
# `(output, exitCode)` strings fed directly to those pure functions — never
# driven through a REAL forced compile via `probeOutcomes`, unlike B1's own
# strict-needle precedent (the suite above, which forces a real compiler
# through `-U__GNUC__ -U__clang__`). This suite closes that gap with a gcc
# WRAPPER SCRIPT substituted for the real compiler via
# `HarvestOptions.extraFlags`'s `--cc:gcc --gcc.exe:<wrapper>` (Nim accepts
# `--<ccname>.exe:<path>` as a per-run override of the "gcc" backend's own
# compiler executable; confirmed empirically against this project's Docker
# toolchain before writing this suite) — the wrapper deterministically fails
# (or lets through) specific `nim c` compiles so both `probeOutcomes` arms
# get driven by a genuinely failing/succeeding subprocess, not a mocked
# return value.
#
# THE MECHANISM (documented per the finding's own instruction to spell this
# out): `probeOutcomes` issues 2 or 3 `compileProbe` calls in strict
# sequence for one `(version, symbol)` probe — existence, then verify, then
# (only if verify fails non-infra) an identical retry — and EACH
# `compileProbe` call gets its OWN fresh nimcache directory
# (`freshDir`/`createTempDir("sl_harvest_", "", nimcacheRoot)`, an 11-
# character-plus-prefix RANDOM name, e.g. `sl_harvest_FhX96eM3`). A single
# `nim c --noLinking` invocation shells out to the (wrapped) "gcc" MANY
# times — once per changed C file (`system.nim`, several stdlib modules,
# the fixture module itself, a `-dumpversion` sanity probe, etc.) — so the
# wrapper cannot simply count its own invocations 1st/2nd/3rd; instead it
# extracts the unique `sl_harvest_<random>` nimcache-directory token that
# appears in EVERY gcc invocation's arguments for a given `nim c` call
# (it's baked into every `-o .../sl_harvest_XXXX/foo.c.o` and generated
# `.c` path) and maintains an ORDER FILE recording each DISTINCT token the
# first time it's seen, under an `flock`-guarded critical section (multiple
# gcc invocations within one `nim c` call are not guaranteed sequential).
# The 1-based position of a token in that order file is exactly "which of
# the 2-3 `compileProbe` calls this gcc invocation belongs to" — 1st distinct
# token = existence, 2nd = verify, 3rd = retry — regardless of how many gcc
# sub-invocations happen inside each. The wrapper then fails EVERY gcc call
# belonging to token #2 (the verify compile) when a mode file says so,
# and passes every other call straight through to the real `/usr/bin/gcc`.
# (Empirically discovered pitfall, documented here so it isn't silently
# reintroduced: the test's OWN scratch directory name must not itself
# contain the substring `sl_harvest_`, or the wrapper's substring grep
# matches that constant, ever-present outer path — which appears in every
# gcc invocation via `-I<versionDir>` — before it ever reaches the real,
# per-compile nimcache token, permanently pinning every call to "position
# 1" and never triggering the intended failure. Hence `sl_m4wrap*` below,
# not `sl_harvest_m4*`.)
#
# The two arms:
# - FLAKY: mode file says "flaky" — position-2 (verify) fails once with a
#   plain, non-infra-shaped error; position-3 (retry) is allowed through
#   to the real compiler and succeeds (the header genuinely matches the
#   binding — nothing is actually wrong). `probeOutcomes` must record the
#   NON-decisive `fkUnknown` (never `fkMismatch`) and print
#   `resolveVerifyRetry`'s loud warning — captured here via a real fd-2
#   (`stderr`) `dup`/`dup2` swap around the call (the warning is an
#   in-process `stderr.writeLine`, not a subprocess's own output, so it's
#   directly interceptable this way; no such hook existed before this test,
#   so this IS the "assertable surface" the finding asks to look for).
# - INFRA: mode file says "infra" — position-2 (verify) fails with the
#   literal text `internal compiler error`, one of `infraFailureMarkers`.
#   `probeOutcomes` must raise `HarvestError` immediately, WITHOUT ever
#   attempting a retry (confirmed via `compileCounter`, which stops at 2)
#   — the existing "a dying toolchain doesn't get a second compile burned
#   on it" guard, exercised on the FIRST-failure check
#   (`probeOutcomes`'s own `firstInfra` branch) rather than the retry-
#   also-infra branch inside `resolveVerifyRetry` (both branches share the
#   identical `infraFailureReason` detector this wrapper's "infra" mode
#   targets, and the first-failure branch is the one an infra-shaped
#   FIRST verify failure actually reaches — the retry-also-infra branch
#   is `resolveVerifyRetry`'s own territory, already unit-proven directly
#   above this suite).
# ---------------------------------------------------------------------------
# RFC-0003 round-2 review R2-2: this suite is Linux/gcc-specific by construction — the gcc wrapper script `exec`s `/usr/bin/gcc` directly and its order-file bookkeeping is guarded by `flock(1)`, neither of which the macOS/clang CI leg can rely on (that leg DOES compile and run this file, via `runHarvesterCheck(clangLeg = true)` in softlink.nimble). Gated the same way the golden verify-apparatus check is gated in softlink.nimble (`runHarvesterCheck`'s own "Linux/gcc leg only" precedent): the mechanism itself is toolchain-specific, but the ARMS it proves (`resolveVerifyRetry`'s flaky/infra decisions) are already unit-tested platform-independently above (the pure "resolveVerifyRetry" and "infraFailureReason" suites), so no coverage is lost on non-Linux legs — only the real-compile integration proof is Linux-only.
when defined(linux):
  suite "harvest — retry-once real-compile integration proof (RFC-0003 stage-4 review finding M4)":
    proc captureRealStderr(body: proc()): string =
      ## Real fd-2 swap (not a Nim-level stream substitution) — `probeOutcomes`
      ## prints its flaky warning via a direct `stderr.writeLine` in THIS
      ## process (not a subprocess whose output the harness already pipes
      ## and captures), so nothing else in this codebase's test suites needed
      ## this hook before. Symmetric save/restore of the real descriptor so
      ## the rest of this test binary's own output (unittest's own progress
      ## printing, e.g.) is unaffected once `body` returns.
      ##
      ## RFC-0003 round-2 review R2-3: the dup2/body/dup2-back sequence is
      ## wrapped in try/finally — without it, an exception raised out of
      ## `body` (e.g. a `check`/`doAssert` failure, or `probeOutcomes` itself
      ## raising `HarvestError`) would propagate straight past the restore
      ## line below, permanently leaving this process's real stderr
      ## redirected into the capture file for the rest of the test binary —
      ## silently swallowing every later suite's diagnostics. The finally
      ## restores fd 2 unconditionally, exception or not.
      ##
      ## RFC-0003 round-2 review R2-4: the capture path is now a real
      ## `createTempFile` (race-free `mkstemp`-style primitive, matching
      ## production `freshDir`'s own precedent) rather than a
      ## PID-suffixed, predictable name under the shared, world-writable
      ## `getTempDir()`. Prefix kept in the `sl_m4wrap_`-not-`sl_harvest_`
      ## family per this suite's own documented pitfall (see the header
      ## comment above `buildM4WrapperFixture`): a capture path containing
      ## the substring `sl_harvest_` would itself match the wrapper
      ## script's `sl_harvest_<random>` nimcache-token grep.
      ##
      ## Acquisition order and cleanup close the two informational leak
      ## paths from the same review: the temp file is created BEFORE the
      ## fd is duplicated (a `createTempFile` failure can no longer leak
      ## `savedFd`), and the outer finally removes the capture file even
      ## when `body` raises (previously the read/remove sat after the
      ## fd-restore finally and were skipped on the raising path).
      stderr.flushFile()
      let (f, capturePath) = createTempFile("sl_m4wrap_stderr_capture_", "")
      try:
        let savedFd = dup(2.cint)
        try:
          discard dup2(getFileHandle(f).cint, 2.cint)
          body()
          stderr.flushFile()
        finally:
          discard dup2(savedFd, 2.cint)
          discard close(savedFd)
          f.close()
        result = readFile(capturePath)
      finally:
        removeFile(capturePath)

    proc buildM4WrapperFixture(dir: string): tuple[modulePath, wrapperPath, orderFile, modeFile: string] =
      ## One tiny, self-contained header + binding (a single header-only proc
      ## whose declared and bound signatures genuinely agree, so any failure
      ## seen during a test is attributable to the WRAPPER, never a real
      ## drift) plus the counting/mode-dispatching gcc wrapper script
      ## described in this suite's own header comment above.
      createDir(dir)
      writeFile(dir / "m4wraplib.h", """
#ifndef M4WRAPLIB_H
#define M4WRAPLIB_H
int m4wrap_fn(int a);
#endif
""")
      let modulePath = dir / "m4wrap_binding.nim"
      writeFile(modulePath, """
import softlink

dynlib "libm4wrapprobe.so":
  proc m4wrap_fn(a: cint): cint {.cdecl, header: "m4wraplib.h".}
""")
      let wrapperPath = dir / "wrap.sh"
      let orderFile = dir / "order.txt"
      let modeFile = dir / "mode.txt"
      writeFile(orderFile, "")
      writeFile(wrapperPath, "#!/bin/bash\n" &
        "ORDER_FILE=\"" & orderFile & "\"\n" &
        "MODE_FILE=\"" & modeFile & "\"\n" &
        "LOCK_FILE=\"$ORDER_FILE.lock\"\n" & """
ARGV="$*"
ID=$(echo "$ARGV" | grep -oE 'sl_harvest_[A-Za-z0-9]+' | head -1)

if [ -z "$ID" ]; then
  exec /usr/bin/gcc "$@"
fi

(
  flock -x 200
  if ! grep -qxF "$ID" "$ORDER_FILE" 2>/dev/null; then
    echo "$ID" >> "$ORDER_FILE"
  fi
) 200>"$LOCK_FILE"

INDEX=$(grep -nxF "$ID" "$ORDER_FILE" | head -1 | cut -d: -f1)
MODE=$(cat "$MODE_FILE" 2>/dev/null || echo "")

if [ "$INDEX" = "2" ]; then
  if [ "$MODE" = "flaky" ]; then
    echo "softlink harvest test (M4): wrapper-forced verify failure, simulating a transient toolchain hiccup (not a real signature problem)" >&2
    exit 1
  elif [ "$MODE" = "infra" ]; then
    echo "internal compiler error: wrapper-forced ICE for RFC-0003 M4 integration test" >&2
    exit 1
  fi
fi

exec /usr/bin/gcc "$@"
""")
      setFilePermissions(wrapperPath, {fpUserRead, fpUserWrite, fpUserExec,
                                        fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
      (modulePath, wrapperPath, orderFile, modeFile)

    test "FLAKY verify failure (transient, non-infra) classifies fkUnknown -- " &
         "never the decisive fkMismatch -- and prints the loud retry warning":
      # RFC-0003 round-2 review R2-4: race-free `createTempDir` (production
      # `freshDir`'s own precedent) instead of a predictable fixed name
      # under the shared, world-writable `getTempDir()`.
      let dir = createTempDir("sl_m4wrap_flaky_", "")
      let (modulePath, wrapperPath, _, modeFile) = buildM4WrapperFixture(dir)
      writeFile(modeFile, "flaky")

      var opts = defaultHarvestOptions()
      opts.extraFlags.add("--cc:gcc")
      opts.extraFlags.add("--gcc.exe:" & wrapperPath)

      let nimcacheRoot = dir / "nimcache"
      createDir(nimcacheRoot)
      var compileCount = 0
      var outcome: ProbeOutcomes
      let warning = captureRealStderr(proc () =
        outcome = probeOutcomes("nim", modulePath, dir, "m4wrap_fn", nimcacheRoot,
          opts, addr compileCount)
      )
      removeDir(dir)

      # Decisive proof this is the NON-decisive path: `veUnavailable` in the
      # evidence set (never `fkMismatch`, which the pre-M4-fix reclassify
      # rule would land a naive "any failure is decisive" reading on).
      check outcome.stage == psVerifyFailed
      check veUnavailable in outcome.evidence
      check classify(outcome) == fkUnknown
      # The loud warning is real, in-process `stderr` output, not a mocked
      # return value -- captured via the real fd-2 swap above.
      check "FLAKY" in warning
      check "m4wrap_fn" in warning
      check "RFC-0003 5.2 ii" in warning
      # existence(1) + verify(2, forced fail) + retry(3, allowed through) --
      # exactly one retry burned, matching "decisive requires deterministic"
      # (§5.2 ii): the retry is attempted exactly once, never looped.
      check compileCount == 3

    test "INFRA-marker verify failure raises HarvestError immediately, " &
         "WITHOUT attempting a retry, and records no fact at all":
      # RFC-0003 round-2 review R2-4: race-free `createTempDir`, see the
      # FLAKY test above.
      let dir = createTempDir("sl_m4wrap_infra_", "")
      let (modulePath, wrapperPath, _, modeFile) = buildM4WrapperFixture(dir)
      writeFile(modeFile, "infra")

      var opts = defaultHarvestOptions()
      opts.extraFlags.add("--cc:gcc")
      opts.extraFlags.add("--gcc.exe:" & wrapperPath)

      let nimcacheRoot = dir / "nimcache"
      createDir(nimcacheRoot)
      var compileCount = 0
      var raised = false
      var raisedMsg = ""
      try:
        discard probeOutcomes("nim", modulePath, dir, "m4wrap_fn", nimcacheRoot,
          opts, addr compileCount)
      except HarvestError as e:
        raised = true
        raisedMsg = e.msg
      removeDir(dir)

      check raised
      check "INFRASTRUCTURE" in raisedMsg
      check "m4wrap_fn" in raisedMsg
      # existence(1) + verify(2, forced ICE) -- the first-failure infra check
      # aborts BEFORE any retry compile is issued: a dying toolchain must
      # never be given a second compile to burn (RFC-0003 §5.2 ii).
      check compileCount == 2

# ---------------------------------------------------------------------------
# RFC-0003 §3.1's named residual, pinned empirically: a struct-by-value
# PARAMETER drift (the struct's own fields change between two corpus
# versions) that the call-based, per-symbol dummy-call verification
# mechanism does NOT catch — documented honestly (§5.2's drift taxonomy),
# not silently implied. This test PINS current behavior; it does not fix it
# (the RFC rejects full-type comparison as the fix, §5.1 — see this file's
# other suites for what full-type comparison would have broken instead).
# ---------------------------------------------------------------------------
suite "struct-by-value residual (RFC-0003 §3.1, honest gap — pinned, not fixed)":
  test "a struct-by-value field drift between two versions still classifies fkVerified at both":
    ## `softlink_b1_point_t` is declared `{int x; int y;}` at "1.0.0" and
    ## `{long x; long y; long z;}` at "2.0.0" — a genuine ABI-breaking
    ## change (size, member count, AND member types all differ) to a
    ## parameter passed BY VALUE. Because the dummy-call mechanism only
    ## ever declares `softlink_b1_point_t p;` and calls
    ## `softlink_b1_struct_drift(p)` — never inspecting the struct's own
    ## members — the C compiler has nothing to object to at EITHER
    ## version: the type name resolves against whichever header is
    ## currently included, and passing a value of that type to a parameter
    ## of the identical type always type-checks. This is exactly the "no
    ## pointer conversion involved" gap Fix B's `-Werror=incompatible-*`
    ## pins (RFC-0003 §5.2 i) cannot help with either — those pins only
    ## ever fire on POINTER parameter drift, and a by-value struct argument
    ## never goes through pointer conversion rules at all.
    let dir = getTempDir() / "sl_harvest_structdrift"
    if dirExists(dir): removeDir(dir)
    createDir(dir)
    let v1 = dir / "1.0.0"
    let v2 = dir / "2.0.0"
    createDir(v1)
    createDir(v2)
    writeFile(v1 / "structdrift.h", """
#ifndef SOFTLINK_B1_STRUCTDRIFT_H
#define SOFTLINK_B1_STRUCTDRIFT_H
typedef struct { int x; int y; } softlink_b1_point_t;
int softlink_b1_struct_drift(softlink_b1_point_t p);
#endif
""")
    writeFile(v2 / "structdrift.h", """
#ifndef SOFTLINK_B1_STRUCTDRIFT_H
#define SOFTLINK_B1_STRUCTDRIFT_H
typedef struct { long x; long y; long z; } softlink_b1_point_t;
int softlink_b1_struct_drift(softlink_b1_point_t p);
#endif
""")
    writeFile(dir / "structdrift_binding.nim", """
import softlink

type SoftlinkB1Point {.importc: "softlink_b1_point_t", header: "structdrift.h".} = object

dynlib "libsoftlinkb1structdrift.so":
  proc softlink_b1_struct_drift(p: SoftlinkB1Point): cint {.cdecl, header: "structdrift.h".}
""")
    let modulePath = dir / "structdrift_binding.nim"
    let opts = defaultHarvestOptions()

    let atV1 = probeOutcomes("nim", modulePath, v1, "softlink_b1_struct_drift", dir, opts)
    let atV2 = probeOutcomes("nim", modulePath, v2, "softlink_b1_struct_drift", dir, opts)
    removeDir(dir)

    # The honest gap: BOTH classify fkVerified, even though the struct's
    # true layout genuinely changed between the two versions.
    check classify(atV1) == fkVerified
    check classify(atV2) == fkVerified

# ---------------------------------------------------------------------------
# Code-review finding F1(a): enumerateCorpusVersions must fail loudly on a
# cmpVersion-aliasing pair of on-disk directory names (e.g. "1.09" and "1.9"
# both parse to the run-sequence @[1, 9] — see softlink/versions'
# parseVersion doc comment), not silently let one of the two get
# misclassified by compressFacts' strictly-increasing-run assumption.
# ---------------------------------------------------------------------------
suite "enumerateCorpusVersions — cmpVersion-aliasing guard (code-review finding F1)":
  let aliasDir = getTempDir() / "sl_harvest_alias_test_corpus"

  test "aliasing directory names ('1.09' vs '1.9') raise HarvestError naming both":
    if dirExists(aliasDir): removeDir(aliasDir)
    createDir(aliasDir / "1.09")
    createDir(aliasDir / "1.9")
    createDir(aliasDir / "2.0")
    var raised = false
    var msg = ""
    try:
      discard enumerateCorpusVersions(aliasDir)
    except HarvestError as e:
      raised = true
      msg = e.msg
    removeDir(aliasDir)
    check raised
    check "1.09" in msg
    check "1.9" in msg

  test "non-aliasing directory names are unaffected (control)":
    if dirExists(aliasDir): removeDir(aliasDir)
    createDir(aliasDir / "1.9")
    createDir(aliasDir / "1.10")
    createDir(aliasDir / "2.0")
    let versions = enumerateCorpusVersions(aliasDir)
    removeDir(aliasDir)
    check versions == @["1.9", "1.10", "2.0"]

# ---------------------------------------------------------------------------
# Code-review finding F6: the harvester's real `nim c` subprocess invocation
# (`runProcess`) must never hang forever nor accumulate unbounded output —
# both are real DoS/resource-exhaustion risks for a tool that shells out to
# a compiler dozens of times per harvest. `runProcess` takes explicit
# `timeoutMs`/`maxOutputBytes` bounds and raises `HarvestError` (never just
# silently truncates or hangs) when either is exceeded. `sleep`/`yes`/`echo`
# (real subprocesses via the SAME `startProcess` machinery `compileProbe`
# uses, not a mock) exercise all three outcomes directly, kept well under a
# few seconds of wall time by construction (small timeouts, small caps).
# ---------------------------------------------------------------------------
suite "runProcess — bounded time and output (code-review finding F6)":
  test "a hanging child is killed after compileTimeoutMs and raises HarvestError":
    let t0 = epochTime()
    var raised = false
    var msg = ""
    try:
      discard runProcess("sleep", @["30"], 200, 16_777_216)
    except HarvestError as e:
      raised = true
      msg = e.msg
    let elapsed = epochTime() - t0
    check raised
    check msg.len > 0
    check elapsed < 5.0  # nowhere near the 30s the child would otherwise run

  test "unbounded output is capped and raises HarvestError":
    var raised = false
    var msg = ""
    try:
      discard runProcess("yes", @[], 5_000, 1024)
    except HarvestError as e:
      raised = true
      msg = e.msg
    check raised
    check msg.len > 0

  test "a normal, fast command still returns its real output and exit code":
    let (output, exitCode) = runProcess("echo", @["hello"], 5_000, 16_777_216)
    check "hello" in output
    check exitCode == 0

  when defined(posix):
    test "a grandchild holding stdout open after the direct child dies " &
         "still returns promptly on timeout (R2-2 group-kill regression)":
      ## Reproduces the confirmed hang: `sh -c "sleep 30 & wait"` backgrounds
      ## `sleep 30` (detached from `sh`'s own job control via `&`) and then
      ## `wait`s on it — so `sh` itself lives exactly as long as `sleep`
      ## does and is NOT the process actually holding the pipe open past any
      ## direct-child kill. Killing only the immediate child (old
      ## behavior: plain `kill(p)`, PID-only, no process group) leaves
      ## `sleep 30` — a grandchild reparented once `sh` is reaped — still
      ## holding the merged stdout pipe's write-end open, so
      ## `readOutputThread`'s blocked `readData` never sees EOF and
      ## `runProcess` never returns within the 30s the child would
      ## otherwise run. The fix (`killProcessTree`: `killpg` on the
      ## `poDaemon`-created process group) must reach `sleep 30` too, so
      ## this must return well before 30s elapse.
      let t0 = epochTime()
      var raised = false
      var msg = ""
      try:
        discard runProcess("sh", @["-c", "sleep 30 & wait"], 1_500, 1_000_000)
      except HarvestError as e:
        raised = true
        msg = e.msg
      let elapsed = epochTime() - t0
      check raised
      check "did not finish within" in msg
      # Must return in well under the grandchild's 30s lifetime — proves
      # `runProcess` returned because it killed the tree, not because the
      # orphaned `sleep 30` eventually exited on its own.
      check elapsed < 10.0
