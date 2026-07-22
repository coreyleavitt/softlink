## Finding #24(b) (code-review round 2 coverage gap): the RFC-0001 §C.3/
## §C.4b "no double-count" guarantee (`tests/tcompat_report_manifest.nim`'s
## "no double-count: an already-absent symbol whose facts also carry a
## mismatch interval..." test) only ever exercises ONE such symbol at a
## time. `computeMissingPartition` (`src/softlink.nim`) is a thin per-
## symbol dispatch loop around the pure `classifyAbsence`
## (`src/softlink/manifest.nim`) — a `case` over one `AbsenceClass` value,
## so it structurally cannot double-count a SINGLE symbol — but nothing
## proves multiple simultaneously-anomalous symbols classify independently
## in the same pass, without cross-symbol interference (one symbol's facts
## leaking into another's classification, or entries getting merged/
## deduplicated across different symbols).
##
## `classifyAbsence` is pure and exported from `softlink/manifest` (no
## `std/macros`, no library load, no `dynlib` block needed — this file
## tests the exact shared logic `computeMissingPartition` dispatches into,
## at the layer where it actually lives), so this reproduces
## `computeMissingPartition`'s own per-symbol loop shape directly against
## THREE symbols at once, at the same probed version:
##  - `sym_mismatch_a`, `sym_mismatch_b`: both absent facts entirely (no
##    runtime resolution modeled here -- classifyAbsence doesn't care
##    whether the symbol resolved, only what the headers say), but BOTH
##    carry a `mismatch` interval covering the probed version -> both must
##    independently classify `acAnomalous`.
##  - `sym_expected`: carries an `absent` interval covering the probed
##    version instead -> must classify `acExpected` -- a different answer,
##    proving the loop isn't just returning one fixed class for everything.
import std/[unittest, sequtils, sets]
import softlink/manifest

suite "classifyAbsence -- multi-symbol no-double-count (finding #24b)":
  test "two independently-mismatched symbols + one expected-absent symbol, same probed version: exactly one classification each, no cross-symbol interference":
    var symA = SymbolFacts(cname: "sym_mismatch_a")
    symA.header[fkMismatch] = @[VersionInterval(lo: "4.0.0", hi: "")]
    var symB = SymbolFacts(cname: "sym_mismatch_b")
    symB.header[fkMismatch] = @[VersionInterval(lo: "4.0.0", hi: "")]
    var symC = SymbolFacts(cname: "sym_expected")
    symC.header[fkAbsent] = @[VersionInterval(lo: "4.0.0", hi: "")]
    let symbols = @[symA, symB, symC]

    # Mirrors `computeMissingPartition`'s own per-symbol dispatch loop
    # (`src/softlink.nim`): one `classifyAbsence` call per missing symbol,
    # `acNone` contributing no entry, all at the SAME probed version and
    # with no `{.since.}` claim in play.
    let missing = @["sym_mismatch_a", "sym_mismatch_b", "sym_expected"]
    var partition: seq[tuple[symbol: string, class: AbsenceClass]] = @[]
    for sym in missing:
      let cls = classifyAbsence(symbols, sym, "4.0.0", "", "")
      if cls != acNone:
        partition.add (symbol: sym, class: cls)

    check partition.len == 3
    check (symbol: "sym_mismatch_a", class: acAnomalous) in partition
    check (symbol: "sym_mismatch_b", class: acAnomalous) in partition
    check (symbol: "sym_expected", class: acExpected) in partition

    # The no-double-count guarantee itself: exactly one partition entry
    # per symbol, across the WHOLE multi-symbol pass -- not just
    # algebraically obvious from a single pair.
    var seen: seq[string] = @[]
    for entry in partition:
      check entry.symbol notin seen
      seen.add entry.symbol

  test "three-way tie at the same probed version: all-mismatch symbols each still classify independently":
    # A tighter variant: ALL THREE symbols anomalous at once (no
    # differentiating control), same probed version -- proves the
    # independence holds even when every symbol resolves to the identical
    # class, not just when one control symbol stands out.
    var symbols: seq[SymbolFacts] = @[]
    for name in ["sym_x", "sym_y", "sym_z"]:
      var sf = SymbolFacts(cname: name)
      sf.header[fkMismatch] = @[VersionInterval(lo: "2.0.0", hi: "3.0.0")]
      symbols.add sf

    let missing = @["sym_x", "sym_y", "sym_z"]
    var partition: seq[tuple[symbol: string, class: AbsenceClass]] = @[]
    for sym in missing:
      let cls = classifyAbsence(symbols, sym, "2.5.0", "", "")
      if cls != acNone:
        partition.add (symbol: sym, class: cls)

    check partition.len == 3
    check partition.allIt(it.class == acAnomalous)
    check partition.mapIt(it.symbol).toHashSet.len == 3

# Code review CR1-8, cell 2: `classifyAbsence`'s RFC-0002 §4.3 `until`-
# demotion axis (the `untilVersion` parameter) never got its OWN
# multi-symbol independence pin — `tcov_classify_absence_multi_pair`'s
# existing suite above (finding #24b) covers multi-symbol independence for
# the ORIGINAL RFC-0001 header-facts axis, but every one of its calls
# passes `untilVersion = ""`. `classifyAbsence`'s until-branch runs FIRST,
# before the header-facts loop even starts (src/softlink/manifest.nim),
# so two symbols that are simultaneously absent, sharing the same
# `symbols` slice and the same probed version, but carrying DIFFERENT
# declared `until` values, must classify independently on this axis too —
# nothing should leak from one symbol's `untilVersion` argument into the
# other's.
suite "classifyAbsence -- multi-symbol until-axis independence (review CR1-8, cell 2)":
  test "two simultaneously-absent symbols with different declared until values classify independently at the same probed version":
    # sym_until_low carries no header facts at all -- proving its
    # classification comes SOLELY from the until-demotion branch (there is
    # nothing else here that could produce acExpected).
    let symLow = SymbolFacts(cname: "sym_until_low")
    # sym_until_high DOES carry a `verified` header fact covering the
    # probed version -- the header-facts branch this symbol's OWN call
    # falls through to once its (higher) until fails to demote it.
    var symHigh = SymbolFacts(cname: "sym_until_high")
    symHigh.header[fkVerified] = @[VersionInterval(lo: "4.0.0", hi: "")]
    let symbols = @[symLow, symHigh]
    let probed = "4.0.0"

    # sym_until_low: probed ("4.0.0") is AT-OR-ABOVE its own declared
    # until ("3.0.0") -> demoted to acExpected via the until branch, before
    # the header-facts loop runs at all for this call.
    let clsLow = classifyAbsence(symbols, "sym_until_low", probed, "", "3.0.0")
    check clsLow == acExpected

    # sym_until_high: the SAME `symbols` slice, the SAME probed version,
    # but its own until ("5.0.0") is still AHEAD of "4.0.0" -> the until
    # branch does NOT fire for this call; it falls through to the
    # header-facts loop, whose `verified` interval covers "4.0.0" ->
    # acAnomalous. A genuinely different answer than sym_until_low's own,
    # from the same shared `symbols` argument -- proving the demotion is
    # keyed off THIS CALL's own `untilVersion` argument, not anything
    # shared or global, and that one symbol's demotion doesn't leak into
    # (suppress or force) the other's classification.
    let clsHigh = classifyAbsence(symbols, "sym_until_high", probed, "", "5.0.0")
    check clsHigh == acAnomalous
