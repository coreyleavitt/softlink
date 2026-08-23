## `softlink/versions` — version-string comparison and the pinned
## interval/fact types shared by softlink's `dynlib` macro and the
## `softlink harvest` CLI (RFC-0001 slice B0).
##
## A version string is parsed into the sequence of its **digit runs** and
## **alphabetic runs**, read left to right: a maximal run of ASCII digits
## becomes its integer value; a maximal run of ASCII letters (case-folded)
## becomes its **bijective base-26** ordinal — the same scheme spreadsheet
## column names use: ``a``=1 … ``z``=26, ``aa``=27, ``za``=677. Every other
## character (``.``, ``-``, ``+``, …) is pure run separator and contributes
## nothing to the sequence — but a letter run is NEVER a separator: a bare
## ``p`` (OpenSSL-style, ``"4.15.8p1"``) is itself parsed as an alpha run
## and contributes its base-26 value to the sequence, exactly like any
## other letter run (see `parseVersion`'s own worked example below — this
## comment previously, incorrectly, called such a letter "a separator";
## RFC-0002 §6 C4a drive-by fix).
##
## Comparison is lexicographic over the resulting integer sequences, with a
## missing trailing component treated as ``0`` — so ``"1.2"`` and
## ``"1.2.0"`` compare equal. There is no PARSED pre-release syntax (no
## ``-``/``+`` metadata grammar): every letter run, wherever it appears,
## becomes an ordinary POSITIVE trailing component under the same
## bijective base-26 rule, which means an alpha SUFFIX sorts ABOVE its bare
## numeric prefix (``"4.16.0-rc1"`` compares ABOVE ``"4.16.0"``) — the
## inverse of semver's own pre-release ordering. Callers that need
## semver-correct pre-release handling (e.g. RFC-0002 §4.4's declared-bound
## refusal, which must not treat a ``-rcN``/distro-suffixed probe as
## "newer" than its base release) use `compareToBound` below — the
## numeric-prefix-only comparator — instead of raw `cmpVersion`. The
## corpus this comparator targets is release tags, and one consistent
## versioning scheme per library is assumed (RFC-0001 §5 C.0). Cross-scheme
## version strings can collide under this ordering; that is documented,
## not defended against.
##
## A version string with **no runs at all** (e.g. ``""``, ``"..."``,
## ``"-"``) fails to parse. Parse failure is surfaced as a plain
## `Option[seq[int]]` — never an exception — so Stage C's load-time
## probing can classify an unparseable runtime version as "unattested"
## without wrapping every comparison in `try/except`.
##
## A digit run longer than 18 characters ALSO fails the whole string to
## parse (code-review finding CR1-3): 18 decimal digits is the largest
## width `val = val*10 + digit` can accumulate without ever exceeding
## `int64`'s range mid-computation, so it is the widest run this module
## can safely convert to an integer at all. A run of 19+ digits is not
## saturated to some sentinel "very large" value — saturation would
## invent an ordering for what is, by construction, not a legitimate
## version component (RFC-0001 §5 C.0's "one consistent versioning
## scheme" assumption does not extend to a hostile or corrupted runtime
## probe string) — the run instead makes the ENTIRE input unparseable,
## landing on the exact same `none(seq[int])` decline path as `""` or
## `"..."`. This is a RUNTIME hardening concern only: `parseVersion`'s
## compile-time callers (`softlink/pragmas`' since/until pragma
## validation) see only short, author-written bound literals, for which
## an 18-digit run is unreachable.
##
## An alphabetic run longer than 13 characters gets the SAME treatment,
## for the same reason (CR1-3 follow-up hardening): a base-26 run's
## worst case is all-`z` (value 26 per letter, the widest digit this
## alphabet has), and `val = val*26 + digit` accumulated over 13 such
## letters tops out at 2_580_398_988_131_886_038 — under `int64`'s
## 9_223_372_036_854_775_807 max — while 14 letters' worst case
## (67_090_373_691_429_037_014) overflows it. 13 is therefore the widest
## alpha run this module can safely convert without ever exceeding
## `int64`'s range mid-computation, exactly mirroring the digit-run
## bound above; a run of 14+ letters makes the whole string unparseable
## rather than raising `OverflowDefect` or silently wrapping.

import std/options
export options

type
  FactKind* = enum
    ## Classification of one C symbol's attested behavior at a given
    ## version, as recorded by the harvester (RFC-0001 §4). Pinned here,
    ## in the module both sides import, so the harvester (v0.9.0) and the
    ## runtime consumer (v0.10.0) cannot drift apart independently.
    fkVerified   ## Header-verified: the symbol's signature matched.
    fkAbsent     ## The header does not declare this symbol at all.
    fkMismatch   ## The header declares the symbol with a different signature.
    fkUnknown    ## Harvest could not classify (e.g. a broken header include).

  VersionInterval* = object
    ## A version range over the B0 total order. `""` means unbounded in
    ## that direction: `lo == ""` reads as "from the start of the corpus",
    ## `hi == ""` as "through the end of the corpus". Bounds are ordinary
    ## strings compared via `cmpVersion`/`parseVersion`, never as raw byte
    ## sequences.
    ##
    ## This is a type shape only — slice B0 does not implement interval
    ## containment, compression, or the disjoint/exhaustive invariant
    ## (those land in B4/B6a).
    lo*, hi*: string

  SymbolFacts* = object
    ## Per-symbol harvested facts: which `FactKind` held over which
    ## `VersionInterval`s, for one C symbol (`cname`). Slice B0 pins the
    ## shape only; the disjoint/exhaustive-by-construction guarantee over
    ## `header` and its manifest embedding are later slices (B4/B6a/B6b).
    cname*: string
    header*: array[FactKind, seq[VersionInterval]]

func isAsciiDigit(c: char): bool {.inline.} =
  c in '0'..'9'

func isAsciiAlpha(c: char): bool {.inline.} =
  c in {'a'..'z', 'A'..'Z'}

func toLowerAsciiChar(c: char): char {.inline.} =
  if c in 'A'..'Z': char(ord(c) + (ord('a') - ord('A'))) else: c

func cmpRuns(a, b: seq[int]): int =
  ## Lexicographic comparison of two already-parsed run-sequences, with a
  ## missing trailing component treated as `0`. An internal primitive over
  ## parsed sequences — `cmpVersion` is the public string-level entry
  ## point; not exported.
  let n = max(a.len, b.len)
  for idx in 0 ..< n:
    let av = if idx < a.len: a[idx] else: 0
    let bv = if idx < b.len: b[idx] else: 0
    result = cmp(av, bv)
    if result != 0:
      return result
  result = 0

func parseVersion*(v: string): Option[seq[int]] =
  ## Parse `v` into its run-sequence: each maximal run of ASCII digits
  ## becomes its integer value, each maximal run of ASCII letters
  ## (case-folded) becomes its bijective base-26 ordinal. Every other
  ## character is a pure separator. Returns `none(seq[int])` if `v`
  ## contains no digit or alphabetic runs at all — the only failure mode,
  ## and never an exception.
  ##
  ## Examples: ``"4.15.8p1"`` -> ``@[4, 15, 8, 16, 1]``; ``"1.1.1a"`` ->
  ## ``@[1, 1, 1, 1]``; ``"1.0.2za"`` -> ``@[1, 0, 2, 677]``.
  ##
  ## A second failure mode (CR1-3, module doc comment above): any digit
  ## run longer than 18 characters makes the WHOLE string unparseable
  ## (`none`), never raised as an `OverflowDefect` and never silently
  ## saturated to some sentinel value. A third, symmetric failure mode
  ## (CR1-3 follow-up): any alphabetic run longer than 13 characters gets
  ## identical treatment, for the same int64-accumulation reason — see
  ## the module doc comment above for the worked bound.
  const maxDigits = 18
  const maxAlphaChars = 13
  var runs: seq[int] = @[]
  var i = 0
  let n = v.len
  var overflowed = false
  while i < n:
    if isAsciiDigit(v[i]):
      var j = i
      var val = 0
      var digitCount = 0
      while j < n and isAsciiDigit(v[j]):
        if digitCount < maxDigits:
          val = val * 10 + (ord(v[j]) - ord('0'))
        else:
          overflowed = true
        inc digitCount
        inc j
      runs.add val
      i = j
    elif isAsciiAlpha(v[i]):
      var j = i
      var val = 0
      var alphaCount = 0
      while j < n and isAsciiAlpha(v[j]):
        if alphaCount < maxAlphaChars:
          val = val * 26 + (ord(toLowerAsciiChar(v[j])) - ord('a') + 1)
        else:
          overflowed = true
        inc alphaCount
        inc j
      runs.add val
      i = j
    else:
      inc i
  if overflowed or runs.len == 0: none(seq[int]) else: some(runs)

func abiTag*(): string =
  ## Best-effort OS + data-model tag (RFC-0001 §B.3's round-2 addition —
  ## "a manifest is valid for exactly one ABI class"): `hostOS` (a Nim
  ## compile-time constant) plus the data model computed from
  ## `sizeof(clong)`/`sizeof(pointer)` — `lp64` (long=8, ptr=8; Linux/macOS
  ## 64-bit), `llp64` (long=4, ptr=8; 64-bit Windows), `ilp32` (long=4,
  ## ptr=4; any 32-bit target). Nim's `clong` is defined to match the
  ## TARGET C compiler's `long` width for the current platform
  ## (`system/ctypes.nim`), not a fixed Nim integer size, so this reflects
  ## the real ABI code compiled against this call runs under — true both
  ## when `tools/harvest/harvester.nim`'s probe compiles call it (the
  ## producer side) and when a `dynlib`/`verifyProcs` macro evaluates it at
  ## compile time via `const`/`static` (the consumer side, slice B6a) — one
  ## definition, shared by both, so they cannot drift apart independently
  ## (the same rationale the RFC gives for pinning the B0 types here).
  let model =
    if sizeof(clong) == 8 and sizeof(pointer) == 8: "lp64"
    elif sizeof(clong) == 4 and sizeof(pointer) == 8: "llp64"
    elif sizeof(clong) == 4 and sizeof(pointer) == 4: "ilp32"
    else: "unknown-datamodel"
      # An exotic/16-bit target: never crash over an unrecognized data
      # model, just record that the tag couldn't be computed — a human
      # authoring a manifest for such a target can still hand-edit this
      # one field.
  hostOS & "-" & model

func cmpVersion*(a, b: string): int =
  ## Three-way comparison of two version strings under the B0 total
  ## order: negative if `a` sorts before `b`, zero if equal, positive if
  ## `a` sorts after `b` — the same contract as `system.cmp`. A missing
  ## trailing component compares as `0` (`"1.2"` == `"1.2.0"`).
  ##
  ## A version string with no runs (see `parseVersion`) compares as the
  ## empty sequence: less than any version with a positive leading
  ## component, and equal to any other unparseable string. Callers that
  ## must distinguish "genuinely small version" from "failed to parse"
  ## should call `parseVersion` directly rather than relying on this
  ## fallback.
  let ra = parseVersion(a)
  let rb = parseVersion(b)
  cmpRuns(if ra.isSome: ra.get else: @[], if rb.isSome: rb.get else: @[])

func contains*(iv: VersionInterval, v: string): bool =
  ## Half-open interval membership (RFC-0001 §B.3/§B.4): `lo` inclusive,
  ## `hi` exclusive, either bound `""` meaning unbounded in that direction.
  ## Compared via `cmpVersion`, never raw string comparison — see the
  ## module doc comment's "4.9.0" < "4.10.0" property this must not
  ## silently violate. The single exported predicate slice B6a's manifest
  ## validation (`softlink/manifest`) needs consumer-side; the harvester's
  ## own `versionInSupportRange` (`tools/harvest/harvester.nim`) is the
  ## producer-side twin with identical semantics — kept as two call sites
  ## of the SAME rule rather than two independent implementations.
  (iv.lo.len == 0 or cmpVersion(v, iv.lo) >= 0) and
  (iv.hi.len == 0 or cmpVersion(v, iv.hi) < 0)

func numericPrefixRuns(v: string): tuple[runs: seq[int], hasAlpha: bool] =
  ## Internal primitive for `compareToBound` only (not exported): `v`'s
  ## LEADING contiguous run of digit-groups, stopping at the first
  ## alphabetic character — never folding an alpha run in as a trailing
  ## component the way `parseVersion` does. `hasAlpha` is true iff the scan
  ## stopped on a letter (equivalently: `v` contains a letter ANYWHERE,
  ## since a letter later in `v` would have stopped this same left-to-right
  ## scan) — "does `v` carry an alpha tail after its numeric prefix".
  ## Examples: `"4.16.3-ubuntu3"` -> `(@[4, 16, 3], true)` (the `ubuntu3`
  ## tail is never inspected — only that a letter follows matters);
  ## `"4.16.0"` -> `(@[4, 16, 0], false)`; `"rc1"` -> `(@[], true)` (no
  ## leading numeric run at all).
  ##
  ## Same CR1-3 hardening as `parseVersion`: a digit run longer than 18
  ## characters makes the run unusable, and — since this scan never folds
  ## an alpha run in, unlike `parseVersion` — there is no lesser-of-two-
  ## evils "keep the parseable prefix" option that wouldn't invent meaning
  ## for a truncated/garbage numeric run, so the whole result collapses to
  ## `(@[], hasAlpha)`: empty `runs` lands on `compareToBound`'s existing
  ## "no leading numeric run at all" -> `none` decline path, exactly like
  ## a wholly non-numeric string.
  const maxDigits = 18
  var runs: seq[int] = @[]
  var i = 0
  let n = v.len
  var hasAlpha = false
  var overflowed = false
  while i < n:
    if isAsciiDigit(v[i]):
      var j = i
      var val = 0
      var digitCount = 0
      while j < n and isAsciiDigit(v[j]):
        if digitCount < maxDigits:
          val = val * 10 + (ord(v[j]) - ord('0'))
        else:
          overflowed = true
        inc digitCount
        inc j
      runs.add val
      i = j
    elif isAsciiAlpha(v[i]):
      hasAlpha = true
      break
    else:
      inc i
  if overflowed: (newSeq[int](0), hasAlpha) else: (runs, hasAlpha)

func compareToBound*(probe, bound: string): Option[int] =
  ## RFC-0002 §4.4's declared-bound comparison rule — the runtime
  ## `{.since/until.}` refusal check's comparator, deliberately DIFFERENT
  ## from `cmpVersion`: it compares only `probe`'s and `bound`'s LEADING
  ## NUMERIC-RUN prefixes, never an alphabetic tail. `cmpVersion` encodes
  ## every letter run — wherever it appears — as a positive trailing
  ## component (module doc comment above), which inverts semver
  ## pre-release ordering (`"4.16.0-rc1"` sorts ABOVE `"4.16.0"` under
  ## `cmpVersion`) — exactly backwards for deciding whether a pre-release
  ## or distro-suffixed probe string has crossed a declared bound.
  ##
  ## Returns the ordinary three-way `cmpVersion`-style result (negative:
  ## `probe`'s numeric prefix sorts below `bound`'s; zero: the numeric
  ## prefixes are IDENTICAL and NEITHER side carries an alpha tail;
  ## positive: `probe`'s numeric prefix sorts above `bound`'s) wrapped in
  ## `some` — UNLESS the decision is not safe to make, in which case this
  ## returns `none` (report-don't-block; both cases are "not comparable"
  ## per §4.4):
  ## - either string has NO leading numeric run at all (wholly
  ##   unparseable as a numeric-prefixed version, e.g. `""` or a bare
  ##   alpha tag);
  ## - the numeric prefixes tie AND at least one side carries an alpha
  ##   tail (a genuine pre-release-style ambiguity — `"4.16.0-rc1"` vs
  ##   bound `"4.16.0"`: is a release candidate "before" or "at" its own
  ##   release? Undecidable under this codebase's no-pre-release-semantics
  ##   stance, RFC-0001 §5 C.0).
  ##
  ## A numeric prefix that DECIDES (differs from the bound's) is decisive
  ## regardless of either side's alpha tail — this is what keeps the
  ## flagship distro-suffix case protected: `compareToBound("4.16.3-ubuntu3",
  ## "4.16.0")` returns `some(positive)` (`3 > 0` at the third component)
  ## even though the probe carries a trailing alpha run.
  let (probeRuns, probeAlpha) = numericPrefixRuns(probe)
  let (boundRuns, boundAlpha) = numericPrefixRuns(bound)
  if probeRuns.len == 0 or boundRuns.len == 0:
    return none(int)
  let c = cmpRuns(probeRuns, boundRuns)
  if c == 0 and (probeAlpha or boundAlpha):
    return none(int)
  some(c)

func evaluateBoundRefusal*(probed, sinceVersion, untilVersion: string):
    tuple[refuse, notComparable: bool] =
  ## The single decision function for RFC-0002 §4.4's declared-bound
  ## runtime refusal (code-review finding CR1-4) — extracted from the
  ## `dynlib` macro's `buildBoundCheck` (`src/softlink.nim`), which used to
  ## hand-assemble this exact logic as `NimNode` trees with nothing
  ## unit-testing the decision directly. This is now the ONE place that
  ## decision lives; the macro merely sequences a call to it.
  ##
  ## `sinceVersion`/`untilVersion` follow the same `""` == "absent bound"
  ## convention as `VersionInterval`; either, both, or neither may be
  ## empty. Each declared bound present is checked independently against
  ## `probed` via `compareToBound` (never raw `cmpVersion` — see that
  ## proc's own doc comment on why: alpha-suffix/pre-release ordering
  ## would invert the flagship distro-suffix case):
  ##
  ## - `until` (exclusive upper bound): refuses when `probed` is AT or
  ##   ABOVE `until` (`compareToBound(probed, untilVersion)` is `some` and
  ##   `>= 0`) — the half-open `[since, until)` window's upper edge, so a
  ##   probe exactly AT `until` refuses.
  ## - `since` (inclusive lower bound): refuses when `probed` is BELOW
  ##   `since` (`compareToBound(probed, sinceVersion)` is `some` and
  ##   `< 0`) — so a probe exactly AT `since` is accepted, never refused.
  ## - either comparison coming back `none` (an unparseable probe, an
  ##   oversized/overflow-guarded run per CR1-3, or a genuine boundary tie
  ##   with an alpha tail) never refuses on its own; it sets
  ##   `notComparable` instead (report-don't-block) — independent per
  ##   bound, so one bound's ambiguous result never suppresses the OTHER
  ##   bound's decisive refusal. `refuse` and `notComparable` are
  ##   therefore not mutually exclusive: an until-decisive-refuse can
  ##   coexist with a since-side `none`.
  ##
  ## Both bounds get identical rigor (§4.4's "both bounds, same check"
  ## symmetry) and both start `false`/`false` when both bounds are `""`
  ## (an unbounded proc never refuses, regardless of `probed`).
  result = (refuse: false, notComparable: false)
  if untilVersion.len > 0:
    let cmpUntil = compareToBound(probed, untilVersion)
    if cmpUntil.isSome:
      if cmpUntil.get >= 0:
        result.refuse = true
    else:
      result.notComparable = true
  if sinceVersion.len > 0:
    let cmpSince = compareToBound(probed, sinceVersion)
    if cmpSince.isSome:
      if cmpSince.get < 0:
        result.refuse = true
    else:
      result.notComparable = true

func isCorpusTrackable*(noVerify: bool, hasHeader: bool): bool =
  ## The shared "does this proc have per-version corpus facts worth
  ## recording/checking" predicate (code-review finding #21). A symbol is
  ## corpus-trackable iff it is not `{.noverify.}` (nothing to probe — the
  ## symbol isn't even header-verified) AND it declares a real `{.header.}`
  ## (a `{.prototype.}`-only symbol verifies against a vendored, corpus-
  ## INVARIANT declaration that never varies by installed headers, so it has
  ## no per-version facts to harvest or compare).
  ##
  ## Two independent call sites used to hand-roll this same three-line
  ## condition with nothing forcing them to agree: the manifest-consumption
  ## side (`softlink/directives.applyCompatManifest`'s `trackable` list, bound
  ## against `SoftlinkProc.noVerify`/`.headerFile`) and the manifest-production
  ## side (`tools/harvest/harvester.harvest`'s per-proc classification, bound
  ## against `ProbeFact.noverify`/`.header`) — two distinct record types with
  ## different field names/casing, which is why this takes plain `bool`s
  ## rather than either struct. Pinned here, in the one leaf module both
  ## sides already import (directly, or — pre-R3-3 — transitively via
  ## `softlink/manifest`'s `export versions`), so the predicate cannot drift
  ## apart independently ever again.
  not noVerify and hasHeader

const softlinkVersion* = "0.12.2"
  ## RFC-0003 SS2/SS7 slice C1: the CORE `softlink` package's own
  ## version-of-record -- `HarvestMeta.harvesterVersion`'s (tools/harvest/
  ## harvester.nim) source of truth, stamping which softlink release
  ## performed a given harvest. Hand-bumped in lockstep with
  ## softlink.nimble's own `version` field; `softlink.nimble`'s `task test`
  ## runs a nimble-layer check (`checkVersionOfRecordPin`) comparing this
  ## constant against nimble's own `version` global so the two can never
  ## silently drift apart.
  ##
  ## Deliberately NOT the harvest CLI's own `NimblePkgVersion`:
  ## `tools/harvest/softlink_harvest.nimble` is versioned independently
  ## (0.1.x, `requires softlink >= 0.7.0` -- a floor, not a pin), so
  ## `NimblePkgVersion` there would stamp the harvest CLI package's own
  ## release lineage, not the core package's -- the wrong provenance for a
  ## field whose whole point is "which softlink fixed Gap A/Gap B".
  ##
  ## Lives here, in `softlink/versions`, rather than a new module: this is
  ## the one core-package module BOTH `tools/harvest/harvester.nim`
  ## (`import softlink/versions`) and `softlink.nimble` itself
  ## (`import "src/softlink/versions"`, this repo's nimble file header)
  ## already import -- so the version-of-record const reaches both the
  ## harvester and the nimble-layer pin check with no new import anywhere.
