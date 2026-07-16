## RFC-0001 SS4 B.2/B.3 slice B3: harvester classification loop —
## integration + pure-classifier tests.
##
## NOT compiled by the regular test suite target (`test_softlink.nim`); run
## explicitly (`nim c -r --path:src tests/tharvest.nim`) by the `nimble
## test` task's Linux branch (harvester probing is real `nim c` subprocess
## work — kept out of the main suite's hot path, mirrors this file's own
## dump-generation cost, one real compile per (version, symbol) probed).
import std/[unittest, os, osproc, tables, strutils, json]
import ../tools/harvest/harvester
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

suite "harvester CLI shim — drift alarm exit code (RFC-0001 SS4 B.4, slice B5, integration)":
  ## The slice is explicitly "(integration)": the RFC text says `softlink
  ## harvest` "exits nonzero" — a claim about the actual CLI process, not
  ## just the pure `driftAlarm` decision. This compiles AND RUNS the real
  ## `when isMainModule` shim (`tools/harvest/harvester.nim`) against the
  ## already-generated dump + the real fixture corpus (both still on disk
  ## at this point — `dumpDir` is only removed at the very end of this
  ## file) via one `nim c -r` invocation, exactly the usage line the
  ## module's own doc comment gives: `harvester <dumpFile> <corpusDir>
  ## [nimPath ...]`.
  ##
  ## Scoping (per the slice brief): only the nonzero-exit path is checked
  ## here. A cheap "success path is still exit 0" fixture would need a
  ## second, no-mismatch binding/corpus — a second real harvest, doubling
  ## this already ~1-minute-of-wall-time suite's cost for a fact already
  ## covered for free at the `driftAlarm` unit level above (the shim's
  ## `quit(1)` is a direct, untested-in-isolation `if tripped: quit(1)` --
  ## nothing about exit-0 behavior is specific to the CLI wiring). See the
  ## slice brief's own explicit accept-nonzero-only instruction.
  test "running the real CLI shim against the dump + corpus exits nonzero and prints the F3 diagnosis":
    let harvesterModule = "tools" / "harvest" / "harvester.nim"
    let shimCmd = "nim c -r --path:src " & harvesterModule & " " & dumpFile &
      " " & ("tests" / "corpus")
    let (output, exitCode) = execCmdEx(shimCmd)
    check exitCode != 0
    check f3Sentence in output

removeDir(dumpDir)
