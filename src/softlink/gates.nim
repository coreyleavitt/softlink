## `softlink/gates` — RFC-0002 §5 Layer 2's pure compile-time gate
## synthesizer: turns a `{.since/until.}` semver bound plus a `versionMacros`
## macro-name list into a C preprocessor predicate string. A leaf module by
## design (§5: "a pure function ... living in a new leaf module
## `src/softlink/gates.nim`, golden-tested outside the macro") — no
## `std/macros`/`NimNode` anywhere in this file, string/int/seq in, string
## out, so every rule below is a trivial, macro-expansion-free unit test.
##
## The synthesis rules, precisely (RFC-0002 §5):
## - **Bound validation**: a bound's parsed components must be all-numeric
##   (no alphabetic runs — there is no C macro a `"4.16.0rc1"` component
##   could compare against) and, once TRAILING zero components are stripped
##   (see below), no LONGER than the macro list (a `"4.16.3"` bound against
##   two macros has no C signal for the trailing nonzero `3` — silent
##   truncation would synthesize a gate that's wrong at exactly the boundary
##   that matters). The excess check runs AFTER the strip, not before —
##   `"2.0.0"` against one macro strips to `[2]` and must be accepted
##   identically to `"2"`; checking the raw 3-component parse first would
##   reject a bound this module's own equivalence invariant says is
##   identical to one that passes (CR1-2). Either violation is reported via
##   `GateResult`'s error case, never raised/thrown — this module has no
##   macro context to `error()` into; the caller
##   (`softlink/pragmas.synthesizeVersionGates`) turns a `GateError` into a
##   proc-anchored macro error.
## - Bounds SHORTER than the macro list need no special-casing: the trailing-
##   zero strip below and the "compare only a macro-list PREFIX" scheme
##   already make `"4.16"` and `"4.16.0"` synthesize identically — there is
##   no separate padding step (padding up to the macro count and then
##   stripping trailing zeros back off is a no-op composition; see below).
## - **Predicate construction**: strip TRAILING zero components from the
##   RAW parsed bound, then emit the full nested lexicographic comparison
##   over the remaining components. Dropping a NON-trailing zero is wrong —
##   `since: "4.0.5"` is the pinned counterexample: naively eliding the
##   middle `0` would compare `"4.5"` against the wrong two macros (major,
##   minor) instead of the right three (major, minor, patch), silently
##   excluding versions this module's own golden test proves must be
##   in-range. Only a TRAILING run of zeros is dropped, because a
##   trailing-zero component compares as `0` under the lexicographic order
##   already used everywhere else in this codebase (`softlink/versions`'
##   `cmpRuns`) — stripping it is provably equivalence-preserving for both
##   `<` and `>=` lexicographic comparison; nothing else is assumed.
## - AND-combined when both bounds are present (`synthesizeGate`);
##   until-only is just the `<` predicate. This module does not itself
##   enforce "since-only procs are not synthesized" — that is a SCOPE rule
##   the macro-wiring layer applies (only calls this module for
##   until-carrying procs); this module is a pure combinator that will
##   happily synthesize a since-only gate if asked (used internally by
##   `synthesizeGate`'s both-bounds path, and exercised directly by this
##   module's own golden tests).

import std/strutils

type
  BoundKind* = enum
    bkSince  ## lower bound, inclusive: rendered as `>=` (mirrored form)
    bkUntil  ## upper bound, exclusive: rendered as `<`

  GateErrorKind* = enum
    geAlphaRun          ## the bound contains a non-numeric (alphabetic) run
    geExcessComponents  ## the bound has more components than the macro list

  GateError* = object
    kind*: GateErrorKind
    bound*: BoundKind
    value*: string          ## the offending bound string, verbatim
    componentCount*: int    ## geExcessComponents only: how many components `value` has
    macroCount*: int        ## geExcessComponents only: how many macros were available

  GateResult* = object
    case ok*: bool
    of true:
      predicate*: string      ## the synthesized C preprocessor predicate
      usedMacros*: seq[string]  ## the macro-list PREFIX actually referenced
                                 ## (post trailing-zero-strip) — "" for a
                                 ## degenerate all-zero bound, whose predicate
                                 ## is the literal `"0"`/`"1"` and references
                                 ## no macro at all.
    of false:
      error*: GateError

func hasAlphaRun(bound: string): bool =
  ## True iff `bound` contains any ASCII letter anywhere — deliberately NOT
  ## `softlink/versions.parseVersion`'s "fold every alpha run into a
  ## positive trailing component" reading (that scheme exists for corpus
  ## COMPARISON, where an arbitrary release tag must sort somewhere; here,
  ## `until`'s job is to name C macro VALUES, and there is no macro a
  ## `"rc1"` component could ever compare against, so any letter is
  ## unconditionally a synthesis error regardless of where it appears).
  for c in bound:
    if c in {'a'..'z', 'A'..'Z'}:
      return true
  false

func parseComponents(bound: string): seq[int] =
  ## Split `bound` into its dot/hyphen/plus-separated numeric components —
  ## e.g. `"4.16.0"` -> `@[4, 16, 0]`. Only reached after `hasAlphaRun`
  ## already returned false, so every run here is guaranteed all-digit.
  var cur = ""
  for c in bound:
    if c in '0'..'9':
      cur.add(c)
    elif cur.len > 0:
      result.add(parseInt(cur))
      cur = ""
  if cur.len > 0:
    result.add(parseInt(cur))

func buildLexicographicExpr(macros: seq[string], comps: seq[int], kind: BoundKind): string =
  ## The full nested lexicographic expansion (§5), flattened to a disjunction
  ## of self-contained conjunctions — one term per component `i`, each term
  ## an equality chain over components `0 ..< i` conjoined with the decisive
  ## comparison at `i`. Fully parenthesized throughout, so this is immune to
  ## `&&`/`||` precedence regardless of how many components are combined
  ## (the naive single-recursive-paren approach breaks precedence past two
  ## components — verified by hand and avoided by construction here).
  ##
  ## `bkUntil` uses a strict `<` at every position (the RFC's own
  ## `until: "4.16.0"` example, 2 components: `(A < 4) || (A == 4 && B < 16)`
  ## — this reproduces that string exactly). `bkSince` mirrors it with `>`
  ## at every position except the LAST, which uses `>=` — the standard
  ## lexicographic-greater-or-equal expansion (a strict `>` at any earlier
  ## position already decides "greater"; equality all the way through must
  ## still count as "at or after" the bound, which only the final `>=`
  ## captures).
  var terms: seq[string] = @[]
  for i in 0 ..< comps.len:
    var parts: seq[string] = @[]
    for j in 0 ..< i:
      parts.add(macros[j] & " == " & $comps[j])
    let isLast = i == comps.len - 1
    let op =
      case kind
      of bkUntil: "<"
      of bkSince: (if isLast: ">=" else: ">")
    parts.add(macros[i] & " " & op & " " & $comps[i])
    terms.add("(" & parts.join(" && ") & ")")
  terms.join(" || ")

proc synthesizeBoundPredicate*(macros: seq[string], bound: string, kind: BoundKind): GateResult =
  ## Synthesize the C predicate for ONE bound (`since` or `until`) against
  ## `macros` (most-significant-first, e.g.
  ## `@["Z3_MAJOR_VERSION", "Z3_MINOR_VERSION"]`). Pure — no macro context;
  ## failures come back as `GateResult.error`, never raised.
  if hasAlphaRun(bound):
    return GateResult(ok: false, error: GateError(
      kind: geAlphaRun, bound: kind, value: bound))
  var comps = parseComponents(bound)
  # Strip the TRAILING zero run from the RAW parse FIRST, before checking
  # for excess components. This replaces the old pad-to-macros.len-then-
  # strip dance: appending zeros and then stripping trailing zeros is
  # order-independent with stripping-then-nothing — a raw parse's own
  # trailing zeros strip away identically whether or not it was first
  # padded out to some longer length, since any zeros appended past the
  # existing trailing-zero run would immediately strip back off too. So
  # stripping the raw parse directly is algebraically equivalent to the
  # previous pad-then-strip, without ever needing to pad.
  #
  # Checking excess AFTER this strip (not before, as this used to do) is
  # the CR1-2 fix: `"2.0.0"` against one macro raw-parses to 3 components,
  # which used to be flagged as excess even though it strips to `[2]` and
  # is mathematically identical to `"2"` (which always passed). Only a
  # genuinely-informative excess — a NONZERO component surviving the strip,
  # like the trailing `3` in `"4.16.3"` against two macros — has no C macro
  # to compare against and is still rejected below.
  while comps.len > 0 and comps[^1] == 0:
    comps.setLen(comps.len - 1)
  if comps.len > macros.len:
    return GateResult(ok: false, error: GateError(
      kind: geExcessComponents, bound: kind, value: bound,
      componentCount: comps.len, macroCount: macros.len))
  if comps.len == 0:
    # Degenerate all-zero bound (e.g. "0.0.0"): `until` excludes nothing has
    # ever preceded it (predicate is unconditionally false — no version to
    # be "< 0.0.0"); `since` admits everything (predicate is unconditionally
    # true — every version is ">= 0.0.0"). No macro is referenced.
    let predicate = if kind == bkUntil: "0" else: "1"
    return GateResult(ok: true, predicate: predicate, usedMacros: @[])
  GateResult(ok: true, predicate: buildLexicographicExpr(macros, comps, kind),
    usedMacros: macros[0 ..< comps.len])

proc synthesizeGate*(macros: seq[string], sinceVersion, untilVersion: string): GateResult =
  ## The proc-level combinator (§5): `until`-only synthesizes just the `<`
  ## predicate; both bounds present AND-combines the `>=` since predicate
  ## with the `<` until predicate. `untilVersion` must be non-empty — the
  ## macro-wiring layer's scope rule ("until-carrying procs only") is this
  ## proc's precondition, not something it re-validates (a since-only call
  ## is meaningless here: there would be nothing to gate `p.verifyWhen`
  ## with in the first place, since RFC-0001's shipped since-only behavior
  ## is deliberately ungated).
  assert untilVersion.len > 0,
    "synthesizeGate requires a non-empty untilVersion (scope: until-carrying procs only)"
  let untilResult = synthesizeBoundPredicate(macros, untilVersion, bkUntil)
  if not untilResult.ok:
    return untilResult
  if sinceVersion.len == 0:
    return untilResult
  let sinceResult = synthesizeBoundPredicate(macros, sinceVersion, bkSince)
  if not sinceResult.ok:
    return sinceResult
  # Both prefixes are drawn from the SAME ordered macro list, so their union
  # is simply the longer of the two prefixes.
  let used =
    if sinceResult.usedMacros.len >= untilResult.usedMacros.len: sinceResult.usedMacros
    else: untilResult.usedMacros
  # `&&` binds tighter than `||`, so a sub-predicate that is itself a
  # top-level disjunction (`buildLexicographicExpr` joins 2+ terms with
  # " || ") MUST be parenthesized before conjoining — otherwise the `&&`
  # only reaches the FIRST disjunct, silently breaking the intended
  # "both bounds together" semantics. A single-term sub-predicate (already
  # one atomic, self-parenthesized comparison — no top-level `||`) needs no
  # extra wrapping; adding one anyway would just be redundant noise. `" || "`
  # never appears in a synthesized predicate except as this top-level join
  # (every comparison side is a plain macro identifier or integer literal),
  # so this substring check is exact, not a heuristic.
  proc wrapForAnd(pred: string): string =
    if " || " in pred: "(" & pred & ")" else: pred
  GateResult(ok: true,
    predicate: wrapForAnd(sinceResult.predicate) & " && " & wrapForAnd(untilResult.predicate),
    usedMacros: used)
