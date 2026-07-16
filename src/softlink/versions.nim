## `softlink/versions` — version-string comparison and the pinned
## interval/fact types shared by softlink's `dynlib` macro and the
## `softlink harvest` CLI (RFC-0001 slice B0).
##
## A version string is parsed into the sequence of its **digit runs** and
## **alphabetic runs**, read left to right: a maximal run of ASCII digits
## becomes its integer value; a maximal run of ASCII letters (case-folded)
## becomes its **bijective base-26** ordinal — the same scheme spreadsheet
## column names use: ``a``=1 … ``z``=26, ``aa``=27, ``za``=677. Every other
## character (``.``, ``-``, ``+``, a bare ``p`` used as a separator, …) is
## pure run separator and contributes nothing to the sequence.
##
## Comparison is lexicographic over the resulting integer sequences, with a
## missing trailing component treated as ``0`` — so ``"1.2"`` and
## ``"1.2.0"`` compare equal. There is no pre-release semantics: the corpus
## this comparator targets is release tags, and one consistent versioning
## scheme per library is assumed (RFC-0001 §5 C.0). Cross-scheme version
## strings can collide under this ordering; that is documented, not
## defended against.
##
## A version string with **no runs at all** (e.g. ``""``, ``"..."``,
## ``"-"``) fails to parse. Parse failure is surfaced as a plain
## `Option[seq[int]]` — never an exception — so Stage C's load-time
## probing can classify an unparseable runtime version as "unattested"
## without wrapping every comparison in `try/except`.

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
  var runs: seq[int] = @[]
  var i = 0
  let n = v.len
  while i < n:
    if isAsciiDigit(v[i]):
      var j = i
      var val = 0
      while j < n and isAsciiDigit(v[j]):
        val = val * 10 + (ord(v[j]) - ord('0'))
        inc j
      runs.add val
      i = j
    elif isAsciiAlpha(v[i]):
      var j = i
      var val = 0
      while j < n and isAsciiAlpha(v[j]):
        val = val * 26 + (ord(toLowerAsciiChar(v[j])) - ord('a') + 1)
        inc j
      runs.add val
      i = j
    else:
      inc i
  if runs.len == 0: none(seq[int]) else: some(runs)

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
