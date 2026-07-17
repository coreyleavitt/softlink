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
      let cls = classifyAbsence(symbols, sym, "4.0.0", "")
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
      let cls = classifyAbsence(symbols, sym, "2.5.0", "")
      if cls != acNone:
        partition.add (symbol: sym, class: cls)

    check partition.len == 3
    check partition.allIt(it.class == acAnomalous)
    check partition.mapIt(it.symbol).toHashSet.len == 3
