## RFC-0001 SS4 B.2/B.3 slice B3: harvester classification loop —
## integration + pure-classifier tests.
##
## NOT compiled by the regular test suite target (`test_softlink.nim`); run
## explicitly (`nim c -r --path:src tests/tharvest.nim`) by the `nimble
## test` task's Linux branch (harvester probing is real `nim c` subprocess
## work — kept out of the main suite's hot path, mirrors this file's own
## dump-generation cost, one real compile per (version, symbol) probed).
import std/[unittest, os, osproc, tables, strutils]
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

suite "runCalibration — preflight (RFC-0001 SS4 B.2)":
  test "the dev toolchain's own known-answer trio classifies correctly":
    let outcome = runCalibration()
    check outcome.ok
    check outcome.diagnosis.len == 0

suite "harvest — full classification matrix against the B3a fixture corpus":
  let r = harvest(dumpFile, "tests" / "corpus")

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

removeDir(dumpDir)
