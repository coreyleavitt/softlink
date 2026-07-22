## RFC-0001 SS4 B.2/B.3 slice B3: harvester classification loop —
## integration + pure-classifier tests.
##
## NOT compiled by the regular test suite target (`test_softlink.nim`); run
## explicitly (`nim c -r --path:src tests/tharvest.nim`) by the `nimble
## test` task's Linux branch (harvester probing is real `nim c` subprocess
## work — kept out of the main suite's hot path, mirrors this file's own
## dump-generation cost, one real compile per (version, symbol) probed).
import std/[unittest, os, osproc, tables, strutils, json, times]
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
# Pure classifier: every row of RFC-0001 SS4 B.2's classification table,
# including the row integration can't cheaply reach (a verify-stage failure
# WITHOUT softlink's own assert message -> unknown, the round-2 fix over
# round 1's "any non-assert failure forced into absent").
# ---------------------------------------------------------------------------
suite "classify — pure decision table (RFC-0001 SS4 B.2)":
  test "baseline fails -> unknown, regardless of anything else":
    check classify(ProbeOutcomes(baselineOk: false)) == fkUnknown
    check classify(ProbeOutcomes(baselineOk: false, existenceOk: true,
                                  verifyOk: true)) == fkUnknown

  test "baseline ok, existence fails -> absent":
    check classify(ProbeOutcomes(baselineOk: true, existenceOk: false)) == fkAbsent
    # verifyOk/assertMsgSeen must not matter once existence has failed.
    check classify(ProbeOutcomes(baselineOk: true, existenceOk: false,
                                  verifyOk: true, assertMsgSeen: true)) == fkAbsent

  test "baseline ok, existence ok, verify ok -> verified":
    check classify(ProbeOutcomes(baselineOk: true, existenceOk: true,
                                  verifyOk: true)) == fkVerified

  test "baseline ok, existence ok, verify fails WITH softlink's assert message -> mismatch":
    check classify(ProbeOutcomes(baselineOk: true, existenceOk: true,
                                  verifyOk: false, assertMsgSeen: true)) == fkMismatch

  test "baseline ok, existence ok, verify fails WITHOUT the assert message -> unknown (round-2 fix)":
    # The round-1 design forced any non-assert verify failure into `absent`;
    # round 2 (this row) requires it classify `unknown` instead — a verify
    # failure for some OTHER reason (compiler crash, unrelated syntax error
    # elsewhere in the TU, ...) is not evidence the symbol is absent.
    check classify(ProbeOutcomes(baselineOk: true, existenceOk: true,
                                  verifyOk: false, assertMsgSeen: false)) == fkUnknown

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

# Hoisted to file scope (rather than a suite-local `let`) so BOTH the
# "harvest — full classification matrix" suite below AND the slice-B5
# "driftAlarm — integration" suite further down can reuse this ONE real
# harvest — `unittest.suite` is `{.dirty.}` but still wraps its body in a
# `block:`, so a suite-local `let` is invisible from a sibling suite; only
# a genuinely file-scope binding is shared. Never re-harvested (real `nim
# c --noLinking` subprocess work, ~1 minute wall time — see
# `runHarvesterCheck`'s doc comment in softlink.nimble).
let r = harvest(dumpFile, "tests" / "corpus")

# RFC-0001 SS4 B.2, optional fast-path (slice B7): a SECOND real harvest of
# the IDENTICAL dump/corpus, with `opts.fastPath = true` — yes, this roughly
# doubles this file's already ~1-minute wall time; acceptable, since it's
# the only way to prove the fast path's `facts` are byte-for-byte identical
# to the standard path's on a real toolchain, not merely by inspection.
var fastOpts = defaultHarvestOptions()
fastOpts.fastPath = true
let rFast = harvest(dumpFile, "tests" / "corpus", fastOpts)

suite "harvest fastPath — identical facts to the standard path (RFC-0001 SS4 B.2, slice B7)":
  test "facts are deep-equal between the standard and fast-path harvests":
    check rFast.facts == r.facts

  test "baselineOk is deep-equal between the standard and fast-path harvests":
    check rFast.baselineOk == r.baselineOk

  test "skipped (corpus-invariant procs) is deep-equal between the two harvests":
    check rFast.skipped == r.skipped

  test "compile-count arithmetic on this fixture corpus (honest, derived, not assumed)":
    ## This fixture corpus has 4 probed symbols across 3 versions (code-
    ## review Finding #19.7 added `corpuslib_crosscheck` — same true,
    ## unchanging signature/story as `corpuslib_stable`, bound via BOTH
    ## `header` and `prototype` together — alongside the original 3) — far
    ## below the scale where O(k·log n) bisection wins over "up to 2
    ## compiles per symbol per version" (the standard path's own cost
    ## shape). Worked by hand and then confirmed against a real run.
    ## `probeTargets`' order (dump.procs order, `corpuslib_protoonly`
    ## excluded as corpus-invariant) is
    ## [stable, changed, added, crosscheck]; `bisectPlan` splits a group of
    ## n into a left half of `n div 2` and a right half of the remainder.
    ##
    ## STANDARD path, per version (baseline + up to 2 compiles/symbol):
    ##   1.0.0: baseline(1) + stable verified(2) + changed verified(2) +
    ##          added ABSENT(1, existence only) + crosscheck verified(2) = 8
    ##   2.0.0: baseline(1) + stable verified(2) + changed MISMATCH(2) +
    ##          added verified(2) + crosscheck verified(2) = 9
    ##   3.0.0: baseline FAILS(1); every symbol unknown, 0 extra = 1
    ##   TOTAL = 8 + 9 + 1 = 18
    ##
    ## FAST path, per version (define-free compile first; corpuslib_added
    ## is the one 1.0.0 drift, corpuslib_changed the one 2.0.0 drift;
    ## corpuslib_crosscheck never drifts, same as corpuslib_stable):
    ##   1.0.0: define-free FAILS(1) [added is absent] -> baseline ok(1) ->
    ##          bisect{stable,changed,added,crosscheck} (root splits into
    ##          left{stable,changed}, right{added,crosscheck}):
    ##          root FAILS(1) [added absent poisons the whole group],
    ##          left{stable,changed} PASSES together(1) [both verified,
    ##          no further split needed], right{added,crosscheck}
    ##          FAILS(1) [added absent], splits into left{added} FAILS(1)
    ##          [singleton], right{crosscheck} PASSES(1) [singleton] =
    ##          5 group compiles -> singleton "added" -> standard
    ##          existence-only(1, absent) = 1 + 1 + 5 + 1 = 8
    ##   2.0.0: define-free FAILS(1) [changed mismatches] -> baseline ok(1)
    ##          -> bisect{stable,changed,added,crosscheck}: root FAILS(1)
    ##          [changed mismatches poisons the whole group],
    ##          left{stable,changed} FAILS(1) [changed mismatches], splits
    ##          into left{stable} PASSES(1) [singleton], right{changed}
    ##          FAILS(1) [singleton], right{added,crosscheck} PASSES
    ##          together(1) [both verified, no further split needed] =
    ##          5 group compiles -> singleton "changed" -> standard
    ##          existence+verify(2, mismatch) = 1 + 1 + 5 + 2 = 9
    ##   3.0.0: define-free FAILS(1) [broken #include] -> baseline ALSO
    ##          FAILS(1); every symbol unknown, no bisection = 1 + 1 = 2
    ##   TOTAL = 8 + 9 + 2 = 19
    ##
    ## So on THIS fixture the fast path costs MORE real compiles (19 > 18)
    ## — expected and fine: a 4-symbol corpus is dominated by the fast
    ## path's own overhead (a define-free compile plus a baseline probe
    ## PLUS the bisection tree, paid IN ADDITION TO the standard pipeline
    ## for every symbol that doesn't settle at the whole-module level,
    ## which on this corpus is every symbol at every non-broken version).
    ## The O(k·log n) win the RFC describes shows up at real-corpus scale
    ## (hundreds of symbols, few drifted) — not on a 4-symbol fixture where
    ## k/n is large and log n is tiny. This assertion pins the CONCRETE,
    ## derived-then-confirmed counts rather than a directional "fewer"
    ## claim that would be false for this corpus.
    check r.compileCount == 18
    check rFast.compileCount == 19

suite "runCalibration — preflight (RFC-0001 SS4 B.2)":
  test "the dev toolchain's own known-answer trio classifies correctly":
    let outcome = runCalibration()
    check outcome.ok
    check outcome.diagnosis.len == 0

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
    check "SKIPPED corpuslib_protoonly" in r.report

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
