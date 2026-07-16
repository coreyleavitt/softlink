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
    ## This fixture corpus has only 3 probed symbols across 3 versions — far
    ## below the scale where O(k·log n) bisection wins over "up to 3
    ## compiles per symbol per version" (the standard path's own cost
    ## shape). Worked by hand BEFORE this assertion was written (see the
    ## slice's own handoff notes) and then confirmed against a real run:
    ##
    ## STANDARD path, per version (baseline + up to 2 compiles/symbol):
    ##   1.0.0: baseline(1) + stable verified(2) + changed verified(2) +
    ##          added ABSENT(1, existence only) = 6
    ##   2.0.0: baseline(1) + stable verified(2) + changed MISMATCH(2) +
    ##          added verified(2) = 7
    ##   3.0.0: baseline FAILS(1); every symbol unknown, 0 extra = 1
    ##   TOTAL = 6 + 7 + 1 = 14
    ##
    ## FAST path, per version (define-free compile first; corpuslib_added
    ## is the one 1.0.0 drift, corpuslib_changed the one 2.0.0 drift):
    ##   1.0.0: define-free FAILS(1) [added is absent] -> baseline ok(1) ->
    ##          bisect{stable,changed,added}: root FAILS(1), left{stable}
    ##          PASSES(1), right{changed,added} FAILS(1), left{changed}
    ##          PASSES(1), right{added} FAILS(1) = 5 group compiles ->
    ##          singleton "added" -> standard existence-only(1, absent) =
    ##          1 + 1 + 5 + 1 = 8
    ##   2.0.0: define-free FAILS(1) [changed mismatches] -> baseline ok(1)
    ##          -> bisect: root FAILS(1), left{stable} PASSES(1),
    ##          right{changed,added} FAILS(1), left{changed} FAILS(1)
    ##          [singleton], right{added} PASSES(1) = 5 group compiles ->
    ##          singleton "changed" -> standard existence+verify(2,
    ##          mismatch) = 1 + 1 + 5 + 2 = 9
    ##   3.0.0: define-free FAILS(1) [broken #include] -> baseline ALSO
    ##          FAILS(1); every symbol unknown, no bisection = 1 + 1 = 2
    ##   TOTAL = 8 + 9 + 2 = 19
    ##
    ## So on THIS fixture the fast path costs MORE real compiles (19 > 14)
    ## — expected and fine: a 3-symbol corpus is dominated by the fast
    ## path's own overhead (a define-free compile plus a baseline probe
    ## PLUS the bisection tree, paid IN ADDITION TO the standard pipeline
    ## for every symbol that doesn't settle at the whole-module level,
    ## which on this corpus is every symbol at every non-broken version).
    ## The O(k·log n) win the RFC describes shows up at real-corpus scale
    ## (hundreds of symbols, few drifted) — not on a 3-symbol fixture where
    ## k/n is large and log n is tiny. This assertion pins the CONCRETE,
    ## derived-then-confirmed counts rather than a directional "fewer"
    ## claim that would be false for this corpus.
    check r.compileCount == 14
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

  test "corpuslib_protoonly is skipped, never probed":
    check r.skipped.len == 1
    check r.skipped[0].cname == "corpuslib_protoonly"
    check "prototype-only" in r.skipped[0].reason
    check "corpuslib_protoonly" notin r.probedSymbols

  test "the human-readable report mentions every probed symbol and the skip":
    check "corpuslib_stable" in r.report
    check "corpuslib_changed" in r.report
    check "corpuslib_added" in r.report
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
