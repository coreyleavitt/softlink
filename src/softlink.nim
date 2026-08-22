## softlink — Type-safe optional dynamic library bindings for Nim.
##
## Provides a `dynlib` macro that generates runtime-loadable FFI bindings
## from type-safe proc definitions, a `dyntype` macro for compile-time struct
## layout verification against C headers, and a `verifyProcs` macro that emits
## the same proc-signature verification standalone (for statically-linked
## `{.importc.}` bindings that want softlink's `_Static_assert` checking
## without runtime loading). Solves the Nim ecosystem gap between
## `{.importc, dynlib.}` (type-safe but fatal on missing) and `std/dynlib`
## (optional but loses type safety).

when defined(js):
  {.error: "softlink requires a native backend (C, C++, or Objective-C). The JavaScript backend does not support dynamic library loading.".}

import std/[macros, sets, strutils, os, json]
import std/dynlib as stdDynlib
import ./softlink/manifest
import ./softlink/versions
# RFC-0001 code-review finding #13: the three extraction seams (a compile-
# time-only prototype tokenizer/analyzer, per-proc pragma parsing +
# body-directive/manifest handling, and header-verification codegen) plus
# the shared `SoftlinkProc` descriptor they and the macros below all pass
# around — see each module's own header comment for what moved from here
# and why the seam is clean (no closure over any `dynlib`/`verifyProcs`
# macro local). `softlink/prototype` (the tokenizer/analyzer itself) is not
# imported directly here — only `softlink/pragmas`' `parseProcPragmas`
# calls into it (via `parsePrototypePragma`/`nonBuiltinIdentifiers`); this
# file only ever goes through that one entry point.
import ./softlink/procinfo
import ./softlink/pragmas
import ./softlink/directives
import ./softlink/verify
import ./softlink/loader
import ./softlink/fatal
# RFC 0011 S0b, work item (i): `softlinkFatal` (`softlink/fatal`) is the
# trusted-wrapper mode's nil-branch diagnostic/termination proc — exported
# here the SAME way `loader.loadLibPatternDetailed`/the `stdDynlib` re-exports
# above are: a `trustedWrappers` block's generated wrapper code lives in the
# CONSUMING module, which resolves `softlinkFatal` unqualified via `import
# softlink` alone, with no separate `import softlink/fatal` of its own
# required.
export fatal.softlinkFatal
# Exported because macro-generated code resolves these identifiers at the call site.
export stdDynlib.LibHandle, stdDynlib.loadLibPattern, stdDynlib.symAddr,
       stdDynlib.unloadLib
# RFC 0011 S0a item 5: `loadX`'s generated body now calls
# `loader.loadLibPatternDetailed` instead of `stdDynlib.loadLibPattern`
# directly (see the `dynlib` macro's loadBody codegen below) — exported for
# the SAME reason as the `stdDynlib` re-exports above (macro-generated code
# living in the consuming module resolves it unqualified). `loadLibPattern`
# itself stays exported too: it's still part of softlink's public surface
# for callers who want the plain stdlib behavior directly, even though
# `dynlib`'s own codegen no longer calls it.
export loader.CandidateAttempt, loader.loadLibPatternDetailed
# NOTE: `compatManifest`/`versionProbe` (the RFC-0001 §B.5/§9 "erroring
# stub" proc/template) stay declared directly below in THIS file, rather
# than moving to `softlink/pragmas` with the rest of the directive-parsing
# machinery — see the comment at their declaration for why (a re-export
# quirk with bodyless `{.error.}`-pragma'd symbols). No `export` line is
# needed for them here as a result: their own `*` already makes them
# public, exactly as before this extraction.
# RFC-0001 §B.5/§9, slice B6b: the pinned B0 types (`softlink/versions`) that
# `softlinkCompatFacts<Base>: seq[SymbolFacts]` is typed with. Exported for
# the SAME reason as the `stdDynlib` re-exports above — the const is
# macro-generated code living in the CONSUMING module, which resolves
# `SymbolFacts`/`VersionInterval`/`FactKind` unqualified via `import softlink`
# alone, with no separate `import softlink/versions` of its own required.
export versions.SymbolFacts, versions.VersionInterval, versions.FactKind

type
  SoftlinkError* = ref object of CatchableError
    ## Raised when calling a function from a library that hasn't been loaded.
    symbol*: string
    library*: string  ## The raw dynlib pattern string (e.g., ``"libm.so(.6|)"``)

  LoadResultKind* = enum
    lrOk             ## All symbols resolved (required + optional)
    lrOkPartial      ## All required resolved, some optional missing
    lrLibNotFound    ## Library .so not found on system
    lrSymbolNotFound ## Required symbol missing, library unloaded

  LoadResult* = object
    case kind*: LoadResultKind
    of lrOkPartial:
      missing*: seq[string]
    of lrSymbolNotFound:
      symbol*: string
    of lrLibNotFound:
      attempts*: seq[loader.CandidateAttempt]
        ## RFC 0011 S0a item 5: every concrete (post pattern-expansion)
        ## candidate the loader tried, and the OS loader's own diagnostic
        ## for each — see `softlink/loader.loadLibPatternDetailed`, which
        ## replaces the plain `loadLibPattern` call this branch used to be
        ## built from. Empty only in the (currently unreachable) case that
        ## `pattern` itself expands to zero candidates. Use `osLoaderDetail`
        ## below for a one-line rendering.
    of lrOk:
      discard

proc osLoaderDetail*(r: LoadResult): string =
  ## RFC 0011 S0a item 5: a one-line-simple rendering of `r.attempts`, for
  ## consumers (e.g. oyamel's planned `GtkApiError.osLoaderDetail`) that
  ## just want a human-readable string, not the structured `seq` — pins the
  ## RENDERED FORM's content (candidate names + error text present), not
  ## exact formatting; format freely in future revisions.
  ##
  ## `""` for every `LoadResultKind` other than `lrLibNotFound` (including
  ## the empty-attempts case, which cannot occur through the generated
  ## `loadX` path today but is handled defensively rather than indexing
  ## into an empty seq).
  if r.kind != lrLibNotFound or r.attempts.len == 0:
    return ""
  var parts = newSeq[string](r.attempts.len)
  for i, a in r.attempts:
    parts[i] = a.candidate & ": " & a.osError
  parts.join("; ")

type
  Attestation* = enum
    ## RFC-0001 §C.2, slice C2 (finding #11 split C2 into six): `CompatReport
    ## .attestation` — six diagnostically distinct "how much do we trust this
    ## runtime" states, kept apart so a caller never has to infer "no
    ## information" from the absence of some other field (`atUnattested`
    ## collapsing `atNoManifest` and "probed but not in corpus" was the
    ## round-2 mistake the RFC itself calls out; `atNoProbe` collapsing "no
    ## probe, ever" with "probe declared, hasn't run yet" was finding #11's
    ## own instance of the same mistake).
    atNoProbe      ## PERMANENT, structural: this block declares no
                   ## `versionProbe` at all. True for the lifetime of the
                   ## block; never transitions to any other value. The zero
                   ## value, by construction the default for a freshly
                   ## zero-initialized `CompatReport` in a probe-less block.
    atProbeNotRun  ## TRANSIENT: this block DOES declare a `versionProbe`,
                   ## but it has not (yet) run — before the block's first
                   ## `loadX` call, after `unloadX()`, or after a load that
                   ## failed in Phase 1/Phase 2 (before Phase 3/the probe
                   ## ever executed). A later successful-enough load
                   ## replaces this with `atProbeFailed`/`atNoManifest`/
                   ## `atOutOfCorpus`/`atAttested`, whichever applies.
    atProbeFailed  ## probe ran and raised, or returned an unparseable string
    atNoManifest   ## probe ok, but no compatManifest attached to check against
    atOutOfCorpus  ## probed version outside the manifest's harvested corpus
    atAttested     ## probed version inside the manifest's harvested corpus

  MissingReason* = enum
    ## RFC-0001 §C.2: why one `CompatReport.missingReasons` symbol didn't
    ## resolve. The type is defined now (public surface); the partition that
    ## populates `missingReasons` is later slices — C3 (`mrExpected`/
    ## `mrAnomalous`) and C4b/C4c (`mrDriftRefused`). Slice C2 itself never
    ## adds an entry.
    mrExpected      ## manifest/since: this runtime predates the symbol
    mrAnomalous     ## this version's headers declare it, yet it did not resolve
    mrDriftRefused  ## resolved, but refused for known signature drift (§C.3)

  MissingReasonEntry* = tuple[symbol: string, reason: MissingReason,
                              interval: VersionInterval]
    ## Code-review finding CR1-7: `CompatReport.missingReasons`'s element
    ## type, named once so the 4 codegen sites in the `dynlib` macro
    ## (`bindSym("MissingReasonEntry")` call sites building the var
    ## holding this shape at macro-expansion time) reference ONE
    ## declaration instead of each re-deriving the same anonymous tuple
    ## structurally.
    ## Since Nim tuples are structural, this is purely a name for the
    ## existing shape — no behavior change, and any caller code written
    ## against the old anonymous tuple keeps compiling unchanged.

  CompatReport* = object
    ## RFC-0001 §C.2: a query proc (`fooCompat*(): CompatReport`) generated
    ## per `dynlib` block — deliberately NOT fields on `LoadResult` (dead
    ## weight on every non-attestation-relevant failure kind). Written on
    ## EVERY `loadX` return path (including the Phase-1 early returns, which
    ## do not write the cached `LoadResult`); `unloadX` resets it to this
    ## block's OWN zero state (finding #11: `atProbeNotRun` if this block
    ## declares a `versionProbe`, `atNoProbe` if it doesn't — never `""`/
    ## `@[]` fields on their own, always alongside `runtimeVersion: ""` and
    ## `missingReasons: @[]`) alongside its other pointer/cache resets —
    ## `fooCompat()` after `unloadFoo()` must never serve a previous load's
    ## trust signals. `verifyProcs` generates no `fooCompat` at all (no
    ## runtime footprint, consistent with its `versionProbe` rejection).
    ##
    ## `missingReasons` (finding #12; was `missing` through slice C2 —
    ## renamed to stop colliding, in name only, with the differently-typed
    ## `LoadResult.missing: seq[string]` a caller frequently holds
    ## alongside this report) partitions *why* each symbol in
    ## `LoadResult.missing` didn't resolve — see `MissingReason` above.
    runtimeVersion*: string   ## "" unless the probe succeeded
    attestation*: Attestation
    missingReasons*: seq[MissingReasonEntry]
      ## RFC-0002 §4.9/§6, slice C2: the evidence interval behind `reason`.
      ## Sourced per §4.9's evidence-interval rule, which varies by WHICH
      ## code path produced the entry, not by `reason`'s own value: on the
      ## attested-mismatch path (both drift-refusal loops below, required
      ## and optional — `mrDriftRefused` entries only), it is the
      ## manifest's own `firstMismatchInterval` for that symbol at the
      ## probed version — already computed there to build the drift
      ## story's text, strictly more precise than the author's `since`/
      ## `until` claim. Everywhere else — `computeMissingPartition`'s
      ## `mrExpected`/`mrAnomalous` entries, C1's classification path —
      ## it is the proc's own DECLARED `[since, until)`
      ## (`VersionInterval(lo: since, hi: until)`), `""` legs rendering as
      ## open/unbounded (`formatInterval`'s "any version" fallback) when
      ## the proc carries neither bound.
    probeNotComparable*: bool
      ## RFC-0002 §4.4/§4.9, slice C4a/C4b: `false` unless the
      ## declared-bound refusal check (`versions.evaluateBoundRefusal`)
      ## hits a genuine boundary tie (numeric prefixes equal, an alpha
      ## run on either side) or an unparseable probe string when
      ## comparing a probed version against a `{.since/until.}` bound —
      ## in that case the check declines to refuse and sets this `true`
      ## instead (report-don't-block for that one ambiguous case). Set by
      ## `declaredBoundRefusalStmts`, which is shared by three emission
      ## sites: `atNoManifest` and `atOutOfCorpus` (search
      ## `assignCompatReportStmt`), plus the `atAttested` path for
      ## manifest-absent bounded procs. `atProbeFailed` is NOT reused for
      ## this: it already means "the probe raised, or returned no string
      ## at all" — a different failure than "the probe returned a string
      ## that couldn't be compared against a bound".

# Exported because macro-generated wrapper procs call this by ident at the call site.
proc raiseNotLoaded*(library, symbol: string) {.noreturn, noinline.} =
  raise SoftlinkError(
    msg: library & ": library not loaded, cannot call: " & symbol,
    library: library, symbol: symbol)

# RFC-0001 §C.3, slice C4b: raised by a wrapper INSTEAD OF `raiseNotLoaded`
# above when its symbol resolved at load time but was then re-nilled for
# known signature drift (`findDriftStory` below found a stored story) —
# `story` IS the message (the full "<symbol>: signature drift at
# <interval> per compat manifest; refusing unsafe dispatch" text, built
# once at refusal time in loadXxx and stashed in
# `softlinkDriftStories<Base>`). Exported and called via a plain ident
# from generated code, exactly like `raiseNotLoaded`.
proc raiseDriftRefused*(library, symbol, story: string) {.noreturn, noinline.} =
  raise SoftlinkError(msg: story, library: library, symbol: symbol)

proc findDriftStory(stories: seq[tuple[symbol: string, story: string]],
                     symbol: string): string =
  ## RFC-0001 §C.3, slice C4b design guidance: a linear scan of one
  ## block's `softlinkDriftStories<Base>` for `symbol` — error-path only (a
  ## wrapper already found its function pointer nil), so cost is
  ## irrelevant. `""` means "no stored story for this symbol" (either it
  ## was never refused, or refusal never happens in this block at all) —
  ## the wrapper's generated call site falls back to the ordinary
  ## `raiseNotLoaded` message on a miss, unchanged. Not exported (like
  ## `computeMissingPartition` below): generated code resolves it via
  ## `bindSym`, forcing THIS module's definition regardless of what else
  ## is in scope at the call site.
  for entry in stories:
    if entry.symbol == symbol: return entry.story
  ""

proc computeMissingPartition(symbols: seq[SymbolFacts], missingSymbols: seq[string],
                              sinceCNames, sinceVersions, untilVersions: seq[string],
                              probedVersion: string): seq[MissingReasonEntry] =
  ## RFC-0001 §9/§C.2, slice C3: the runtime bridge between the pure
  ## `softlink/manifest.classifyAbsence` (facts + version + since ->
  ## `AbsenceClass`) and `CompatReport.missingReasons`'s `MissingReason`. Called
  ## once per successful, manifest-attested `loadX` (bound via `bindSym`
  ## from generated code, like `parseVersion`/`isSome` above it — no
  ## export needed, `bindSym` resolves in THIS module's own scope) — only
  ## when the block has both a `compatManifest` and at least one optional
  ## proc (nothing to partition otherwise). `missingSymbols` is the exact
  ## `softlinkMissing` seq the load pipeline already built (Phase 2);
  ## `sinceCNames`/`sinceVersions` are macro-time-computed PARALLEL arrays
  ## rather than a `seq` of pairs, purely so the macro can embed them with
  ## the same plain `newLit(seq[string])` shape already proven elsewhere in
  ## this file (`corpusLit`), with no new exported aggregate type for
  ## generated code to reference by name.
  ##
  ## RFC-0002 §4.9, slice C4a: the caller now passes the ONE canonical
  ## bounds embedding (`boundCNames`/`boundSinceVersions` — EVERY proc in
  ## the block carrying a `since` and/or `until` claim, required or
  ## optional, not just this proc's original "optional procs' own
  ## `{.since.}` claims" subset). Behavior here is unchanged regardless:
  ## required symbols never appear in `missingSymbols` on a successful load
  ## (Phase 1 fails the whole load first), so their now-included rows are
  ## never matched by the lookup below; an until-only row's `since` is `""`,
  ## identical to "not found" for this function's purposes.
  ##
  ## RFC-0002 §4.3, slice C1: `untilVersions` is the same-shaped, same-
  ## indexed third parallel array (row `i` is `boundCNames[i]`'s declared
  ## `until`, `""` if it carries none) — threaded straight through to
  ## `classifyAbsence`'s own new `untilVersion` parameter, no local
  ## decision logic added here.
  ##
  ## RFC-0002 §4.9, slice C2: every entry's `interval` is the proc's own
  ## DECLARED `[since, until)` — `since`/`until` are already looked up
  ## per-symbol just below for `classifyAbsence` itself, so this is a
  ## free byproduct, not a second lookup. This is the "declared interval
  ## elsewhere" leg of §4.9's evidence-interval rule — the OTHER leg (the
  ## manifest's own `firstMismatchInterval`, for attested-mismatch
  ## `mrDriftRefused` entries) never reaches this function at all; those
  ## entries are built directly in the `dynlib` macro's drift-refusal
  ## loops, which already hold the matched `firstMismatchInterval` result.
  for sym in missingSymbols:
    var since = ""
    var until = ""
    for i in 0 ..< sinceCNames.len:
      if sinceCNames[i] == sym:
        since = sinceVersions[i]
        until = untilVersions[i]
        break
    let iv = VersionInterval(lo: since, hi: until)
    case classifyAbsence(symbols, sym, probedVersion, since, until)
    of acExpected: result.add (symbol: sym, reason: mrExpected, interval: iv)
    of acAnomalous: result.add (symbol: sym, reason: mrAnomalous, interval: iv)
    of acNone: discard

# `toIncludeDirective`/`emitPrototypeDecl` moved to `softlink/verify` (code-
# review finding #13's "genVerifyBlock + verification tiers" seam) —
# `toIncludeDirective` is exported from there (`dyntype` below still calls
# it); `emitPrototypeDecl` is used only inside `genVerifyBlock` itself and
# stays private to that module.

func leadingAlternationStem(pattern: string): tuple[found: bool, stem, rest: string] =
  ## RFC 0011 S0a item 2: if `pattern` opens with a parenthesized
  ## alternation — `"(alt1|alt2|...)"` — whose alternatives all reduce to
  ## the SAME stem after stripping an optional literal "lib" prefix from
  ## each, returns that common stem plus the remainder of `pattern`
  ## following the closing paren. This is the general form of the fix
  ## below: `"(lib|)"` (bare optional-lib prefix — both alternatives reduce
  ## to "") and `deriveLibPattern`'s own Windows output
  ## `"(lib" & stem & "|" & stem & ")"` (both alternatives reduce to
  ## `stem`) are the SAME shape with a different common stem — one rule
  ## handles both, rather than special-casing the empty-stem spelling as a
  ## distinct case from the non-empty one. Alternatives that reduce to
  ## DIFFERENT stems (no principled pick) or a pattern with no leading
  ## group at all leave `found = false`; the caller then falls back to
  ## treating `pattern` unchanged, exactly as before this fix existed.
  if pattern.len == 0 or pattern[0] != '(':
    return (false, "", pattern)
  let closeIdx = pattern.find(')')
  if closeIdx < 0:
    return (false, "", pattern)
  let alts = pattern[1 ..< closeIdx].split('|')
  if alts.len < 2:
    return (false, "", pattern)
  var stem = alts[0]
  if stem.startsWith("lib"): stem = stem[3 .. ^1]
  for i in 1 ..< alts.len:
    var alt = alts[i]
    if alt.startsWith("lib"): alt = alt[3 .. ^1]
    if alt != stem:
      return (false, "", pattern)
  (true, stem, pattern[closeIdx + 1 .. ^1])

func libNameToIdent(libPattern: string): string =
  ## Derive an identifier base name from a library pattern string.
  ## Normalizes a leading optional-`lib` alternation (`"(lib|)stem..."`,
  ## `"(libstem|stem)..."` — see `leadingAlternationStem` above, RFC 0011
  ## S0a item 2) the same as a literal "lib" prefix, truncates at the first
  ## dot, removes non-alphanumeric characters (underscores, hyphens, etc.),
  ## and capitalizes.
  ## Examples: "libmbedtls.so(.16|)" → "Mbedtls", "libfoo_bar.so" → "Foobar",
  ## "(lib|)glib-2.0-0.dll" → "Glib2" (same as "libglib-2.0.so(|.0)").
  var name = libPattern
  let alt = leadingAlternationStem(name)
  if alt.found: name = alt.stem & alt.rest
  if name.startsWith("lib"): name = name[3 .. ^1]
  let dotIdx = name.find('.')
  if dotIdx >= 0: name = name[0 ..< dotIdx]
  # Remove non-alnum chars
  var clean = ""
  for c in name:
    if c.isAlphaNumeric: clean.add(c)
  if clean.len > 0:
    clean[0] = clean[0].toUpperAscii()
  clean

type
  LibOs* = enum
    ## Target operating system for library-name derivation. Passed explicitly
    ## (rather than read from `defined()`) so `deriveLibPattern` stays a pure,
    ## per-OS-testable function.
    osLinux, osMacos, osWindows

func deriveLibPattern*(name: string, os: LibOs): string =
  ## Derive the `loadLibPattern` candidate string for a bare logical library
  ## `name` on the given `os` — e.g. ``"z3"`` → ``"libz3.so(|.7|…)"`` on Linux.
  ## The rule is simply "list the plausible on-disk names for this OS"; the
  ## loader tries them in order. A leading ``lib`` is stripped first, so ``"z3"``
  ## and ``"libz3"`` derive identically.
  ##
  ## Covers bare (``libz3.so``) and single-component major sonames
  ## (``libz3.so.4``). Multi-component runtime-only sonames (openSUSE
  ## ``libz3.so.4.15`` with no bare/major symlink) are out of scope — pin those
  ## with the explicit-pattern escape hatch instead of a bare logical name.
  var stem = name
  if stem.startsWith("lib"): stem = stem[3 .. ^1]
  case os
  # Bare ``.so`` first (dev installs carry the unversioned symlink); then
  # descending *single-component* major sonames, since a runtime-only install
  # often ships only ``libfoo.so.N`` with no bare symlink (e.g. Debian
  # ``libz3.so.4``). NOTE: multi-component runtime-only sonames — e.g. openSUSE's
  # ``libz3.so.4.15`` with no bare or single-major symlink — are deliberately
  # NOT enumerated here: an unbounded minor sweep can't be future-proof and
  # would bloat the candidate list. Such installs use the explicit-pattern
  # escape hatch (``dynlib "libz3.so(.4.15|.4|)"``) or the OS loader path.
  of osLinux: "lib" & stem & ".so(|.7|.6|.5|.4|.3|.2|.1)"
  # macOS mirrors Linux: bare ``.dylib`` first, then descending majors
  # (``libz3.4.dylib``), for runtime-only installs lacking the bare symlink.
  of osMacos: "lib" & stem & "(|.7|.6|.5|.4|.3|.2|.1).dylib"
  # Windows is the one platform where the ``lib`` prefix isn't universal
  # (Z3 ships ``libz3.dll``; many projects ship ``z3.dll``). Try both.
  of osWindows: "(lib" & stem & "|" & stem & ").dll"

func isLogicalName*(spec: string): bool =
  ## True when `spec` is a bare logical library name (a plain stem like
  ## ``"z3"`` or ``"libz3"``) rather than an explicit `loadLibPattern` string.
  ## Explicit patterns carry an extension, alternation, or path separator;
  ## logical names carry none. `dynlib` derives per-OS candidates for logical
  ## names and passes explicit patterns through verbatim (the escape hatch).
  '.' notin spec and '(' notin spec and '/' notin spec and '\\' notin spec

func currentLibOs(): LibOs =
  ## The compile-time target OS as a `LibOs`, for use at macro-evaluation time.
  when defined(windows): osWindows
  elif defined(macosx): osMacos
  else: osLinux

## RFC-0001 §B.5's "erroring stub" message: exported so a
## `compatManifest(...)` call OUTSIDE a `dynlib`/`verifyProcs` block
## resolves, via ordinary overload resolution, to the `compatManifest`
## proc below — whose `{.error.}` pragma turns the call into a
## softlink-authored diagnostic instead of a bare "undeclared
## identifier" (the #14 lesson, reapplied here: an opaque compiler
## error pointing nowhere useful is worse than a clear one).
## Correctly-placed directives never reach that proc at all — the
## `dynlib`/`verifyProcs` macros recognize and consume the
## `compatManifest` statement structurally (see
## `softlink/directives.isCompatManifestCall`) and never re-emit it into the
## generated code, exactly like every proc declaration in the same body is
## consumed and regenerated rather than passed through verbatim.
##
## Declared directly HERE rather than in `softlink/directives` alongside the
## rest of the directive-recognition machinery (code-review finding #13):
## Nim's qualified re-export syntax (`export someModule.someProc`) does not
## reliably re-export a bodyless `{.error.}`-pragma'd proc/template — see
## `softlink/directives`' own comment at this stub's old location for the
## empirical detail. Keeping both stubs declared where their own `*` already
## makes them public sidesteps the issue and reproduces pre-extraction
## behavior byte-for-byte.
const compatManifestStubMsg =
  "softlink: compatManifest is a body directive of dynlib/verifyProcs " &
  "blocks (RFC-0001 §B.5) — it must appear directly inside a " &
  "`dynlib \"lib\": ...` or `verifyProcs: ...` block (e.g. " &
  "`compatManifest \"lib.compat.json\"`), not called as an ordinary proc."

proc compatManifest*(path: string, refuse: bool = false) {.error: compatManifestStubMsg.}

## RFC-0001 §9/§C.1, slice C1b: the analogous "erroring stub" for
## `versionProbe`, so a misplaced `versionProbe: ...` outside any `dynlib`
## block gets a softlink-authored diagnostic instead of a raw compiler
## error. Unlike `compatManifest` (an ordinary call, `compatManifest("path")`),
## the `versionProbe: <body>` call site uses colon-block syntax, which only
## type-checks against a parameter typed `untyped` — and `untyped`
## parameters are only legal on templates/macros, never plain procs (unlike
## `compatManifest`'s stub above). A `template` carrying the same
## `{.error.}` pragma reproduces the identical "diagnostic fires at the USE
## site, not the definition site" behavior (verified empirically: Nim's
## `{.error.}` on a template behaves exactly like on a proc). Correctly-
## placed directives never reach this template at all — `dynlib` recognizes
## and consumes the `versionProbe` statement structurally (see
## `softlink/directives.isVersionProbeStmt`) before it is ever resolved as an
## identifier; `verifyProcs` does the same, but ALWAYS rejects it with its
## own directive-specific error (no runtime footprint there — see
## `collectVProcs`).
const versionProbeStubMsg =
  "softlink: versionProbe is a body directive of dynlib blocks (RFC-0001 " &
  "§9/§C.1) — it must appear directly inside a `dynlib \"lib\": ...` " &
  "block (e.g. `versionProbe: parseFooVersion($Foo_get_version())`), not " &
  "called outside one."

template versionProbe*(body: untyped) {.error: versionProbeStubMsg.} =
  discard

# `SoftlinkProc` (the shared per-proc descriptor) moved to
# `softlink/procinfo`, and `pragmaKeyName`/`parseVerifyWhenExpr`/
# `parseSinceExpr`/`parseNoVerifyReasonExpr` moved to `softlink/pragmas`
# (code-review finding #13's "pragma parsing" seam) — `pragmaKeyName` is
# exported from there (`dyntype` below still calls it); the other three are
# used only inside `softlink/pragmas`' own `parseProcPragmas` and stay
# private to that module.
#
# The RFC-0001 §3 A.1 prototype tokenizer/analyzer (`PrototypeTokenKind`,
# `PrototypeToken`, `tokenizePrototype`, `PrototypeAnalysis`,
# `analyzePrototype`, `builtinCTypeKeywords`, `nonBuiltinIdentifiers`,
# `parsePrototypePragma`) moved to `softlink/prototype` (code-review
# finding #13's "prototype tokenizer" seam) — a self-contained, pure-
# function group with no dependency on anything else in this file.
#
# `ProcPragmaFacts`/`callingConventions`/`parseProcPragmas` (per-proc
# pragma parsing) moved to `softlink/pragmas` (code-review finding #13's
# "pragma parsing" seam) — every proc there takes its inputs as explicit
# parameters and closes over no `dynlib`/`verifyProcs` macro local.
#
# `CompatManifestDirective`/`isCompatManifestCall`/
# `parseCompatManifestDirective`/`compatManifestDupError`,
# `VersionProbeDirective`/`isVersionProbeStmt`/`parseVersionProbeDirective`/
# `versionProbeDupErrorMsg`, and `AppliedManifest`/`applyCompatManifest`
# moved to `softlink/directives` (code-review finding #13's "pragma parsing
# + directive/manifest application" seam, later split from `softlink/pragmas`
# itself under code-review finding R2-4 — block-level directive AST
# recognition plus I/O-performing manifest-application orchestration is a
# different concern from per-proc pragma parsing) — every proc there takes
# its inputs as explicit parameters and closes over no `dynlib`/
# `verifyProcs` macro local. `ProcPragmaMode` (the `ppmDynlib`/
# `ppmVerifyProcs` enum `parseProcPragmas` and `applyCompatManifest` both
# take) moved to `softlink/procinfo` in the R2-4 pass, so that
# `softlink/pragmas` and `softlink/directives` each import `procinfo` for
# it rather than one importing the other.
# The `compatManifest`/`versionProbe` erroring stubs did NOT move: they
# stay declared above in THIS file (a bodyless `{.error.}` proc/template
# does not survive Nim's qualified re-export — see the stubs' own doc
# comments), so a misplaced directive still resolves through
# `import softlink` alone, exactly as before.
#
# `genVerifyBlock` and its verification-tier helpers (`softlinkProbeOnly`/
# `softlinkProbeExistence` consts, `parseProbeOnlyList`) moved to
# `softlink/verify` (code-review finding #13's "genVerifyBlock +
# verification tiers" seam) — `softlinkNoDriftRefusal` just below stays
# here, since (unlike the other two probe-mode consts) it is read directly
# by the `dynlib` macro's own drift-refusal gate, not by `genVerifyBlock`.

const softlinkNoDriftRefusal {.booldefine.} = false
  ## RFC-0001 §C.3, slice C4c: `-d:softlinkNoDriftRefusal` — the
  ## downstream-consumer-scoped escape hatch ("a vendor rebuilding a
  ## patched library under the same version string the manifest classified
  ## as mismatched"). Disables RUNTIME drift refusal build-wide: every
  ## `dynlib` block in this compile behaves as if EVERY `compatManifest`
  ## directive carried `refuse = false`, regardless of what any individual
  ## block's own directive says (this define wins — see
  ## `driftRefusalEnabled`'s computation in the `dynlib` macro).
  ##
  ## Read at MACRO-EXPANSION time via `{.booldefine.}`, exactly like
  ## `softlinkProbeExistence` immediately above (and `softlinkProbeOnly`,
  ## `softlinkDumpProbes`, `softlinkStrictVerify` elsewhere in this file) —
  ## NOT emitted as a `when defined(...)` into the generated code. `dynlib`
  ## expands as part of the SAME single `nim c -d:...` compiler invocation
  ## that compiles the consuming module (Nim compiles a whole program in
  ## one process), so a build-wide `-d:` flag is exactly as visible to a
  ## `{.booldefine.}` const evaluated during macro expansion as it is
  ## anywhere else — this is proven, not assumed: every one of those
  ## existing consts already relies on the identical mechanism, and their
  ## own tests (this file's `nimble test` task) already pass under
  ## `-d:softlinkStrictVerify`/`-d:softlinkProbeOnly=...` today. Gating at
  ## macro time additionally means refusal codegen is skipped ENTIRELY
  ## under the define — no dead `when` branch, no doubled candidate lists —
  ## the same "cleanest degradation" property `refuse = false` gets per
  ## block (see `driftRefusalEnabled`).

const softlinkDumpProbes {.strdefine.} = ""
  ## RFC-0001 §4 B.1: with `-d:softlinkDumpProbes=<dir>`, every `dynlib`
  ## and `verifyProcs` block writes one probe-facts JSON file to `<dir>`
  ## at macro-expansion time (see `dumpProbeFacts` below) — module path,
  ## lib pattern, base name, and per-proc pragma facts, for the (future,
  ## Stage B3) harvester to consume. This define is a **dedicated,
  ## single-shot invocation**: run it to (re)generate probe files for a
  ## harvest pass, not something to leave enabled in ordinary dev/CI
  ## builds. Without it (the default — `softlinkDumpProbes == ""`),
  ## `dynlib`/`verifyProcs` perform zero extra work and touch no
  ## filesystem path beyond the compiler's own build products: this
  ## slice is purely additive.

proc probeFactsJson(p: SoftlinkProc): JsonNode =
  ## One proc's pragma facts as a JSON object for the RFC-0001 §4 B.1
  ## probe dump. Deliberately **facts only, no source text**: `prototype`
  ## is dumped as-is because it IS a pragma fact (a string the user
  ## wrote), not a `repr`/declaration reconstruction — the round-1 design
  ## that reassembled proc bodies from `repr` was abandoned (RFC §4 B.1's
  ## round-2 note): it couldn't reproduce pragma-clause semantics
  ## (`optional` etc.) or supply the user's own type definitions from
  ## outside the block.
  ##
  ## `cName` (RFC 0011 S0a item 3): the real, possibly-renamed C symbol —
  ## `p.cName`, which is `nimName` unless a `{.symbol: "c_name".}` pragma
  ## overrode it. The two keys were already both emitted, unconditionally
  ## equal, before this landed (softlink then had no rename axis at all —
  ## the C symbol `symAddr`/the verify assert looked up WAS the proc's Nim
  ## name); that groundwork is why the harvester's schema didn't need to
  ## change shape for this axis to arrive — only the VALUE at this one key
  ## did, from always-equal-to-nimName to the real, independently-tracked
  ## C symbol.
  ##
  ## `since` (RFC-0001 §B.5/§C.2, slice B6a: {.since: "x.y.z".} lands in
  ## THIS slice) now carries the real per-proc value — "" when the pragma
  ## is absent, same as every other optional fact here. The key itself was
  ## already reserved (always `""`) before this slice, precisely so the
  ## harvester's key set would not churn when a real value arrived.
  ##
  ## `until` (RFC-0002 §6, slice A1b): mirrors `since` exactly — the real
  ## per-proc `{.until: "x.y.z".}` value, "" when the pragma is absent. Like
  ## `since`, this is descriptive metadata only: the harvester carries it
  ## but does not yet consume it (that's a later RFC-0002 slice).
  %*{
    "nimName": p.nameStr,
    "cName": p.cName,
    "header": p.headerFile,
    "prototype": p.prototype,
    "verifyWhen": p.verifyWhen,
    "optional": p.isOptional,
    "noverify": p.noVerify,
    "noverifyReason": p.noVerifyReason,
    "since": p.sinceVersion,
    "until": p.untilVersion
  }

proc dumpProbeFacts(kind, modulePath, libPattern, baseName: string,
                     procs: seq[SoftlinkProc], callNode: NimNode) =
  ## RFC-0001 §4 B.1: write `<softlinkDumpProbes>/<baseName>.probes.json`.
  ## No-op when the `-d:softlinkDumpProbes=<dir>` define is absent or was
  ## given an empty value — the common case, and the entirety of this
  ## slice's footprint when unused.
  ##
  ## Write-then-rename, because nimsuggest/`nim check` expand macros
  ## speculatively and a torn write must never be observable by a
  ## concurrent reader (RFC §4 B.1): `writeFile` runs fine from macro/VM
  ## code, but `os.moveFile` does not — it FFI-imports `c_rename`, which
  ## the compile-time VM refuses ("cannot 'importc' variable at compile
  ## time"). `staticExec` (the documented fallback of last resort) shells
  ## out for the rename step only, to the platform's own atomic-rename
  ## command (POSIX `mv -f`, an atomic `rename()` within one directory;
  ## Windows `move /Y`) — the part that could tear (the actual byte
  ## content) is still a single `writeFile` to a `.tmp` sibling in the
  ## SAME directory, so the rename is same-filesystem by construction.
  ##
  ## `softlinkDumpProbes` MUST be an absolute path (enforced below,
  ## empirically discovered during this slice's TDD cycle): Nim ties
  ## `staticExec`'s subprocess working directory to the directory of the
  ## Nim FILE that lexically contains the `staticExec` call — this file,
  ## softlink.nim — never to the invoking `nim c`'s actual process cwd.
  ## `writeFile`/`createDir` above, by contrast, DO resolve relative paths
  ## against the true process cwd (verified directly: a relative dir
  ## produces `.tmp` files under the real invocation directory, while the
  ## following `staticExec("mv ...")` with that SAME relative path fails
  ## with "cannot stat ... No such file or directory", because its shell
  ## subprocess cwd is softlink.nim's own directory instead). Requiring an
  ## absolute `<dir>` sidesteps the mismatch entirely (absolute paths are
  ## cwd-independent) rather than attempting to reconstruct the invoking
  ## process's cwd from inside the VM, which has no accessible primitive
  ## for it (`os.getCurrentDir`/`absolutePath` themselves fail at compile
  ## time — "cannot 'importc' variable at compile time; getcwd"). This is
  ## a fine constraint for the documented single-shot harvester
  ## invocation this define targets (B.2/B.3 fully control the `-d:` value
  ## they pass), not a hardship for a human typing it once.
  if softlinkDumpProbes.len == 0: return
  if not isAbsolute(softlinkDumpProbes):
    error("softlink: -d:softlinkDumpProbes requires an ABSOLUTE directory " &
          "path (got '" & softlinkDumpProbes & "') — its write-then-rename " &
          "step shells out via staticExec, whose working directory Nim " &
          "ties to the directory of the Nim file containing the call " &
          "(softlink.nim itself), not the invoking `nim c`'s process cwd, " &
          "so a relative path here resolves to the wrong location. Pass " &
          "an absolute path, e.g. -d:softlinkDumpProbes=$(pwd)/probes on " &
          "POSIX shells.", callNode)
    return
  createDir(softlinkDumpProbes)
  var procsArr = newJArray()
  for p in procs:
    procsArr.add(probeFactsJson(p))
  let doc = %*{
    "schemaVersion": 1,
    "kind": kind,
    "modulePath": modulePath,
    "libPattern": libPattern,
    "baseName": baseName,
    "procs": procsArr
  }
  let target = softlinkDumpProbes / (baseName & ".probes.json")
  let tmp = target & ".tmp"
  writeFile(tmp, doc.pretty)
  when defined(windows):
    discard staticExec("cmd /c move /Y " & quoteShell(tmp) & " " & quoteShell(target))
  else:
    discard staticExec("mv -f " & quoteShell(tmp) & " " & quoteShell(target))

proc seqOfTupleType(fields: openArray[(string, string)]): NimNode =
  ## Build the NimNode for `seq[tuple[<name1>: <type1>, <name2>: <type2>,
  ## ...]]` — RFC-0001 §C.3, slice C4b needs this for
  ## `softlinkDriftStories<Base>`'s and the per-load drift-refused
  ## partition var's types. `quote do: seq[tuple[symbol: string, ...]]`
  ## looks like the idiomatic route but was VERIFIED to mis-resolve the
  ## field name `symbol` against `std/macros`' own (deprecated)
  ## `proc symbol*(n: NimNode): NimSym` — `tuple[symbol: ...]`'s field
  ## list, reparsed by `quote`, hits ordinary overload resolution for the
  ## identifier `symbol` instead of being treated as a field declaration,
  ## and `macros.symbol` is in scope (this module imports `std/macros`),
  ## producing "cannot use symbol of kind 'proc' as a 'field'" at the call
  ## site. Building the `nnkTupleTy` node directly — the same way
  ## `procTy`/`ptrReturnType` elsewhere in this file build proc-type nodes
  ## — sidesteps `quote` (and this whole class of accidental-capture
  ## bugs) entirely.
  var tupleTy = newNimNode(nnkTupleTy)
  for (fname, tname) in fields:
    tupleTy.add(newNimNode(nnkIdentDefs).add(ident(fname), ident(tname), newEmptyNode()))
  newNimNode(nnkBracketExpr).add(ident("seq"), tupleTy)

proc calleeIdentName(n: NimNode): string =
  ## Fully resolves a call/command node's callee-position node (`n`) to a
  ## plain identifier name, seeing through every syntactic wrapper that
  ## leaves the call DIRECT, or `""` if it isn't a recognizable direct
  ## callee (a computed expression, a proc/closure value, a multi-token
  ## accquoted, etc.) — callers treat `""` as "no recognizable direct
  ## callee name", never as a match.
  ##
  ## Code-review findings R2-1/R3-1: this is the SINGLE normalization point.
  ## All three unwrap steps live here, in the only correct order, so no
  ## caller has to sequence them (an earlier split across
  ## `normalizeCalleeNode` + an inline dot-unwrap made correctness depend on
  ## the caller getting that order right — the same footgun R2-1 itself
  ## fixed):
  ##   1. strip wrapping single-child `nnkPar` — `(P)`, `((P))`, and the
  ##      paren-wrapped-UFCS `(x.P)` — repeatedly. An `nnkPar` with
  ##      `len != 1` is a TUPLE CONSTRUCTOR (`(a, b)`), never a grouped
  ##      expression, and is left untouched (stripping it would treat an
  ##      unrelated shape as a callee). Parens come off FIRST so a paren
  ##      wrapping a dot-expr callee exposes the `DotExpr` for step 2.
  ##   2. unwrap a dot-call/UFCS callee (`x.P(...)`, AST `DotExpr(x, P)`) to
  ##      its field half `P` — UFCS is sugar, not an indirection, so it is
  ##      exactly as direct and detectable as the bare-ident form `P(x)`.
  ##   3. extract a bare `nnkIdent`, or a single-token `` `P` ``
  ##      (`nnkAccQuoted`, so `` x.`P`(...) `` resolves like `x.P(...)`).
  ## Detection is thereby paren/UFCS-insensitive at a single call site.
  var cur = n
  while cur.kind == nnkPar and cur.len == 1:
    cur = cur[0]
  if cur.kind == nnkDotExpr and cur.len == 2:
    cur = cur[1]
  if cur.kind == nnkIdent:
    $cur
  elif cur.kind == nnkAccQuoted and cur.len == 1 and cur[0].kind == nnkIdent:
    $cur[0]
  else:
    ""

proc scanProbeBodyForDriftCalls(stmts: NimNode, mismatchCNames: HashSet[string]): bool =
  ## RFC-0001 §C.1/§C.3, slice C4b: "the version probe may only call
  ## symbols with no known drift ranges" (RFC §C.1: "the probe must not be
  ## the drift"). Walks `stmts` (the versionProbe body, still raw AST at
  ## macro-expansion time — the manifest is already parsed by now) looking
  ## for a DIRECT call (`nnkCall`/`nnkCommand`) whose callee is a bare ident
  ## matching `mismatchCNames` — this block's own symbols (required OR
  ## optional; required-symbol RUNTIME refusal is C4c's territory, but the
  ## call-safety risk this scan guards against exists for both) that carry
  ## ANY `mismatch` interval in the attached manifest. This scan is
  ## deliberately UNCONDITIONAL — unlike runtime refusal it is NOT lifted by
  ## `refuse = false` / `-d:softlinkNoDriftRefusal` (code-review #10, resolved
  ## Option A: keep unconditional, explain in the diagnostic). The escape
  ## hatches relax how your APP treats drifted symbols; they say nothing about
  ## whether the version-detection probe — which runs first and keys the whole
  ## drift machinery — may itself rest on one. The error message spells this
  ## out. The dot-call/UFCS
  ## form (`x.P(...)`, AST `Call(DotExpr(x, P), ...)`) is ALSO matched: the
  ## callee's `P` half is exactly as direct and exactly as detectable as
  ## the bare-ident form `P(x)` — UFCS is sugar, not an indirection, so
  ## treating it as unseeable would be a real gap, not a documented one.
  ## The callee position goes through `calleeIdentName`, which resolves any
  ## paren-wrapped (`(P)(x)`, `((P))(x)`, `(x.P)(x)`) or UFCS callee to its
  ## bare name in one step (R2-1/R3-1) — detection here is paren/UFCS-
  ## insensitive. Emits ONE macro error at the offending call node and stops
  ## (returns `true`) — a probe with several such calls gets one diagnostic,
  ## not a pile-up. Indirect calls TRULY through a variable, a closure, or a
  ## method value can't be seen statically; that residual risk is accepted
  ## and documented here, not pretended away, per the RFC's own words.
  if stmts.kind in {nnkCall, nnkCommand} and stmts.len > 0:
    let callee = calleeIdentName(stmts[0])
    if callee.len > 0 and callee in mismatchCNames:
      error("softlink: dynlib: versionProbe directly calls '" & callee &
            "', which has a recorded 'mismatch' interval in the attached " &
            "compat manifest — the version probe may only call symbols " &
            "with no known drift ranges (RFC-0001 §C.1: \"the probe must " &
            "not be the drift\"). This is deliberately NOT suppressed by " &
            "refuse = false or -d:softlinkNoDriftRefusal: those relax the " &
            "RUNTIME refusal of drifted symbols in your own code, but the " &
            "probe runs earlier — to determine the version the whole drift " &
            "machinery is keyed on — so a probe built on a symbol of " &
            "uncertain signature can misreport that version before any " &
            "refusal policy could apply; its soundness stays unconditional. " &
            "Read the version through a drift-free symbol instead. (Indirect " &
            "calls cannot be detected statically and remain a documented " &
            "residual risk.)", stmts)
      return true
  for child in stmts:
    if scanProbeBodyForDriftCalls(child, mismatchCNames):
      return true
  false

proc collectBodylessProcDeclsInWhen(whenStmt: NimNode): seq[NimNode] =
  ## RFC 0011 (softlink-authored diagnostic for conditional binding
  ## declarations): recursively walks a top-level `when` statement's
  ## branches — `nnkElifBranch`/`nnkElifExpr` and a trailing
  ## `nnkElse`/`nnkElseExpr`, nested `when`s included — looking for a
  ## BODYLESS proc declaration (`nnkProcDef` with an empty body), the exact
  ## shape that means "binding declaration" everywhere else in a `dynlib`
  ## block body. Statement pass-through (RFC 0011 S0a item 4) treats a
  ## `when` as one opaque statement to splice through verbatim — correct
  ## for a `when` guarding ordinary helper code, but it means the body-scan
  ## loop that recognizes bindings NEVER looks inside a `when`'s branches at
  ## all, so a user who writes a bodyless proc there (evidently trying to
  ## make a CONDITIONAL binding) gets no binding, no softlink diagnostic,
  ## and — because the proc is re-emitted as ordinary code with no defined
  ## body — Nim's own bare "implementation expected" once the generated
  ## code is compiled. Returns every offending proc def found (possibly
  ## none, meaning the `when` is legitimate pass-through and must be left
  ## untouched); the caller turns a non-empty result into ONE softlink
  ## error naming the first offender.
  for branch in whenStmt:
    # `nnkElifBranch`/`nnkElifExpr` have 2 children (cond, stmts); a
    # trailing `nnkElse`/`nnkElseExpr` has 1 (stmts) — the branch's
    # statement list is always its LAST child either way.
    let stmts = branch[branch.len - 1]
    if stmts.kind != nnkStmtList: continue
    for s in stmts:
      if s.kind == nnkProcDef and s.body.kind == nnkEmpty:
        result.add(s)
      elif s.kind == nnkWhenStmt:
        result.add(collectBodylessProcDeclsInWhen(s))

const conditionalBindingErrorMsg =
  "softlink: dynlib: conditional binding declarations are not supported " &
  "inside a dynlib block: a `when` passes through as ordinary code and " &
  "its procs are never scanned as bindings. Split into separate `dynlib` " &
  "blocks (one per configuration, distinct `identBase`), or wrap the " &
  "whole block in a top-level `when`."

macro dynlib*(libPattern: static[string], body: untyped): untyped =
  ## Generate type-safe, runtime-optional bindings for a dynamic library.
  ## The generated ``loadXxx``/``unloadXxx`` procs are **not thread-safe**.
  ## Wrapper proc calls must also not race with ``unloadXxx`` — the loaded
  ## state and function pointer dispatch are not atomic.
  ## Callers must synchronize externally if using from multiple threads.
  ##
  ## `libPattern` may be a bare logical name (``"z3"``), in which case the
  ## per-OS candidate names are derived automatically (see `deriveLibPattern`);
  ## or an explicit `loadLibPattern` string (``"libz3.so(.4|)"``), used verbatim.
  ##
  ## Per-proc pragmas: a calling convention (required), ``header`` (required
  ## unless ``noverify`` or ``prototype``), ``optional`` (symbol may be
  ## missing at runtime), ``verifyWhen: "C_PP_EXPR"`` (verify only when the
  ## preprocessor condition holds — for symbols newer than some installed
  ## headers), ``noverify`` (skip verification — for symbols no header
  ## declares), and ``prototype: "<C prototype>"`` (RFC-0001 §3 A.1: a
  ## vendored declaration copied from upstream's header, checked for a
  ## well-formed, non-variadic, name-matching C prototype; may coexist with
  ## ``header`` for cross-checking, but not with ``noverify``. Emitted as a
  ## file-scope ``extern`` declaration in the verify TU — verified with the
  ## same call-based ``_Static_assert`` machinery as a header, so a
  ## ``prototype``-only proc is fully header-verified without a header).
  let resolvedPattern =
    if libPattern.isLogicalName: deriveLibPattern(libPattern, currentLibOs())
    else: libPattern
  # RFC 0011 S0a item 1: `identBase` overrides `baseName` below — scanned
  # BEFORE `baseName` is derived (see `scanIdentBase`'s own doc comment for
  # why this can't be a fourth case inside the per-statement body loop
  # further down, like `compatManifest`/`versionProbe`/`versionMacros`).
  let identBaseOverride = scanIdentBase(body, "dynlib")
  # Absent an `identBase` override, derive the ident base from the
  # *logical* name (the macro argument), NOT the OS-expanded pattern.
  # RFC 0011 S0a item 2 closed the historical trap here: deriveLibPattern's
  # Windows form "(libz3|z3).dll" used to mangle through libNameToIdent to
  # "Libz3z3" (vs "Z3" from the logical name, breaking cross-OS ident
  # stability) — libNameToIdent's leading-alternation normalization now
  # reduces it the same way "Z3" does, so deriving from `libPattern` here
  # is belt-and-suspenders for that case, not load-bearing. It STAYS
  # load-bearing for hand-authored EXPLICIT per-OS patterns with
  # irreducibly different stems across platforms — e.g. Windows
  # "(lib|)gtk-4-1.dll" (base "Gtk41") vs Linux "libgtk-4.so(|.1)" (base
  # "Gtk4") — no string-level normalization can unify "4-1" and "4".
  # `identBase` (above) is the escape hatch for exactly that case, and for
  # giving multiple blocks over one library distinct load-proc names.
  let baseName =
    if identBaseOverride.present: identBaseOverride.overrideName
    else: libNameToIdent(libPattern)
  if baseName.len == 0:
    error("cannot derive identifier from dynlib pattern '" & libPattern & "'", body)
  if not baseName[0].isAlphaAscii:
    error("dynlib pattern '" & libPattern & "' produces invalid identifier '" &
          baseName & "' (must start with a letter)", body)
  let baseNameLower = baseName.toLowerAscii()
  let loadProcName = ident("load" & baseName)
  let unloadProcName = ident("unload" & baseName)
  let loadedProcName = ident(baseNameLower & "Loaded")
  let handleName = ident("softlinkHandle" & baseName)
  let cachedResultName = ident("softlinkResult" & baseName)
  # RFC-0001 §9/§C.2, slice C2: the compat report's backing var — named
  # alongside `softlinkHandle<Base>`/`softlinkResult<Base>` above, same
  # convention. Unlike the probe state vars just below, this one is
  # emitted UNCONDITIONALLY: `fooCompat()` is generated for every dynlib
  # block. Its initial value depends on `hasProbe` (finding #11, computed
  # further below): a probe-less block's query proc always returns the
  # var's bare zero value, `atNoProbe`; a probe-bearing block's initial
  # value is explicitly set to `atProbeNotRun` once `hasProbe` is known
  # (see the assignment right after the probe state vars below).
  let compatReportName = ident("softlinkCompatReport" & baseName)
  let libPatternLit = newStrLitNode(resolvedPattern)
  # RFC-0001 §9/§C.1, slice C1b: the probe's outcome state (read by C2's
  # CompatReport construction below) and the internal reentrancy flag —
  # named alongside `softlinkHandle<Base>`/`softlinkResult<Base>` above,
  # following the same convention. All three are emitted only when this
  # block declares a (well-formed) `versionProbe` — see `hasProbe` below,
  # computed after the body loop that finds out.
  let probedVersionName = ident("softlinkProbedVersion" & baseName)
  let probeFailedName = ident("softlinkProbeFailed" & baseName)
  let loadInProgressName = ident("softlinkLoadInProgress" & baseName)
  # Hygienic proc name for the versionProbe body's own generated proc (see
  # its emission point below, alongside the unloadX forward declaration) —
  # `genSym` rather than a derived-from-baseName ident since this proc is
  # purely an implementation detail, never referenced outside this macro's
  # own generated code.
  let probeProcSym = genSym(nskProc, "versionProbeBody")

  proc reentrancyRaiseStmt(procNameStr: string): NimNode =
    ## RFC-0001 §9/§C.1: "`loadX` and `unloadX` raise `SoftlinkError`
    ## (\"loadX called reentrantly from its own versionProbe\")" — built
    ## here (a closure over `libPatternLit`) so both `loadX`'s and
    ## `unloadX`'s own reentrancy checks share one wording, adapted per the
    ## actual generated proc name (`procNameStr`).
    newNimNode(nnkRaiseStmt).add(
      newNimNode(nnkObjConstr).add(
        ident("SoftlinkError"),
        newNimNode(nnkExprColonExpr).add(ident("msg"), newStrLitNode(
          procNameStr & " called reentrantly from its own versionProbe")),
        newNimNode(nnkExprColonExpr).add(ident("library"), libPatternLit),
        newNimNode(nnkExprColonExpr).add(ident("symbol"), newStrLitNode(""))
      )
    )

  proc compatReportObjConstr(fields: seq[(string, NimNode)]): NimNode =
    ## RFC-0001 §9/§C.2: build one `CompatReport(...)` object-constructor
    ## node — a closure only in spirit (no captures), grouped here purely
    ## so every report shape in `loadXxx`/`unloadXxx` below goes through one
    ## place. `fields` omitted entirely means every OTHER field takes its
    ## zero-value default (`""`, `@[]`) — callers wanting the block's own
    ## "probe hasn't run" state (finding #11: `atProbeNotRun` if this block
    ## has a probe, else bare `atNoProbe`) pass that explicitly via
    ## `probeNotRunFields()` below rather than relying on the bare enum
    ## zero value, which is only ever correct for probe-less blocks.
    result = newNimNode(nnkObjConstr).add(ident("CompatReport"))
    for (fieldName, valNode) in fields:
      result.add(newNimNode(nnkExprColonExpr).add(ident(fieldName), valNode))

  proc assignCompatReportStmt(fields: seq[(string, NimNode)] = @[]): NimNode =
    ## RFC-0001 §9/§C.2: `softlinkCompatReport<Base> = CompatReport(...)` —
    ## a closure over `compatReportName`, the ONE assignment shape every
    ## `loadXxx` return path below uses (Phase-1 early returns via the
    ## zero-field form, the post-probe success path via the classified
    ## form) — see the design guidance's "one AST-generating helper" call.
    newAssignment(compatReportName, compatReportObjConstr(fields))

  proc unwindStmt(unloadHandle: bool, resultKind: NimNode,
                   resultFields: seq[(string, NimNode)] = @[],
                   reportFields: seq[(string, NimNode)] = @[],
                   resetPtrs: seq[NimNode] = @[],
                   resetProbeState: bool = false): NimNode =
    ## RFC-0001 §9/§C.3-C.4, slice C4a: the shared cleanup/unwind AST
    ## helper — "Phase-1 early-fail, post-probe required unwind, optional
    ## re-nil ... one generator, behavior-preserving for the existing path"
    ## (RFC §9 C4a; motivating note at RFC §C.3 lines 641-645). A closure
    ## over `handleName` (like `reentrancyRaiseStmt`/`assignCompatReportStmt`
    ## above), building ONE statement-list shape:
    ##   [unloadLib(handle); handle = nil]   -- only when `unloadHandle`
    ##   softlinkCompatReport<Base> = CompatReport(reportFields...)
    ##   return LoadResult(kind: resultKind, resultFields...)
    ##
    ## Two shapes are wired TODAY, both pure extractions of previously-inline
    ## code (no behavior change):
    ##   - lrLibNotFound (`loadLibPattern` returned nil — there is no handle
    ##     to unload yet): unwindStmt(unloadHandle = false,
    ##     resultKind = ident("lrLibNotFound"))
    ##   - Phase-1 required-symbol early-fail (`symAddr` returned nil before
    ##     any function pointer was assigned): unwindStmt(unloadHandle = true,
    ##     resultKind = ident("lrSymbolNotFound"),
    ##     resultFields = @[("symbol", symName)])
    ## Both pass `reportFields = probeNotRunFields()` (finding #11: the
    ## block's own "probe hasn't run" state — `atProbeNotRun` if this block
    ## declares a `versionProbe`, otherwise the bare zero-value `atNoProbe`
    ## — is correct pre-first-load / right after unloadX resets state, and
    ## is exactly as correct after a Phase-1 early-fail, since Phase 3/the
    ## probe never ran either way) — already threaded through so C4c can
    ## pass a non-empty (drift-story) report without touching this proc.
    ##
    ## RFC-0001 §C.3, slice C4c: a THIRD shape is now wired, additively —
    ## the post-probe REQUIRED-symbol drift-refusal unwind (see the
    ## `dynlib` macro's `requiredDriftCandidates` loop, inside the
    ## `atAttested` branch of `loadXxx`): unwindStmt(unloadHandle = true,
    ## resultKind = ident("lrSymbolNotFound"), resultFields = @[("symbol",
    ## symName)], reportFields = @[("runtimeVersion", ...), ("attestation",
    ## ident("atAttested")), ("missingReasons", ...)], resetPtrs = <every proc's
    ## ptrName in this block>, resetProbeState = true). Firing later in the
    ## pipeline than the other two shapes (after Phase 3 has assigned every
    ## pointer and the probe has run) is exactly why the two NEW leading
    ## cleanup steps below exist: nil every already-assigned function-
    ## pointer var (`resetPtrs`, mirroring unloadX's own per-proc reset
    ## loop), and reset the probe state vars (`resetProbeState`, mirroring
    ## unloadX's own `softlinkProbedVersion<Base>`/`softlinkProbeFailed
    ## <Base>` reset) — both purely additive params defaulting to `@[]`/
    ## `false`, so shape-1/shape-2 call sites (`unloadHandle = false` for
    ## `lrLibNotFound`; the Phase-1 required-symbol early-fail) need no
    ## change and their generated output stays token-identical (see
    ## `tests/tcompat_drift_required.nim`'s use of this third shape, and
    ## the C4c handoff for the `expandMacro` diff proving shapes 1/2 are
    ## unaffected).
    ##
    ## `resetProbeState`'s ordering here — leading cleanup, BEFORE the
    ## report assignment below — means a caller must never pass the LIVE
    ## `softlinkProbedVersion<Base>` node itself as a `reportFields`
    ## `runtimeVersion` value when also passing `resetProbeState = true`:
    ## by the time the report-assign statement executes, that var has
    ## already been reset to `""`. Callers needing both must snapshot the
    ## probed version into their OWN `let` BEFORE calling this proc, and
    ## pass that snapshot instead — a plain Nim `string` `let` copies the
    ## value, so the snapshot is unaffected by the reset that follows it
    ## (this is the "report snapshots the string value — safe" resolution
    ## flagged in the C4c slice brief). See the required-refusal call site
    ## for the snapshot in practice.
    ##
    ## Historical note: C4b's optional re-nil (re-nil one already-resolved
    ## optional pointer + add its name to the `missing` set) does NOT go
    ## through this proc — it is not a return-path cleanup at all (the
    ## pipeline keeps running to classify the remaining symbols, so neither
    ## a compat-report assignment nor a `return` may fire for it), so C4b
    ## implemented it inline in the `dynlib` macro's `atAttested` branch
    ## instead of forcing it through a `terminal: bool` toggle here, as an
    ## earlier draft of this comment had proposed. This proc stays scoped
    ## to genuine return-path unwinds (all three shapes above share exactly
    ## that structure); C4c's required-refusal shape confirms the fit.
    result = newStmtList()
    for ptrNode in resetPtrs:
      result.add(newAssignment(ptrNode, newNilLit()))
    if resetProbeState:
      result.add(newAssignment(probedVersionName, newStrLitNode("")))
      result.add(newAssignment(probeFailedName, newLit(false)))
    if unloadHandle:
      result.add(newCall(ident("unloadLib"), handleName))
      result.add(newAssignment(handleName, newNilLit()))
    result.add(assignCompatReportStmt(reportFields))
    var resultConstr = newNimNode(nnkObjConstr).add(ident("LoadResult"))
    resultConstr.add(newNimNode(nnkExprColonExpr).add(ident("kind"), resultKind))
    for (fieldName, valNode) in resultFields:
      resultConstr.add(newNimNode(nnkExprColonExpr).add(ident(fieldName), valNode))
    result.add(newNimNode(nnkReturnStmt).add(resultConstr))

  # RFC 0011 S0a item 4: a body statement is either a BINDING (a bodyless
  # proc declaration — dynlib's actual reason for existing) or PASS-
  # THROUGH (anything else: a `type`/`const` section, a proc WITH a body,
  # a `var`/`let`/`template`/`when`, or a doc-comment statement).
  # `orderedItems` (populated by the body-scan loop below) records both
  # kinds in ONE source-ordered list, which is what lets final emission
  # (further below) interleave a passed-through helper with the wrapper of
  # a binding it calls in the same relative order the author wrote them —
  # walking `procs` and a separate pass-through seq independently could
  # not reconstruct that interleaving once both lists are collected.
  type
    DynlibItemKind = enum
      diBinding
      diPassthrough
    DynlibItem = object
      case kind: DynlibItemKind
      of diBinding: procIdx: int
      of diPassthrough: stmt: NimNode

  result = newStmtList()

  # Duplicate-block guard. Two dynlib blocks whose patterns derive the same
  # ident base (e.g. `dynlib "m"` twice, or "libfoo.so" + "foo") would
  # re-declare every module-scope state var and public proc, surfacing as an
  # opaque "redefinition of 'softlinkHandleX'" pointing INTO softlink.nim.
  # `declared()` is evaluated in the expansion scope at semantic time — before
  # this block's own declarations below — so it fires exactly when a previous
  # expansion in the same scope already claimed the names, and stays silent
  # across modules (the state vars are not exported). See #14/Defect A.
  block:
    let dupMsg = "softlink: dynlib block for '" & libPattern &
      "' collides with an earlier dynlib block in the same scope (both " &
      "derive the identifier base '" & baseName & "' → load" & baseName &
      ", softlinkHandle" & baseName & ", ...). Merge the procs into the " &
      "earlier block; mark symbols that may be missing at runtime " &
      "{.optional.}, adding {.noverify.} if a symbol is also absent from " &
      "the installed C headers."
    var errPragma = newNimNode(nnkPragma).add(
      newNimNode(nnkExprColonExpr).add(ident("error"), newStrLitNode(dupMsg)))
    errPragma.copyLineInfo(body)
    result.add(newNimNode(nnkWhenStmt).add(
      newNimNode(nnkElifBranch).add(
        newCall(ident("declared"), handleName),
        newStmtList(errPragma))))

  # RFC 0011 (per-block pattern-override seam): a compile-time-overridable
  # copy of this block's search pattern, keyed on the block's EFFECTIVE
  # identBase (`baseName` — the explicit `identBase` override if present,
  # else the derived one), NOT on `resolvedPattern`/`libPatternLit` — this
  # is what keeps the override from ever touching identifier derivation,
  # verification, the manifest, probe-facts, or drift logic, all of which
  # key off the DECLARED pattern/identBase exactly as before. Consumed at
  # LOAD TIME ONLY, in `loadBody` below: empty (the default) means "no
  # override", and `loadX` uses the declared pattern unchanged. A non-empty
  # override is a full softlink pattern in its own right — it goes through
  # the identical `libCandidates` alternation/version-suffix expansion a
  # hand-written pattern would, so `LoadResult.attempts`/`osLoaderDetail`
  # name the OVERRIDE's own candidates, not the declared ones. See the
  # README's "Pattern override: redirecting a block's search pattern at
  # build time" section. Two blocks over the same declared pattern text but
  # different `identBase`s (the `identBase` directive's own second
  # motivating case) get two independently-keyed overrides, by construction
  # — this const's name and its strdefine key both derive from `baseName`,
  # which is exactly what disambiguates them. Not emitted for `verifyProcs`:
  # that macro has no library identity at all (no `libPattern` parameter, no
  # `loadX`), so there is no pattern to override in the first place — see
  # the README section for the explicit non-applicability note.
  let patternOverrideName = ident(baseNameLower & "PatternOverride")
  result.add(newNimNode(nnkConstSection).add(
    newNimNode(nnkConstDef).add(
      newNimNode(nnkPragmaExpr).add(
        patternOverrideName,
        newNimNode(nnkPragma).add(
          newNimNode(nnkExprColonExpr).add(
            ident("strdefine"),
            newStrLitNode("softlink.pattern." & baseName)
          )
        )
      ),
      newEmptyNode(),
      newStrLitNode("")
    )
  ))

  # var handle: LibHandle
  result.add(newNimNode(nnkVarSection).add(
    newNimNode(nnkIdentDefs).add(
      handleName,
      ident("LibHandle"),
      newEmptyNode()
    )
  ))

  # var cachedResult: LoadResult — zero-initializes to lrOk, but the
  # idempotent guard checks the handle (nil before first load), so
  # this value is never returned to callers before loadXxx runs.
  result.add(newNimNode(nnkVarSection).add(
    newNimNode(nnkIdentDefs).add(
      cachedResultName,
      ident("LoadResult"),
      newEmptyNode()
    )
  ))

  # var compatReport: CompatReport — RFC-0001 §9/§C.2: bare zero-initializes
  # to `atNoProbe`, `""`, `@[]` here (mirrors `cachedResult` above); a
  # PROBE-BEARING block's initial value is then corrected to `atProbeNotRun`
  # (finding #11) by an explicit assignment emitted once `hasProbe` is known
  # (below, right after the probe state vars) — a probe-less block needs no
  # such correction, since `atNoProbe` IS its permanent, correct value.
  # Emitted for EVERY dynlib block, unlike the probe state vars further
  # below — `fooCompat()` is generated unconditionally (see its emission
  # point near `xxxLoaded*`).
  result.add(newNimNode(nnkVarSection).add(
    newNimNode(nnkIdentDefs).add(
      compatReportName,
      ident("CompatReport"),
      newEmptyNode()
    )
  ))

  # Collect proc info, hoisted type/const sections, and pass-through
  # statements (RFC 0011 S0a item 4). See `DynlibItem`'s doc comment above
  # for why bindings and pass-through statements share one source-ordered
  # list (`orderedItems`) instead of two independent seqs.
  var procs: seq[SoftlinkProc]
  var hoisted: seq[NimNode]
  var orderedItems: seq[DynlibItem]
  var seenNames: HashSet[string]
  var manifestDirective: CompatManifestDirective
  var versionProbeDirective: VersionProbeDirective
  var versionMacrosDirective: VersionMacrosDirective
  var noVerifyDirective: NoVerifyDirective
  var trustedWrappersDirective: TrustedWrappersDirective

  for stmt in body:
    # RFC-0001 §B.5, slice B6a: the `compatManifest` body directive — at
    # most one per block, any position. Consumed here (never re-emitted),
    # exactly like every proc declaration below is consumed and
    # regenerated rather than passed through verbatim — this is why a
    # correctly-placed directive never reaches the erroring stub proc
    # `compatManifest` above.
    if isCompatManifestCall(stmt):
      let d = parseCompatManifestDirective(stmt, "dynlib")
      if manifestDirective.present:
        error(compatManifestDupError("dynlib", manifestDirective, d), stmt)
      else:
        manifestDirective = d
      continue

    # RFC-0001 §9/§C.1, slice C1b: the `versionProbe` body directive — at
    # most one per block, any position. Consumed here (never re-emitted
    # verbatim — its statements are spliced into `loadXxx` below), exactly
    # like `compatManifest` above.
    if isVersionProbeStmt(stmt):
      let d = parseVersionProbeDirective(stmt, "dynlib")
      if versionProbeDirective.present:
        error(versionProbeDupErrorMsg, stmt)
      else:
        versionProbeDirective = d
      continue

    # RFC-0002 §5/§6, slice E1: the `versionMacros` body directive — Stage
    # E gate-synthesis input (§5 Layer 2). At most one per block, any
    # position, mirroring `compatManifest`/`versionProbe` above. This slice
    # only parses and stores the result (`versionMacrosDirective`); nothing
    # consumes the macro list yet — see the `discard` near this macro's end.
    if isVersionMacrosCall(stmt):
      let d = parseVersionMacrosDirective(stmt, "dynlib")
      if versionMacrosDirective.present:
        error(versionMacrosDupError("dynlib", versionMacrosDirective, d), stmt)
      else:
        versionMacrosDirective = d
      continue

    # RFC 0011 S0a item 6: the block-level `noverify: "reason"` directive —
    # at most one per block, any position, mirroring `compatManifest`/
    # `versionProbe`/`versionMacros` above. Recognized and consumed HERE
    # (unlike `identBase`, which must be fully resolved before `baseName`
    # is derived above) — nothing before this point in the macro depends on
    # it. Its actual EFFECT (defaulting every bodyless proc with no other
    # verification source) is applied in a post-body-scan pass, once
    # `procs` is fully collected — see `applyNoVerifyDefault`'s own doc
    # comment for why that deferral is required.
    if isNoVerifyCall(stmt):
      let d = parseNoVerifyDirective(stmt, "dynlib")
      if noVerifyDirective.present:
        error(noVerifyDupError("dynlib", noVerifyDirective, d), stmt)
      else:
        noVerifyDirective = d
      continue

    # RFC 0011 S0b, work item (i)(e): the block-level `trustedWrappers`
    # directive — at most one per block, any position, mirroring
    # `compatManifest`/`versionProbe`/`versionMacros`/`noverify` above.
    # Recognized and consumed HERE (nothing before this point depends on
    # it — unlike `identBase`). Its EFFECT (every wrapper in this block
    # becomes `{.raises: [].}`, nil branch fatals instead of raising) is
    # applied at wrapper-emission time below, and the versionProbe
    # mutual-exclusion check (work item (i)(i)) fires once both directives
    # are known, right after this loop.
    if isTrustedWrappersCall(stmt):
      let d = parseTrustedWrappersDirective(stmt, "dynlib")
      if trustedWrappersDirective.present:
        error(trustedWrappersDupError("dynlib"), stmt)
      else:
        trustedWrappersDirective = d
      continue

    # RFC 0011 S0a item 1: the `identBase` body directive — already fully
    # scanned, validated, and consumed by `scanIdentBase` ABOVE, before
    # `baseName` was derived (see that proc's own doc comment for why this
    # is the one directive NOT recognized-and-consumed inside this loop
    # like the three above). This branch only needs to skip it here so
    # it's never mistaken for a proc declaration and never re-emitted.
    if isIdentBaseCall(stmt):
      continue

    # RFC 0011 S0a item 4: "bodyless proc = binding declaration; anything
    # else passes through verbatim" — the general rule replacing the old
    # blanket `stmt.kind != nnkProcDef` rejection (pre-item-4 wording:
    # "dynlib body must contain only proc declarations..."). A `type`/
    # `const` section, a proc WITH a body (e.g. a passed-through `==`/
    # `hash` helper), a `var`/`let`/`template`/`when`, or a doc-comment
    # statement (`nnkCommentStmt`) are all legal now; only a BODYLESS proc
    # still means "resolve this symbol at runtime" — keeping every
    # migration diff a per-proc pragma swap instead of a whole-file
    # restructuring pass (binding modules routinely interleave narrative
    # type/const/helper definitions with declarations).
    #
    # Narrower generic-error surface is the accepted trade-off: a
    # misspelled directive (e.g. `identBas "X"`) no longer gets a
    # softlink-authored error here — it falls through as ordinary user
    # code and fails with Nim's own "undeclared identifier" at the call
    # site, same trade-off `{.noverify.}` already made for symbols no
    # header declares.
    if stmt.kind != nnkProcDef or stmt.body.kind != nnkEmpty:
      case stmt.kind
      of nnkTypeSection, nnkConstSection:
        # Hoisted ahead of every binding's pointer-var declaration (see the
        # emission point below) so a binding's signature may reference a
        # passed-through type declared EITHER before or after it in
        # source (deliverable 2's "both directions" requirement). Ordinary
        # Nim visibility already makes types/consts declaration-order-
        # independent relative to each other, so hoisting changes nothing
        # observable about the passed-through code itself — it only lets
        # every binding see it regardless of source position.
        hoisted.add(stmt)
      of nnkWhenStmt:
        # RFC 0011: a `when` is ordinary pass-through UNLESS one of its
        # branches (at any nesting depth) hides a bodyless proc decl — see
        # `collectBodylessProcDeclsInWhen`'s own doc comment for why the
        # ordinary pass-through rule can never see that shape on its own.
        # A `when` with only bodied helpers/types/consts/statements is
        # untouched, exactly like every other pass-through statement.
        let offenders = collectBodylessProcDeclsInWhen(stmt)
        if offenders.len > 0:
          error(conditionalBindingErrorMsg, offenders[0])
        orderedItems.add(DynlibItem(kind: diPassthrough, stmt: stmt))
      else:
        orderedItems.add(DynlibItem(kind: diPassthrough, stmt: stmt))
      continue

    let procName = stmt[0]
    let nameStr = $procName
    let ptrName = ident("softlinkFp" & baseName & nameStr)
    let formalParams = stmt[3]
    let hasReturn = formalParams[0].kind != nnkEmpty

    # Duplicate detection
    if nameStr in seenNames:
      error("duplicate proc '" & nameStr & "' in dynlib block", stmt)
    seenNames.incl(nameStr)

    # Pragma validation: extract calling convention, optional flag, noverify
    # flag, and header via the shared parser (also used by `verifyProcs`).
    let facts = parseProcPragmas(stmt, nameStr, ppmDynlib)

    procs.add(SoftlinkProc(name: procName, nameStr: nameStr, cName: facts.cName,
                        ptrName: ptrName,
                        formalParams: formalParams, callConv: facts.callConv,
                        headerFile: facts.headerFile, isOptional: facts.isOptional,
                        noVerify: facts.noVerify, noVerifyReason: facts.noVerifyReason,
                        verifyWhen: facts.verifyWhen,
                        prototype: facts.prototype, sinceVersion: facts.sinceVersion,
                        untilVersion: facts.untilVersion,
                        hasReturn: hasReturn))
    orderedItems.add(DynlibItem(kind: diBinding, procIdx: procs.high))

  # RFC 0011 S0a item 6: apply the block-level noverify default, then run
  # the (now-deferred) "every proc needs a header, a prototype, or
  # {.noverify.}" check — in that order, and as early as possible after
  # `procs` is fully collected (fail fast, before any codegen below).
  # `checkVerificationSourceRequired` replaces the inline check
  # `parseProcPragmas` used to run per-proc, during the loop just above —
  # see both procs' own doc comments (`softlink/pragmas`) for why the
  # deferral is required: a block-level directive is position-independent
  # and may appear after the proc(s) it defaults for.
  applyNoVerifyDefault(procs, noVerifyDirective.present, noVerifyDirective.reason)
  checkVerificationSourceRequired(procs)

  # RFC 0011 S0b, work item (i)(i): `trustedWrappers` + `versionProbe` in
  # one block is a compile-time error. The probe contract (`atProbeFailed`,
  # `Attestation` above) converts a wrapper's raised `SoftlinkError` into a
  # reported attestation state via try/except around the probe body's own
  # wrapper calls (see the `versionProbe:` splice into `loadXxx` further
  # below) — a `{.raises: [].}` trusted wrapper can never raise for that
  # `except` to catch, so a probe that ever hits a not-loaded/drift-refused
  # trusted wrapper would `_Exit` the whole process instead of the probe
  # cleanly reporting `atProbeFailed`, silently defeating the very
  # mechanism `versionProbe` exists to provide. Deliberately broader than
  # the precise hazard (only a probe body that itself CALLS an
  # `{.optional.}` — the only symbols that can be genuinely unresolved
  # *while* the probe runs — is actually at risk): the RFC records the
  # narrower relaxation as a deferred backlog item, since no shipped block
  # needs it yet.
  if trustedWrappersDirective.present and versionProbeDirective.present:
    error("softlink: dynlib: trustedWrappers and versionProbe cannot both " &
          "be declared in one block — the probe contract converts a " &
          "wrapper's raised SoftlinkError into a reported atProbeFailed " &
          "attestation via try/except around the probe body's own wrapper " &
          "calls, but a trustedWrappers block's wrappers are {.raises: " &
          "[].} and can never raise for that except to catch (a nil " &
          "pointer there terminates the process instead). Split the " &
          "trusted symbols into their own dynlib block with no " &
          "versionProbe, or drop trustedWrappers from this one", body)

  # RFC 0011 S0a item 4: hoisted type/const sections, emitted unconditionally
  # here — regardless of where they appeared in `body` — so they are in
  # scope for EVERY binding's pointer-var declaration just below, whether
  # the binding using one appears before or after it in source (see the
  # `hoisted.add` comment above for why hoisting is safe: types/consts have
  # no forward-reference restriction to preserve, unlike procs).
  for h in hoisted:
    result.add(h)

  # Pointer vars for every binding — batched here, ahead of the interleaved
  # pass-through/wrapper emission further below. RFC-0001 §9/§C.1's
  # original invariant ("pointer vars must precede the first wrapper") is
  # generalized by item 4: pointer vars must also precede any passed-
  # through statement that might call a wrapper, so batching them right
  # after the hoisted section — rather than emitting each one at its own
  # binding's source position, as slice C1a originally did inline above —
  # is what makes "a helper can call any binding declared above it"
  # (source position) hold uniformly, independent of how many other
  # bindings or pass-through statements sit between them. Pointer vars are
  # private (unexported) and order-independent relative to each other, so
  # this reordering changes nothing observable about them.
  for p in procs:
    var procTy = newNimNode(nnkProcTy)
    procTy.add(p.formalParams.copy())
    procTy.add(newNimNode(nnkPragma).add(
      ident(p.callConv),
      newNimNode(nnkExprColonExpr).add(
        ident("raises"),
        newNimNode(nnkBracket)
      )
    ))
    result.add(newNimNode(nnkVarSection).add(
      newNimNode(nnkIdentDefs).add(
        p.ptrName,
        procTy,
        newEmptyNode()
      )
    ))

  # RFC-0001 §9/§C.1, slice C1b: true iff this block declared a WELL-FORMED
  # `versionProbe` — a malformed shape already reported its own error above
  # and leaves `bodyStmts` empty, so every check below gated on `hasProbe`
  # degrades to "as if no probe were declared" rather than crashing or
  # emitting a second, confusing diagnostic for the same mistake.
  let hasProbe = versionProbeDirective.present and versionProbeDirective.bodyStmts.len > 0

  # RFC-0001 §9/§C.2 design guidance (C2 itself — CompatReport — is a later
  # slice): the probe's outcome needs a home for that future query proc to
  # read. Two unexported module-level vars, following the
  # `softlinkHandle<Base>` naming convention, emitted ONLY when this block
  # declares a versionProbe — mirrors slice B6b's "no directive → no
  # const" precedent (provable via `declared()`; see
  # tests/tcheck_versionprobe_absent.nim). `softlinkLoadInProgress<Base>`
  # is a third, purely-internal var backing the reentrancy guard below —
  # gated the same way, since it would be meaningless without a probe (no
  # other user code ever runs inside loadX/unloadX, per the existing
  # no-thread-safety stance).
  if hasProbe:
    result.add(newNimNode(nnkVarSection).add(
      newNimNode(nnkIdentDefs).add(probedVersionName, ident("string"), newEmptyNode())))
    result.add(newNimNode(nnkVarSection).add(
      newNimNode(nnkIdentDefs).add(probeFailedName, ident("bool"), newEmptyNode())))
    result.add(newNimNode(nnkVarSection).add(
      newNimNode(nnkIdentDefs).add(loadInProgressName, ident("bool"), newEmptyNode())))

  proc probeNotRunFields(): seq[(string, NimNode)] =
    ## RFC-0001 §C.2, finding #11: the report shape that means "this
    ## block's probe (if any) has not run" — used at every site that needs
    ## the pre-first-load / post-Phase-1-early-fail / post-unloadX report:
    ## `atProbeNotRun` when this block declares a `versionProbe` (transient
    ## — a later successful-enough load overwrites it), or the bare
    ## zero-value `atNoProbe` when it doesn't (permanent — that block never
    ## writes any other attestation). A closure over `hasProbe`, mirroring
    ## `assignCompatReportStmt`'s own closure-over-`compatReportName` style.
    if hasProbe: @[("attestation", ident("atProbeNotRun"))]
    else: @[]

  # RFC-0001 §C.2, finding #11: correct `softlinkCompatReport<Base>`'s
  # initial value for a probe-bearing block — the bare var declaration
  # above already zero-initialized it to `atNoProbe`, which is right for a
  # probe-less block but WRONG here (a probe-bearing block that hasn't
  # loaded yet, or was just unloaded, must report `atProbeNotRun`, not the
  # permanent-structural `atNoProbe`). A probe-less block needs no such
  # correction and gets none — `probeNotRunFields()` returns `@[]` for it,
  # an idempotent no-op re-assignment of the same bare zero value.
  result.add(assignCompatReportStmt(probeNotRunFields()))

  # RFC-0001 §4 B.1: dump this block's probe facts (no-op unless
  # -d:softlinkDumpProbes=<dir> is given). `libPattern` (the macro's
  # as-typed argument), not `resolvedPattern` (the OS-expanded form), is
  # dumped — the same choice already made for `baseName` above, and for
  # the same reason (a single, OS-stable identity for the block).
  dumpProbeFacts("dynlib", body.lineInfoObj.filename, libPattern, baseName, procs, body)

  # Visibility for trust points (RFC-0001 principle 2: "anything unverified
  # is surfaced at compile time, never silent"): enumerate {.noverify.}
  # symbols so audits don't depend on grepping source. A hint in normal
  # builds, upgraded to a warning under -d:softlinkStrictVerify — audit mode
  # wants loudness, but an explicit opt-out must not fail the build.
  # verifyWhen procs get no diagnostic: their status is decided by the C
  # preprocessor and the pragma documents itself at the declaration site.
  # {.prototype.}-only procs (no {.header.}) do NOT appear here either — as
  # of slice A2 they ARE header-verified (against the vendored extern
  # declaration; see `genVerifyBlock`/`emitPrototypeDecl`), so listing them
  # as a trust hole would be actively wrong, not merely redundant. Before
  # A2 wired the emission, such procs were invisible in a different sense
  # (unverified yet also absent from this hint) — that gap is what A2 closes,
  # by making them genuinely verified rather than by adding them here.
  block:
    # RFC-0001 §3 A.2, slice A7: "the current parser already accepts and
    # silently discards the colon form — A7 makes it read the string. The
    # justification is folded into the existing unverified-symbols hint/
    # warning." Each entry renders as `name — "reason"` when a justification
    # was given, or `name — (no justification)` for bare {.noverify.} — bare
    # form stays legal (additive), per A.2.
    #
    # RFC 0011 S0a item 6: a proc whose `noVerify` came from the block-level
    # default (`noVerifyFromBlockDefault`) does NOT get its own entry in
    # `unverified` here — every such proc shares the SAME reason by
    # construction (the one block-level justification), so listing each by
    # name would be exactly the copy-paste-shaped noise item 6 exists to
    # collapse. They are counted and folded into ONE summary entry below
    # instead; a proc's OWN explicit `{.noverify.}` (with or without its own
    # reason) is entirely unaffected and keeps its individual entry, exactly
    # as before this slice. `totalUnverified` (not `unverified.len`) drives
    # the header count precisely so the header always reflects the true
    # number of unverified SYMBOLS, even though the block-defaulted ones
    # collapse to a single LISTING entry.
    var unverified: seq[string]
    var totalUnverified = 0
    var blockDefaultCount = 0
    var blockDefaultReason = ""
    for p in procs:
      if p.noVerify:
        inc totalUnverified
        if p.noVerifyFromBlockDefault:
          inc blockDefaultCount
          blockDefaultReason = p.noVerifyReason
        else:
          let reasonPart =
            if p.noVerifyReason.len > 0: "\"" & p.noVerifyReason & "\""
            else: "(no justification)"
          unverified.add(p.nameStr & " — " & reasonPart)
    if blockDefaultCount > 0:
      unverified.add($blockDefaultCount &
        (if blockDefaultCount == 1: " symbol" else: " symbols") &
        ", block-level reason: \"" & blockDefaultReason & "\"")
    if totalUnverified > 0:
      let msg = "softlink: dynlib \"" & libPattern & "\": " &
        $totalUnverified & (if totalUnverified == 1: " symbol" else: " symbols") &
        " not header-verified ({.noverify.}): " & unverified.join(", ")
      when defined(softlinkStrictVerify):
        warning(msg, body)
      else:
        hint(msg, body)

  # RFC 0011 S0b, work item (i)(e): the `trustedWrappers` compile-time
  # audit hint — same "trust points are visible" convention as the
  # `{.noverify.}` hint directly above (a HIGHER-severity trust point than
  # a bare noverify, since a trusted wrapper's failure mode is process
  # termination, not a catchable exception), enumerated once per block
  # (the directive is block-level, so every wrapper in the block is
  # trusted uniformly — there is no per-proc list to enumerate the way the
  # noverify hint's `unverified` seq has). Fires even when the block has
  # zero procs (an empty `dynlib` block with a stray `trustedWrappers` is
  # pathological but not itself an error) — `procs.len` is simply 0 then,
  # and the hint says so plainly rather than being suppressed.
  if trustedWrappersDirective.present:
    let reasonPart =
      if trustedWrappersDirective.reason.len > 0:
        "\"" & trustedWrappersDirective.reason & "\""
      else: "(no justification)"
    let msg = "softlink: dynlib \"" & libPattern & "\": " & $procs.len &
      (if procs.len == 1: " wrapper" else: " wrappers") &
      " trusted (trustedWrappers), reason: " & reasonPart &
      " — nil-pointer dispatch terminates the process instead of raising"
    when defined(softlinkStrictVerify):
      warning(msg, body)
    else:
      hint(msg, body)

  # RFC-0002 §4.1/§6, slice A3: another trust-point hint, same convention
  # as the {.noverify.} one directly above (precedent it explicitly names).
  # Required-symbol drift refusal unwinds the ENTIRE load (see the
  # required-symbol declared-bound-refusal path, softlink.nim:~1611 in the
  # RFC's numbering) — so a required proc carrying {.until.} takes every
  # other symbol in this block down with it once the probed version reaches
  # the bound, which is usually not what the author wants. `{.optional.}`
  # procs are exempt: their drift refusal only re-nils that one symbol.
  # Aggregated per block, enumerating every offending symbol, exactly like
  # the noverify hint — a hint in normal builds, a warning under
  # -d:softlinkStrictVerify (a required+until symbol is a HIGHER-severity
  # trust point than a bare noverify: it can silently take the whole block
  # down, not just leave one symbol unverified).
  block:
    var driftedRequired: seq[string]
    for p in procs:
      if p.untilVersion.len > 0 and not p.isOptional:
        driftedRequired.add(p.nameStr & " (until " & p.untilVersion & ")")
    if driftedRequired.len > 0:
      let msg = "softlink: dynlib \"" & libPattern & "\": " &
        $driftedRequired.len &
        (if driftedRequired.len == 1: " symbol" else: " symbols") &
        " drifted-but-required (" & driftedRequired.join(", ") &
        "): drifted-but-required symbols fail the whole load above " &
        "until; did you mean {.optional.}?"
      when defined(softlinkStrictVerify):
        warning(msg, body)
      else:
        hint(msg, body)

  # RFC-0002 §5/§6, slice E2: gate synthesis — MUST run before
  # `checkUntilRequiresGate` right below: a successfully-synthesized
  # predicate is assigned straight into `p.verifyWhen`, so that check sees
  # a satisfied gate and never fires for a proc this pass covered. See
  # `synthesizeVersionGates`'s own doc comment for the full scope rule
  # (until-carrying procs only, explicit verifyWhen always wins, no-op
  # without a versionMacros directive).
  synthesizeVersionGates(procs, versionMacrosDirective.present,
                          versionMacrosDirective.macroNames, "dynlib")

  # RFC-0002 §4.1/§5/§6, slice D1: `until` requires `verifyWhen` —
  # unconditional, post-body-scan (`procs` is fully collected by this
  # point), and deliberately called BEFORE `applyCompatManifest` just
  # below: unlike the since/until contradiction checks inside it (Check
  # 6/6b), this requirement does not depend on a `compatManifest` being
  # attached at all — see `checkUntilRequiresGate`'s own doc comment. Runs
  # AFTER synthesis just above, so a `versionMacros`-satisfied gate never
  # trips this check.
  checkUntilRequiresGate(procs, "dynlib")

  # Code-review finding CR1-12: a `versionMacros` directive nothing ended up
  # consuming (no `until` proc synthesized a gate from it) is a silent no-op
  # otherwise — hint the author, same post-synthesis timing as the check
  # just above. See `checkVersionMacrosConsumed`'s own doc comment for why
  # this stays a plain hint at every verify tier, unlike the noverify/
  # drifted-but-required hints above.
  checkVersionMacrosConsumed(procs, versionMacrosDirective.present,
                              versionMacrosDirective.macroNames, "dynlib",
                              versionMacrosDirective.node)

  # RFC-0001 §B.5, slice B6a: compile-time compat-manifest consumption —
  # no-op unless a `compatManifest` directive was found above. Must run
  # before `genVerifyBlock` so its `attached` bit (whether a manifest is
  # attached, ABI-ignored or not) can gate the degraded-tier warning.
  let appliedManifest = applyCompatManifest(ppmDynlib, baseNameLower, procs, manifestDirective)

  for verifyNode in genVerifyBlock(procs, baseName, appliedManifest.attached,
                                    versionMacrosDirective.headerName):
    result.add(verifyNode)

  # RFC-0001 §B.5/§9, slice B6b: embed the manifest's per-symbol interval
  # table as a module-level const, `softlinkCompatFacts<Base>:
  # seq[SymbolFacts]`, for Stage C's future load-time use — the pinned B0
  # types from `softlink/versions` are the contract between this producer
  # (v0.9.0) and Stage C's consumer (v0.10.0), pinned so the two cannot
  # drift apart independently. Only when a manifest is attached AND
  # survived the ABI check (`appliedManifest.attached`, the same bit
  # `genVerifyBlock` used just above): no manifest, or one degraded to
  # no-manifest behavior by an ABI mismatch, means NO const at all — an
  # empty-seq const would blur "no manifest" with "manifest with zero
  # symbols" (design guidance; also proven by
  # `tests/tcheck_manifest_facts_const_absent.nim` and
  # `tests/tcheck_manifest_facts_const_abi_ignored.nim`). `newLit` handles
  # the nested `array[FactKind, seq[VersionInterval]]` field shape fine —
  # verified directly before wiring this in. Unexported, like
  # `softlinkHandle<Base>` above: the sole consumer is generated code in
  # this same module (Stage C's runtime probe, not yet wired — this slice
  # only emits and statically-inspects the const, nothing reads it at
  # runtime yet).
  if appliedManifest.attached:
    let factsConstName = ident("softlinkCompatFacts" & baseName)
    let factsTypeNode = newNimNode(nnkBracketExpr).add(ident("seq"), ident("SymbolFacts"))
    let factsInit = newLit(appliedManifest.manifest.symbols)
    result.add(newNimNode(nnkConstSection).add(
      newNimNode(nnkConstDef).add(factsConstName, factsTypeNode, factsInit)
    ))

  # RFC-0001 §C.1/§C.3, slice C4b: symbols (any pragma kind — required OR
  # optional) whose header facts include ANY `mismatch` interval, per the
  # attached manifest. Feeds both the probe-body static scan just below
  # (every proc, since a probe dispatching a drift-mismatched REQUIRED
  # symbol is the same "probe must not be the drift" risk) and the
  # runtime refusal candidate list (`driftCandidates`, the OPTIONAL
  # subset — required-symbol refusal is C4c's territory). Empty when no
  # manifest is attached: nothing to check facts against.
  var mismatchCNames: HashSet[string]
  if appliedManifest.attached:
    for p in procs:
      let symOpt = findSymbol(appliedManifest.manifest, p.cName)
      if symOpt.isSome and symOpt.get.header[fkMismatch].len > 0:
        mismatchCNames.incl(p.cName)

  # RFC-0001 §C.1: the macro-time-only probe-body scan. No manifest
  # attached, no (well-formed) probe at all, or no symbol in this block
  # ever carries a mismatch fact: nothing to scan, matching the RFC's own
  # "no manifest -> no facts -> no scan" wording.
  if appliedManifest.attached and hasProbe and mismatchCNames.len > 0:
    discard scanProbeBodyForDriftCalls(versionProbeDirective.bodyStmts, mismatchCNames)

  # RFC-0001 §C.3, slice C4c: the refusal policy gate — "escape hatches,
  # scoped to who holds them". Absent or `refuse = true` on this block's
  # own `compatManifest` directive means refusal is enabled UNLESS the
  # build-wide `-d:softlinkNoDriftRefusal` override wins regardless (the
  # downstream-consumer knob always takes precedence over what the
  # binding author wrote, by construction: it's a build-wide `and not`).
  # Gating BOTH candidate-list computations below on this one flag is the
  # "cleanest degradation" the slice brief calls for: `refuse = false` (or
  # the build-wide define) means driftCandidates/requiredDriftCandidates
  # are simply never populated, so every downstream `.len > 0` check
  # degrades to emitting NO refusal code at all — not merely disabled at
  # runtime, but literally absent from the generated program.
  let driftRefusalEnabled = not softlinkNoDriftRefusal and
    not (manifestDirective.refuseGiven and not manifestDirective.refuse)

  # RFC-0001 §C.3, slice C4b/C4c: split `mismatchCNames` into its OPTIONAL
  # subset (`driftCandidates`, C4b) and REQUIRED subset
  # (`requiredDriftCandidates`, C4c) — the two runtime drift-refusal
  # candidate lists. Both require a probe (no probed version, no refusal
  # is ever possible) AND `driftRefusalEnabled` (see above) — empty
  # whenever any of those is false, even if the manifest has mismatch
  # facts on procs of the relevant kind, since there is either nothing to
  # compare them against yet or refusal is deliberately disabled for this
  # compile.
  var driftCandidates: seq[SoftlinkProc]
  var requiredDriftCandidates: seq[SoftlinkProc]
  if appliedManifest.attached and hasProbe and driftRefusalEnabled:
    for p in procs:
      if p.cName in mismatchCNames:
        if p.isOptional: driftCandidates.add(p)
        else: requiredDriftCandidates.add(p)
  var driftCandidateNames: HashSet[string]
  for p in driftCandidates: driftCandidateNames.incl(p.cName)
  for p in requiredDriftCandidates: driftCandidateNames.incl(p.cName)

  # RFC-0002 §4.4/§4.9, slice C4b/C4c: procs carrying a declared
  # `since`/`until` bound — candidates for the declared-bound refusal
  # fragment emitted into the two non-attested success sites below
  # (`atOutOfCorpus`, `atNoManifest`). Deliberately INDEPENDENT of
  # `appliedManifest.attached`/`mismatchCNames` (unlike `driftCandidates`
  # above, which is keyed on attested manifest facts) — §4.4's whole point
  # is refusing off the AUTHOR'S declaration where manifest facts can't
  # decide, including the manifest-less `atNoManifest` site. Gated only on
  # `hasProbe` (nothing to compare a bound against without a probed
  # version) and `driftRefusalEnabled` (the same escape hatches
  # `driftCandidates`/`requiredDriftCandidates` honor — "absent, not
  # merely disabled", same degradation argument). Split into the OPTIONAL
  # subset (`declaredBoundOptionalCandidates`, C4b: re-nil + continue) and
  # the REQUIRED subset (`declaredBoundRequiredCandidates`, C4c: unwind the
  # whole load) — mirrors the attested `driftCandidates`/
  # `requiredDriftCandidates` split above exactly.
  var declaredBoundOptionalCandidates: seq[SoftlinkProc]
  var declaredBoundRequiredCandidates: seq[SoftlinkProc]
  if hasProbe and driftRefusalEnabled:
    for p in procs:
      if p.sinceVersion.len > 0 or p.untilVersion.len > 0:
        if p.isOptional: declaredBoundOptionalCandidates.add(p)
        else: declaredBoundRequiredCandidates.add(p)
  for p in declaredBoundOptionalCandidates: driftCandidateNames.incl(p.cName)
  for p in declaredBoundRequiredCandidates: driftCandidateNames.incl(p.cName)

  # RFC-0002 §4.4, code-review finding CR1-1 (Critical): the ATTESTED
  # path's own subset of the two lists above — bounded procs that are ALSO
  # ABSENT from the attached manifest's own symbol table
  # (`findSymbol(...).isNone`). `checkUntil`/`checkSince` (softlink/manifest)
  # vacuous-pass on a symbol absent from the manifest (nothing recorded to
  # check the declared bound against), and the attested branch below
  # (`attestedStmts`) otherwise refuses ONLY off the manifest's own
  # `fkMismatch` facts (`mismatchCNames`, built above from symbols PRESENT
  # in the manifest) — so, before this fix, a bounded proc absent from the
  # manifest got ZERO declared-bound enforcement even when the probe
  # attested an in-corpus version at-or-above its declared bound. Bounded
  # procs PRESENT in the manifest are the opposite case: `checkUntil`
  # (directives.nim Check 6b) already validated THOSE against the corpus at
  # compile time, so re-checking them here on the attested path would be
  # pure redundancy — they stay exempt, unchanged from C4b/C4c (existing
  # fixtures, e.g. `testlib_gated` at an attested in-window version,
  # depend on this exemption).
  #
  # Computed only when a manifest is attached (`findSymbol` needs one); the
  # `atNoManifest`/`atOutOfCorpus` sites below keep iterating the FULL
  # `declaredBoundOptionalCandidates`/`declaredBoundRequiredCandidates`
  # lists, unaffected by this addition.
  var declaredBoundOptionalCandidatesAbsent: seq[SoftlinkProc]
  var declaredBoundRequiredCandidatesAbsent: seq[SoftlinkProc]
  if appliedManifest.attached:
    for p in declaredBoundOptionalCandidates:
      if findSymbol(appliedManifest.manifest, p.cName).isNone:
        declaredBoundOptionalCandidatesAbsent.add(p)
    for p in declaredBoundRequiredCandidates:
      if findSymbol(appliedManifest.manifest, p.cName).isNone:
        declaredBoundRequiredCandidatesAbsent.add(p)

  # RFC-0001 §C.3, slice C4b design guidance (extended by C4c to the
  # required subset too; RFC-0002 §4.4 slice C4b extends it again to
  # declared-bound refusal): one drift-story seq per block —
  # `softlinkDriftStories<Base>: seq[tuple[symbol, story: string]]` —
  # populated at refusal time inside loadXxx below, scanned (linearly,
  # error-path only) by the wrapper's nil-pointer branch, and reset by
  # unloadXxx. Zero footprint when nothing could ever be refused (every
  # candidate list empty): gated on the ACTUAL refusal-candidate lists,
  # not merely `appliedManifest.attached`, since a manifest with mismatch
  # facts but no probe, or `refuse = false`/`-d:softlinkNoDriftRefusal`,
  # generates no refusal code at all and would leave this var write-only.
  let driftStoriesName = ident("softlinkDriftStories" & baseName)
  if driftCandidates.len > 0 or requiredDriftCandidates.len > 0 or
     declaredBoundOptionalCandidates.len > 0 or
     declaredBoundRequiredCandidates.len > 0:
    result.add(newNimNode(nnkVarSection).add(
      newNimNode(nnkIdentDefs).add(
        driftStoriesName,
        seqOfTupleType([("symbol", "string"), ("story", "string")]),
        newEmptyNode()
      )
    ))

  # Wrapper procs — RFC-0001 §9/§C.1, slice C1a: emitted here, BEFORE loadXxx,
  # so a future `versionProbe:` body spliced into loadXxx (slice C1b) can call
  # the block's own wrappers without a use-before-declaration error at the Nim
  # top level. Pure codegen reorder: no wrapper here references anything
  # loadXxx defines (temp syms, missing-seq, etc.), so this move is invisible
  # to every existing caller — loadXxx never calls a wrapper today.
  #
  # RFC 0011 S0a item 4: walks `orderedItems` — the SAME source order `body`
  # was written in — instead of batching every wrapper after a separate
  # pass-through emission. This is the empirically-required fix for
  # general statement pass-through: a passed-through helper calling a
  # binding's wrapper is only a legal, ordinary Nim top-level forward
  # reference when the wrapper is emitted at the binding's own source
  # position (a helper may call any binding declared ABOVE it — the same
  # rule that already governs two hand-written top-level procs; see
  # tests/tfail_passthrough_forward_ref.nim for the direction that stays
  # refused). Confirmed by direct experiment before implementing: two
  # macro-spliced top-level procs, and separately two ordinary hand-written
  # ones, both hit "undeclared identifier" for a forward call with no
  # forward declaration — Nim grants macro output no special forward-
  # reference tolerance beyond what hand-written code already gets, so
  # batching (the pre-item-4 shape) would have made a passed-through
  # helper's forward-reference behavior depend on codegen internals
  # instead of the author's own source order.
  for item in orderedItems:
    case item.kind
    of diPassthrough:
      result.add(item.stmt)
    of diBinding:
      let p = procs[item.procIdx]
      # RFC 0011 S0a item 3: the C symbol, not the Nim name — this literal
      # feeds `raiseNotLoaded`/`raiseDriftRefused` (both runtime-facing,
      # user-visible in `SoftlinkError.msg`) and `findDriftStory`'s lookup
      # into `softlinkDriftStories<Base>` (itself keyed on `p.cName`, see
      # the drift-story construction sites below) — all key on the C
      # symbol per the RFC ("all runtime-facing reporting... key on the C
      # symbol, not the Nim name").
      let cNameLit = newStrLitNode(p.cName)

      # Build arg list for forwarding call
      var callNode = newCall(p.ptrName)
      for i in 1 ..< p.formalParams.len:
        let identDefs = p.formalParams[i]
        for j in 0 ..< identDefs.len - 2:
          callNode.add(identDefs[j].copy())

      # nil check + call
      var wrapperBody = newStmtList()
      # RFC-0001 §C.3, slice C4b design guidance: for a symbol eligible for
      # drift refusal (`p.cName in driftCandidateNames` — always false,
      # hence a no-op addition, when this block has no such symbol), check
      # `softlinkDriftStories<Base>` FIRST: a hit means this pointer was
      # resolved once and then re-nilled for known drift, and the wrapper
      # must report the FULL drift story, not the generic "not loaded"
      # message. A miss (never refused, or refused-but-not-THIS-symbol)
      # falls through to the unchanged not-loaded diagnostic below.
      #
      # RFC 0011 S0b, work item (i): `trustedWrappersDirective.present`
      # (captured from the outer macro scope, uniform for every wrapper in
      # this block — `trustedWrappers` is a block-level directive, not a
      # per-proc pragma) selects between the two diagnostic-DELIVERY
      # mechanisms below; the diagnostic TEXT itself is identical either
      # way (the same drift story, the same "<library>: library not
      # loaded, cannot call: <symbol>" message `raiseNotLoaded` builds) —
      # only whether it reaches the caller via a catchable `raise` or via
      # `softlinkFatal`'s terminate-the-process sinks changes.
      var nilBranch = newStmtList()
      if p.cName in driftCandidateNames:
        let storySym = genSym(nskLet, "driftStory")
        nilBranch.add(newLetStmt(storySym,
          newCall(bindSym("findDriftStory"), driftStoriesName, cNameLit)))
        let driftReportStmt =
          if trustedWrappersDirective.present:
            newCall(ident("softlinkFatal"), storySym)
          else:
            newCall(ident("raiseDriftRefused"), libPatternLit, cNameLit, storySym)
        nilBranch.add(newIfStmt((
          newNimNode(nnkInfix).add(ident(">"), newDotExpr(storySym, ident("len")), newIntLitNode(0)),
          newStmtList(driftReportStmt)
        )))
      if trustedWrappersDirective.present:
        # Same message `raiseNotLoaded` (src/softlink.nim) builds at
        # runtime from these two literals — spelled out here directly
        # since `softlinkFatal` takes the already-formatted diagnostic
        # string, not a (library, symbol) pair the way `raiseNotLoaded`
        # does. Plain string `&` carries no exception effect Nim's checker
        # tracks (only an unrecoverable Defect on allocation failure, which
        # `{.raises: [].}` does not need to name), so building it inline
        # here does not disturb the trusted wrapper's own `{.raises: [].}`
        # pragma below.
        nilBranch.add(newCall(ident("softlinkFatal"),
          infix(infix(libPatternLit, "&", newStrLitNode(": library not loaded, cannot call: ")),
                "&", cNameLit)))
      else:
        nilBranch.add(newCall(ident("raiseNotLoaded"), libPatternLit, cNameLit))
      wrapperBody.add(newIfStmt((
        newCall(ident("isNil"), p.ptrName),
        nilBranch
      )))

      if p.hasReturn:
        wrapperBody.add(newNimNode(nnkReturnStmt).add(callNode))
      else:
        wrapperBody.add(callNode)

      var params: seq[NimNode]
      for i in 0 ..< p.formalParams.len:
        params.add(p.formalParams[i].copy())

      var wrapperProc = newProc(
        name = postfix(p.name.copy(), "*"),
        params = params,
        body = wrapperBody,
      )
      # RFC 0011 S0b, work item (i)(f): a trusted wrapper is genuinely
      # `{.raises: [].}` — checked by Nim's effect system at every call
      # site, not merely documented — since its nil branch now calls
      # `softlinkFatal` (itself `{.noreturn, raises: [].}`, `softlink/
      # fatal.nim`) instead of raising `SoftlinkError`. Untrusted wrappers
      # (the overwhelming majority, and every wrapper before this RFC)
      # keep the unchanged `{.raises: [SoftlinkError].}`.
      let wrapperRaisesBracket =
        if trustedWrappersDirective.present: newNimNode(nnkBracket)
        else: newNimNode(nnkBracket).add(ident("SoftlinkError"))
      wrapperProc.addPragma(newNimNode(nnkExprColonExpr).add(
        ident("raises"), wrapperRaisesBracket
      ))
      result.add(wrapperProc)

      # xxxAvailable*(): bool for optional symbols
      if p.isOptional:
        let availName = ident(p.nameStr & "Available")
        result.add(newProc(
          name = postfix(availName, "*"),
          params = [ident("bool")],
          body = newStmtList(prefix(newCall(ident("isNil"), p.ptrName), "not")),
        ))

      # xxxPtr*(): proc type — typed function pointer for C callback passing.
      # Returns the dlsym'd pointer directly (nil if not loaded). No nil
      # check — the load function is the single enforcement point.
      # Return type matches the function pointer variable's type (cdecl + raises: [])
      # so callers get type safety without the wrapper's SoftlinkError raises.
      let ptrAccessorName = ident(p.nameStr & "Ptr")
      var ptrReturnType = newNimNode(nnkProcTy)
      ptrReturnType.add(p.formalParams.copy())
      ptrReturnType.add(newNimNode(nnkPragma).add(
        ident(p.callConv),
        newNimNode(nnkExprColonExpr).add(
          ident("raises"), newNimNode(nnkBracket)
        )
      ))
      var ptrAccessorProc = newProc(
        name = postfix(ptrAccessorName, "*"),
        params = [ptrReturnType],
        body = newStmtList(p.ptrName),
      )
      ptrAccessorProc.addPragma(newNimNode(nnkExprColonExpr).add(
        ident("raises"),
        newNimNode(nnkBracket)
      ))
      result.add(ptrAccessorProc)

  # RFC-0001 §9/§C.1: a versionProbe body may legitimately call the block's
  # own `loadX`/`unloadX` (the reentrancy guard below must reject the
  # attempt, but rejecting still requires the CALL to type-check in the
  # first place). The probe's OWN statements are emitted as a separate
  # top-level proc below (`probeProcSym`), positioned BEFORE `loadX` itself
  # — so, unlike the wrapper-before-load reorder C1a made (where a
  # self-recursive `loadX` call from ITS OWN body needs no forward decl),
  # a call to `loadX`/`unloadX` from WITHIN the probe proc needs both
  # forward-declared here first. Real bodies for both still follow below,
  # unchanged.
  if hasProbe:
    result.add(newProc(name = postfix(loadProcName, "*"),
                        params = [ident("LoadResult")], body = newEmptyNode()))
    result.add(newProc(name = postfix(unloadProcName, "*"), body = newEmptyNode()))

    # RFC-0001 §9/§C.1: the probe's own statements are emitted as a
    # dedicated proc returning `string`, called (once) from inside loadX
    # below — NOT spliced directly as a `block: <stmts>` EXPRESSION.
    # Empirically, Nim cannot infer a type for a bare `block:` whose ONLY
    # content is a `raise` (`Error: ... has no type (or is ambiguous)`,
    # verified directly) — exactly the shape a "deliberately-raising
    # probe" (this slice's own test suite requires one) produces. An
    # ordinary proc with a DECLARED return type has no such problem: Nim
    # already accepts a proc body whose sole statement is `raise` (its
    # return type comes from the signature, not from inferring a common
    # type across the body), so routing through a real proc sidesteps the
    # block-expression inference gap entirely.
    result.add(newProc(
      name = probeProcSym,
      params = [ident("string")],
      body = versionProbeDirective.bodyStmts.copy()
    ))

  # loadXxx*(): LoadResult
  block:
    var hasOptional = false
    for p in procs:
      if p.isOptional: hasOptional = true; break

    # RFC-0002 §4.9, slice C4a: the ONE canonical declared-bounds
    # embedding for C1 (classification) and C2 (report intervals). Replaces
    # the old optional-only `sinceCNames`/`sinceVersions` build (formerly
    # nested inside `if hasOptional:`, scoped to `p.isOptional and
    # p.sinceVersion.len > 0`): three parallel macro-time `seq[string]`s —
    # `boundCNames`/`boundSinceVersions`/`boundUntilVersions` — covering
    # EVERY proc in this block carrying a `since` and/or `until` claim
    # (required or optional), built UNCONDITIONALLY (not gated on
    # `hasOptional`), so C1 and C2 both filter the SAME data instead of
    # each growing its own copy of this collection loop.
    #
    # Code-review finding CR1-6: this is NOT also C4's collection loop.
    # C4's own candidate lists (`declaredBoundOptionalCandidates`/
    # `declaredBoundRequiredCandidates`, built earlier, above) are a
    # SEPARATE scan over `procs` with the identical
    # `p.sinceVersion.len > 0 or p.untilVersion.len > 0` predicate, and
    # deliberately stay separate rather than being derived from (or
    # merged with) this one: (1) gating differs — this loop is
    # unconditional (`computeMissingPartition`'s absence classification is
    # independent of drift-refusal policy), while C4's lists are built
    # only `if hasProbe and driftRefusalEnabled`; a single merged loop
    # would have to pick ONE of the two gatings, wrongly coupling C1/C2's
    # unconditional classification data to C4's refusal-policy gate (or,
    # the other way round, coupling C4's refusal candidates to C1/C2's
    # unconditional one) — so the two scans stay separate instead; (2)
    # shape differs — C4's refusal codegen
    # (`declaredBoundRefusalStmts`) needs the full `SoftlinkProc` (`ptrName`,
    # `isOptional`, etc.) to emit per-symbol runtime checks, not the flat
    # `string` triples `computeMissingPartition` consumes via
    # `newLit(seq[string])`. Deliberately kept as plain parallel arrays
    # rather than a `seq[tuple]` — matches the shape `computeMissingPartition`
    # below already consumes via `newLit(seq[string])`, and matches the ~6
    # `assignCompatReportStmt`/`reportFields` call sites' own existing
    # parallel-field style; the `seq[tuple]` refactor is a known,
    # consciously deferred cleanup (§4.9), not an oversight. `""` in
    # `boundSinceVersions`/`boundUntilVersions` means "this proc's OTHER
    # bound only" (mirrors `SoftlinkProc.sinceVersion`/`.untilVersion`'s
    # own "" == absent convention) — a proc with only `until` still gets a
    # `boundCNames` row so a future `until`-only consumer has one to find.
    # Including REQUIRED procs and until-only procs is behavior-preserving
    # for THIS slice's sole consumer (`computeMissingPartition` below):
    # its lookup only ever probes names already in `softlinkMissing`, which
    # never contains a required symbol on a successful load (Phase 1 fails
    # the whole load first) — the widened rows are simply never matched.
    var boundCNames: seq[string] = @[]
    var boundSinceVersions: seq[string] = @[]
    var boundUntilVersions: seq[string] = @[]
    for p in procs:
      if p.sinceVersion.len > 0 or p.untilVersion.len > 0:
        boundCNames.add(p.cName)
        boundSinceVersions.add(p.sinceVersion)
        boundUntilVersions.add(p.untilVersion)

    # RFC-0001 §C.3, slice C4c: every proc's own pointer var in this block,
    # for a required-refusal unwind's `resetPtrs` — a required refusal walks
    # back the ENTIRE load (mirroring unloadX's own per-proc reset loop),
    # not just the one drifted symbol's pointer. Built once, here, ahead of
    # BOTH `declaredBoundRefusalStmts()` (below, C4c's non-attested unwind)
    # and the attested `requiredDriftCandidates` loop (further below) — the
    # two required-refusal shapes share this exact same array.
    var allPtrNames: seq[NimNode] = @[]
    for p in procs: allPtrNames.add(p.ptrName)

    var loadBody = newStmtList()
    let missingName = ident("softlinkMissing")

    # RFC-0002 §4.4/§4.9, slice C4b/C4c (extended by CR1-1's attested-path
    # fix): the ONE shared declared-bound-refusal codegen fragment, called
    # from THREE sites below — the `atNoManifest` probe-succeeded arm, the
    # `atAttested` branch, and the `atOutOfCorpus` branch (search
    # `declaredBoundRefusalStmts(` to find all three) — a closure over
    # `declaredBoundOptionalCandidates`/`declaredBoundRequiredCandidates`
    # (both computed once, above, alongside `driftCandidates`/
    # `requiredDriftCandidates`), `missingName`, `driftStoriesName`,
    # `allPtrNames`, and `probedVersionName`, exactly like
    # `unwindStmt`/`assignCompatReportStmt` close over their own outer
    # locals. `atNoManifest` and `atAttested`/`atOutOfCorpus` are mutually
    # exclusive at macro-expansion time (the `hasProbe`/
    # `appliedManifest.attached` macro-time `if/elif/else` picks exactly
    # one of those two shapes), but WITHIN the attached-manifest shape both
    # `atAttested` and `atOutOfCorpus` call this proc — two calls in the
    # SAME macro expansion, since the runtime `corpusIf`/`else` branching
    # they emit into is not a macro-time choice. This is safe because each
    # call mints its OWN `genSym`'d `partitionSym`/`notComparableSym`
    # (internal to this proc — see the returned `reportFields` below) —
    # multiple emissions per expansion never collide, whether that is the
    # attached shape's two calls or any future site added here.
    #
    # Per §4.4's comparison rule: for each candidate's `until` (if any) and
    # `since` (if any) independently, `versions.compareToBound(probed,
    # bound)` — NOT raw `cmpVersion` (module doc: alpha-suffix pre-release
    # ordering would invert the flagship distro-suffix case). A decisive
    # `until` result (`isSome` and `>= 0`, i.e. at-or-above `until`) OR a
    # decisive `since` result (`isSome` and `< 0`, i.e. below `since`)
    # refuses the symbol — both bounds get the same rigor (§4.4 "both
    # bounds, same check" symmetry). A `none` result from EITHER
    # comparison never refuses on its own; it sets the shared
    # `notComparableSym` flag instead (report-don't-block for that
    # boundary tie/unparseable probe) — independent per bound, so one
    # candidate's ambiguous `since` check doesn't suppress another
    # candidate's decisive `until` refusal. This comparison logic
    # (`buildBoundCheck` below) is shared verbatim between the required
    # and optional loops — required/optional differ ONLY in the terminal
    # action once a hit is decided, exactly mirroring how the attested
    # `driftCandidates`/`requiredDriftCandidates` loops share the
    # `firstMismatchInterval` shape but differ in what happens on a hit.
    #
    # An already-nil pointer (Phase 2's concern — genuinely absent at
    # runtime) is skipped by construction (`if not isNil(p.ptrName)`),
    # exactly like the attested `driftCandidates` loop above — no
    # double-count with `computeMissingPartition`'s own `mrAnomalous`/
    # `mrExpected` classification of that same absence. (For a REQUIRED
    # candidate this guard is always-true by construction — Phase 1
    # guarantees every required symbol resolved before this point ever
    # runs, the same reasoning the attested `requiredDriftCandidates` loop
    # already documents — so it is kept only for uniformity with the
    # shared helper, not because it can fire.)
    #
    # OPTIONAL refusal action mirrors the attested loop's shape (re-nil the
    # pointer, add to `missing`, stash a drift story so the wrapper raises
    # it instead of the generic "not loaded" message, keep classifying the
    # rest of the block). REQUIRED refusal (C4c) instead unwinds the WHOLE
    # load via `unwindStmt`'s third shape (mirror of `requiredDriftCandidates`,
    # `resetPtrs = allPtrNames`, `resetProbeState = true`) — symmetry with
    # the attested required/optional split. Both source their
    # `VersionInterval` from the proc's own DECLARED `since`/`until` (§4.9's
    # declared-bound evidence-interval leg — there is no manifest-confirmed
    # `firstMismatchInterval` at either of these two sites) and use
    # distinct wording ("declared valid only at", not "per compat manifest") —
    # §4.4's consumer-disambiguation guarantee: `report.attestation`
    # (`atOutOfCorpus`/`atNoManifest` vs `atAttested`) crossed with the
    # `mrDriftRefused` entry already tells the two stories apart; the
    # wording difference is a second, belt-and-suspenders cue.
    #
    # `attestationIdent` is the call site's own `Attestation` value
    # (`atOutOfCorpus`/`atNoManifest`) — needed here (unlike the optional-
    # only shape) because a REQUIRED hit builds and returns its OWN
    # `CompatReport` via `unwindStmt`, bypassing the caller's own
    # `assignCompatReportStmt` entirely. `priorMissingField` is the
    # caller's already-computed C3 `missingReasons` NimNode (the
    # `atOutOfCorpus` site's `missingPartitionFields[0][1]` when
    # `hasOptional`, mirroring the attested required loop's own
    # `reqMissingSym` merge) to fold into a required hit's report, or
    # `nil` when there is none to fold in (always `nil` at `atNoManifest`
    # — §4.4: "there is no facts-driven partition to compute" there).
    #
    # Code-review finding R2-C: this fragment owns BOTH halves of the
    # report-merge seam, not just the refusal statements. `priorMissingField`
    # is folded with this call's own `partitionSym` ONCE, here (`&` when
    # non-nil, `partitionSym` alone otherwise), and the result is returned
    # pre-packaged as `reportFields = @[("missingReasons", <merged>),
    # ("probeNotComparable", notComparableSym)]` — the exact two fields
    # every one of the three call sites needs for its OWN success-path
    # `assignCompatReportStmt`. Each site now just splices `reportFields`
    # in (`.add` at the `atNoManifest` site, which grows an existing field
    # seq; a plain `=` at the other two, which fully replace theirs) instead
    # of re-deriving the same fold-then-append shape three times.
    #
    # `requiredCandidates`/`optionalCandidates` (code-review finding CR1-1):
    # the two candidate lists to iterate, taken as explicit params rather
    # than closing over `declaredBoundRequiredCandidates`/
    # `declaredBoundOptionalCandidates` directly — the `atNoManifest`/
    # `atOutOfCorpus` call sites below pass those FULL lists (unchanged
    # behavior), while the new attested-path call site passes their
    # manifest-absent SUBSETS (`declaredBoundRequiredCandidatesAbsent`/
    # `declaredBoundOptionalCandidatesAbsent`, computed above) — the one
    # shared fragment now serves three call sites with three different
    # candidate scopes.
    proc declaredBoundRefusalStmts(attestationIdent: NimNode,
        priorMissingField: NimNode,
        requiredCandidates, optionalCandidates: seq[SoftlinkProc]
        ): tuple[stmts: NimNode, reportFields: seq[(string, NimNode)]] =
      let partitionSym = genSym(nskVar, "declaredBoundRefused")
      let notComparableSym = genSym(nskVar, "declaredBoundNotComparable")
      var stmts = newStmtList()
      stmts.add(newNimNode(nnkVarSection).add(newNimNode(nnkIdentDefs).add(
        partitionSym,
        newNimNode(nnkBracketExpr).add(ident("seq"), bindSym("MissingReasonEntry")),
        newEmptyNode())))
      stmts.add(newNimNode(nnkVarSection).add(newNimNode(nnkIdentDefs).add(
        notComparableSym, ident("bool"), newEmptyNode())))
      # Takes `sinceStr`/`untilStr` as plain VALUE params (never captures
      # the `for p in ...` loop variable below) — `p` is a `lent
      # SoftlinkProc` (the default `seq` `items` iterator), and Nim
      # forbids capturing a `lent` value into a closure (memory-safety
      # error, hit empirically during this slice's own TDD cycle: "'p' is
      # of type <lent SoftlinkProc> which cannot be captured"). Copying
      # the two string fields out at each call site sidesteps the whole
      # class of error.
      proc declaredIvNode(sinceStr, untilStr: string): NimNode =
        newNimNode(nnkObjConstr).add(
          bindSym("VersionInterval"),
          newNimNode(nnkExprColonExpr).add(ident("lo"), newStrLitNode(sinceStr)),
          newNimNode(nnkExprColonExpr).add(ident("hi"), newStrLitNode(untilStr)))

      # Shared comparison/decision AST, used by BOTH loops below — same
      # value-param convention as `declaredIvNode` above, same reason.
      #
      # Code-review finding CR1-4: the refuse/not-comparable decision
      # itself no longer lives here as hand-assembled NimNode trees — it's
      # `versions.evaluateBoundRefusal` (a plain, directly unit-tested
      # proc, house style per `directives.nim`'s doc comment: every
      # sibling decision — `checkUntil`, `classifyAbsence`, `synthesizeGate`,
      # `compareToBound` — is a pure proc merely SEQUENCED by macro code).
      # This proc now only binds the runtime call and destructures its
      # result into the two module-level flag vars (`refuseSym`, shared
      # `notComparableSym`) the rest of the codegen below already expects.
      proc buildBoundCheck(sinceStr, untilStr: string): tuple[checkStmts, refuseSym: NimNode] =
        let refuseSym = genSym(nskVar, "declaredBoundRefuse")
        let evalSym = genSym(nskLet, "declaredBoundEval")
        var checkStmts = newStmtList()
        checkStmts.add(newLetStmt(evalSym, newCall(bindSym("evaluateBoundRefusal"),
          probedVersionName, newStrLitNode(sinceStr), newStrLitNode(untilStr))))
        checkStmts.add(newVarStmt(refuseSym, newDotExpr(evalSym, ident("refuse"))))
        checkStmts.add(newIfStmt((
          newDotExpr(evalSym, ident("notComparable")),
          newStmtList(newAssignment(notComparableSym, newLit(true))))))
        (checkStmts, refuseSym)

      proc declaredStoryExpr(cName, sinceStr, untilStr: string): NimNode =
        newNimNode(nnkInfix).add(ident("&"),
          newNimNode(nnkInfix).add(ident("&"),
            newStrLitNode(cName & ": signature drift, declared valid only at "),
            newCall(bindSym("formatInterval"), declaredIvNode(sinceStr, untilStr))),
          newStrLitNode("; refusing unsafe dispatch"))

      # RFC-0002 §4.4, slice C4c: REQUIRED candidates checked FIRST —
      # mirrors the attested loop's own required-then-optional ordering
      # and "first hit wins" (a hit `return`s via `unwindStmt`, so any
      # later check in program order simply never runs).
      for p in requiredCandidates:
        let symNameLit = newStrLitNode(p.cName)
        let (checkStmts, refuseSym) = buildBoundCheck(p.sinceVersion, p.untilVersion)
        let versionSnapshotSym = genSym(nskLet, "declBoundReqVersion")
        let reqMissingSym = genSym(nskVar, "declBoundReqMissing")
        var hitStmts = newStmtList()
        # Snapshot BEFORE unwindStmt's resetProbeState=true clears
        # `probedVersionName` — same ordering requirement `unwindStmt`'s
        # own doc comment and the attested required loop already document.
        hitStmts.add(newLetStmt(versionSnapshotSym, probedVersionName))
        hitStmts.add(newCall(newDotExpr(driftStoriesName, ident("add")),
          newNimNode(nnkTupleConstr).add(
            newNimNode(nnkExprColonExpr).add(ident("symbol"), symNameLit),
            newNimNode(nnkExprColonExpr).add(ident("story"),
              declaredStoryExpr(p.cName, p.sinceVersion, p.untilVersion)))))
        hitStmts.add(newNimNode(nnkVarSection).add(newNimNode(nnkIdentDefs).add(
          reqMissingSym,
          newNimNode(nnkBracketExpr).add(ident("seq"), bindSym("MissingReasonEntry")),
          newEmptyNode())))
        if not priorMissingField.isNil:
          hitStmts.add(newAssignment(reqMissingSym, priorMissingField))
        hitStmts.add(newCall(newDotExpr(reqMissingSym, ident("add")),
          newNimNode(nnkTupleConstr).add(
            newNimNode(nnkExprColonExpr).add(ident("symbol"), symNameLit),
            newNimNode(nnkExprColonExpr).add(ident("reason"), ident("mrDriftRefused")),
            newNimNode(nnkExprColonExpr).add(ident("interval"),
              declaredIvNode(p.sinceVersion, p.untilVersion)))))
        hitStmts.add(unwindStmt(
          unloadHandle = true,
          resultKind = ident("lrSymbolNotFound"),
          resultFields = @[("symbol", symNameLit)],
          reportFields = @[
            ("runtimeVersion", versionSnapshotSym),
            ("attestation", attestationIdent),
            ("missingReasons", reqMissingSym)],
          resetPtrs = allPtrNames,
          resetProbeState = true))
        checkStmts.add(newIfStmt((refuseSym, hitStmts)))
        stmts.add(newIfStmt((
          prefix(newCall(ident("isNil"), p.ptrName), "not"),
          checkStmts)))

      # OPTIONAL candidates: re-nil the pointer and keep classifying
      # (unchanged shape from C4b).
      for p in optionalCandidates:
        let symNameLit = newStrLitNode(p.cName)
        let (checkStmts, refuseSym) = buildBoundCheck(p.sinceVersion, p.untilVersion)

        var refuseStmts = newStmtList()
        refuseStmts.add(newAssignment(p.ptrName, newNilLit()))
        refuseStmts.add(newCall(newDotExpr(missingName, ident("add")), symNameLit))
        refuseStmts.add(newCall(newDotExpr(driftStoriesName, ident("add")),
          newNimNode(nnkTupleConstr).add(
            newNimNode(nnkExprColonExpr).add(ident("symbol"), symNameLit),
            newNimNode(nnkExprColonExpr).add(ident("story"),
              declaredStoryExpr(p.cName, p.sinceVersion, p.untilVersion)))))
        refuseStmts.add(newCall(newDotExpr(partitionSym, ident("add")),
          newNimNode(nnkTupleConstr).add(
            newNimNode(nnkExprColonExpr).add(ident("symbol"), symNameLit),
            newNimNode(nnkExprColonExpr).add(ident("reason"), ident("mrDriftRefused")),
            newNimNode(nnkExprColonExpr).add(ident("interval"),
              declaredIvNode(p.sinceVersion, p.untilVersion)))))
        checkStmts.add(newIfStmt((refuseSym, refuseStmts)))

        stmts.add(newIfStmt((
          prefix(newCall(ident("isNil"), p.ptrName), "not"),
          checkStmts)))

      # Code-review finding R2-C: fold `priorMissingField` (the caller's
      # already-computed C3/attested-drift partition, or `nil` when there
      # is none) with THIS call's own `partitionSym` exactly once, here,
      # and hand back the two report fields every call site needs —
      # rather than each of the three call sites re-deriving this same
      # fold-then-append shape itself.
      let missingNode =
        if priorMissingField.isNil: partitionSym
        else: newNimNode(nnkInfix).add(ident("&"), priorMissingField, partitionSym)
      (stmts, @[("missingReasons", missingNode),
                ("probeNotComparable", notComparableSym)])

    # RFC-0001 §9/§C.1: reentrancy guard — must run BEFORE the idempotent
    # handle-check below. By the time a versionProbe body could call
    # loadX again, `handle` is already non-nil (assigned further down in
    # THIS very call, well before Phase 3/the probe runs) but
    # `cachedResult` has not yet been written for THIS load — so the
    # ordinary idempotent check below would return a FABRICATED default
    # LoadResult (the zero-value `lrOk`) before real classification ever
    # ran. Checking the load-in-progress flag first turns that into a
    # raised SoftlinkError instead, which the probe's own try/except
    # (spliced in below, after Phase 3) converts to a failed probe — the
    # caller that triggered the ORIGINAL, non-reentrant loadX call still
    # gets a real, correctly-classified LoadResult.
    if hasProbe:
      loadBody.add(newIfStmt((
        loadInProgressName,
        newStmtList(reentrancyRaiseStmt("load" & baseName))
      )))

    # if not handle.isNil: return cachedResult
    loadBody.add(newIfStmt((
      prefix(newCall(ident("isNil"), handleName), "not"),
      newStmtList(newNimNode(nnkReturnStmt).add(cachedResultName))
    )))

    # #20: past the idempotent-cache gate above, this is a genuine fresh
    # load ATTEMPT (first-ever load, or a retry after a prior attempt
    # unwound `handle` back to nil — e.g. a required-symbol drift refusal,
    # C4c). Reset `softlinkDriftStories<Base>` here so a run of repeated
    # failed loadXxx() calls can't accumulate one stale entry per attempt
    # forever; unloadXxx (below) resets the same seq for the "explicitly
    # unloaded" path, so between the two, the seq only ever holds stories
    # from the CURRENT attempt. Guarded on the same condition as the var's
    # own declaration above — a no-op statement would otherwise reference a
    # var that was never declared when neither candidate list is populated.
    if driftCandidates.len > 0 or requiredDriftCandidates.len > 0 or
       declaredBoundOptionalCandidates.len > 0 or
       declaredBoundRequiredCandidates.len > 0:
      loadBody.add(newAssignment(driftStoriesName, prefix(newNimNode(nnkBracket), "@")))

    # Per-block pattern-override seam: resolve the pattern actually PASSED
    # to the loader this call — the compile-time override (`<base>
    # PatternOverride` above, set via `-d:softlink.pattern.<Base>=...`) when
    # non-empty, otherwise the block's own declared/resolved pattern
    # (`libPatternLit`) unchanged. This is the ONLY site the override
    # affects — every other reference to `libPatternLit` in this macro
    # (error messages, the dup-block guard, `SoftlinkError.library`) keeps
    # naming the DECLARED pattern, exactly as documented.
    #   var effectivePattern: string
    #   if <base>PatternOverride.len > 0: effectivePattern = <base>PatternOverride
    #   else: effectivePattern = "<declared pattern>"
    let effectivePatternName = genSym(nskVar, "effectivePattern")
    loadBody.add(newNimNode(nnkVarSection).add(
      newNimNode(nnkIdentDefs).add(effectivePatternName, ident("string"), newEmptyNode())))
    var patternOverrideIf = newNimNode(nnkIfStmt)
    patternOverrideIf.add(newNimNode(nnkElifBranch).add(
      infix(newDotExpr(patternOverrideName, ident("len")), ">", newLit(0)),
      newStmtList(newAssignment(effectivePatternName, patternOverrideName))))
    patternOverrideIf.add(newNimNode(nnkElse).add(
      newStmtList(newAssignment(effectivePatternName, libPatternLit))))
    loadBody.add(patternOverrideIf)

    # RFC 0011 S0a item 5: let loadOutcome = loadLibPatternDetailed(pattern)
    #                       handle = loadOutcome.handle
    # `loadLibPatternDetailed` (softlink/loader.nim) replaces the plain
    # `loadLibPattern` call this used to be — same candidate expansion, same
    # first-hit-wins ordering (it's built directly on `loadLibPattern`'s own
    # `libCandidates`), but it also carries back the OS loader's diagnostic
    # for every candidate that failed, consumed by the `lrLibNotFound`
    # branch just below. Called against `effectivePattern` (above), not
    # `libPatternLit` directly, so an active pattern override is what the
    # loader actually tries.
    let loadOutcomeName = genSym(nskLet, "loadOutcome")
    loadBody.add(newLetStmt(loadOutcomeName,
      newCall(ident("loadLibPatternDetailed"), effectivePatternName)))
    loadBody.add(newAssignment(handleName, newDotExpr(loadOutcomeName, ident("handle"))))

    # if handle.isNil: write this block's own "probe hasn't run" report
    # (RFC-0001 §9/§C.2, finding #11 — `probeNotRunFields()`: `atProbeNotRun`
    # if this block has a probe, else the bare zero-value `atNoProbe` — this
    # Phase-1 early return happens only before the first ever load, or right
    # after unloadX already reset the probe state vars to their own zero
    # values, so this IS the correct value here, not merely a placeholder)
    # + return LoadResult(kind: lrLibNotFound, attempts: loadOutcome.attempts)
    loadBody.add(newIfStmt((
      newCall(ident("isNil"), handleName),
      unwindStmt(unloadHandle = false, resultKind = ident("lrLibNotFound"),
                 resultFields = @[("attempts", newDotExpr(loadOutcomeName, ident("attempts")))],
                 reportFields = probeNotRunFields())
    )))

    # Collect temp sym names for deferred assignment
    type SymInfo = object
      ptrName: NimNode
      tempSym: NimNode
      procTy: NimNode
      isOptional: bool

    var syms: seq[SymInfo]

    # Phase 1: Resolve all REQUIRED symbols into temp vars
    for p in procs:
      if p.isOptional: continue
      let symName = newStrLitNode(p.cName)
      let tempSym = genSym(nskLet, "sym")

      var procTy = newNimNode(nnkProcTy)
      procTy.add(p.formalParams.copy())
      procTy.add(newNimNode(nnkPragma).add(
        ident(p.callConv),
        newNimNode(nnkExprColonExpr).add(
          ident("raises"), newNimNode(nnkBracket)
        )
      ))

      # let sym = handle.symAddr("name")
      loadBody.add(newLetStmt(tempSym, newCall(ident("symAddr"), handleName, symName)))

      # if sym.isNil: unload + nil handle + this block's own "probe hasn't
      # run" compat report (RFC-0001 §9/§C.2, finding #11 — same reasoning
      # as the lrLibNotFound early return above) + return lrSymbolNotFound
      let cleanupBlock = unwindStmt(unloadHandle = true,
        resultKind = ident("lrSymbolNotFound"), resultFields = @[("symbol", symName)],
        reportFields = probeNotRunFields())
      loadBody.add(newIfStmt((newCall(ident("isNil"), tempSym), cleanupBlock)))

      syms.add(SymInfo(ptrName: p.ptrName, tempSym: tempSym, procTy: procTy, isOptional: false))

    # Phase 2: Resolve all OPTIONAL symbols into temp vars
    if hasOptional:
      loadBody.add(newNimNode(nnkVarSection).add(
        newNimNode(nnkIdentDefs).add(
          missingName,
          newNimNode(nnkBracketExpr).add(ident("seq"), ident("string")),
          newEmptyNode()
        )
      ))

    for p in procs:
      if not p.isOptional: continue
      let symName = newStrLitNode(p.cName)
      let tempSym = genSym(nskLet, "sym")

      var procTy = newNimNode(nnkProcTy)
      procTy.add(p.formalParams.copy())
      procTy.add(newNimNode(nnkPragma).add(
        ident(p.callConv),
        newNimNode(nnkExprColonExpr).add(
          ident("raises"), newNimNode(nnkBracket)
        )
      ))

      # let sym = handle.symAddr("name")
      loadBody.add(newLetStmt(tempSym, newCall(ident("symAddr"), handleName, symName)))

      # if sym.isNil: missing.add(name)
      loadBody.add(newIfStmt((
        newCall(ident("isNil"), tempSym),
        newStmtList(newCall(newDotExpr(missingName, ident("add")), symName))
      )))

      syms.add(SymInfo(ptrName: p.ptrName, tempSym: tempSym, procTy: procTy, isOptional: true))

    # Phase 3: Assign all resolved pointers
    for s in syms:
      if s.isOptional:
        # if not sym.isNil: fp = cast[ProcType](sym)
        loadBody.add(newIfStmt((
          prefix(newCall(ident("isNil"), s.tempSym), "not"),
          newStmtList(newAssignment(s.ptrName, newNimNode(nnkCast).add(s.procTy, s.tempSym)))
        )))
      else:
        # Required: guaranteed non-nil by Phase 1 early-return on failure
        loadBody.add(newAssignment(s.ptrName, newNimNode(nnkCast).add(s.procTy, s.tempSym)))

    # RFC-0001 §9/§C.1: the version probe. Runs AFTER Phase 3 (every
    # resolved pointer — including optional ones — is live, so the probe
    # may call any of the block's own wrappers) and BEFORE the cached
    # LoadResult is written below (a failing probe must never change that
    # cached result — loadX's total, non-raising contract). ANY exception
    # (a wrapper raising on an unresolved optional symbol, the reentrancy
    # raise above, or anything else the probe body does) degrades to
    # probeFailed/"" — never escapes. A successfully-returned string that
    # fails to parse under the C0 grammar (`parseVersion`, the same parser
    # `{.since.}` uses) is ALSO a failed probe. The load-in-progress flag
    # is set for exactly this window (RFC: "while it is set, loadX and
    # unloadX raise") — narrower than the whole pipeline, since the only
    # reachable caller during it is the probe body itself (no other user
    # code ever runs inside loadX/unloadX, per the existing
    # no-thread-safety stance) — reset via `finally` so it clears on every
    # exit from the probe, including a raise.
    if hasProbe:
      loadBody.add(newAssignment(loadInProgressName, newLit(true)))

      let probeValSym = genSym(nskLet, "probeVal")
      let probeParsedSym = genSym(nskLet, "probeParsed")

      var tryBody = newStmtList()
      # let probeVal = <the versionProbe's own statements, as a proc call>
      tryBody.add(newLetStmt(probeValSym, newCall(probeProcSym)))
      tryBody.add(newLetStmt(probeParsedSym,
        newCall(bindSym("parseVersion"), probeValSym)))

      var classifyIf = newNimNode(nnkIfStmt)
      classifyIf.add(newNimNode(nnkElifBranch).add(
        newCall(bindSym("isSome"), probeParsedSym),
        newStmtList(
          newAssignment(probedVersionName, probeValSym),
          newAssignment(probeFailedName, newLit(false))
        )
      ))
      classifyIf.add(newNimNode(nnkElse).add(newStmtList(
        newAssignment(probedVersionName, newStrLitNode("")),
        newAssignment(probeFailedName, newLit(true))
      )))
      tryBody.add(classifyIf)

      let exceptBody = newStmtList(
        newAssignment(probedVersionName, newStrLitNode("")),
        newAssignment(probeFailedName, newLit(true))
      )

      var tryStmt = newNimNode(nnkTryStmt)
      tryStmt.add(tryBody)
      tryStmt.add(newNimNode(nnkExceptBranch).add(ident("CatchableError"), exceptBody))
      tryStmt.add(newNimNode(nnkFinally).add(newStmtList(
        newAssignment(loadInProgressName, newLit(false))
      )))
      loadBody.add(tryStmt)

    # RFC-0001 §9/§C.2: the compat report on the success path — written
    # AFTER the probe's try/finally above (so `probedVersionName`/
    # `probeFailedName`, when they exist, are final) and BEFORE the cached
    # LoadResult write below (the two are independent vars; only the
    # relative order to the probe, and to the final `return`, matters).
    # Which shape applies is a MACRO-EXPANSION-time fact (`hasProbe`,
    # `appliedManifest.attached`); the one piece that must run at RUNTIME
    # is reading `probeFailedName`/corpus membership, since only the probe
    # call itself (just above) knows the outcome.
    if not hasProbe:
      # No versionProbe at all — atNoProbe, the zero state, unconditionally.
      loadBody.add(assignCompatReportStmt())
    elif not appliedManifest.attached:
      # Probed, no manifest to check against: failed -> atProbeFailed;
      # succeeded -> atNoManifest + the probed version.
      #
      # RFC-0002 §4.4/§4.9, slice C4b: this `atNoManifest` success arm is
      # one of the two sites §4.4 names for the manifest-less declared-
      # bound refusal check ("the atNoManifest path's else arm") — the
      # SAME `declaredBoundRefusalStmts()` fragment the `atOutOfCorpus`
      # branch below calls. `missingReasons` here is populated ONLY with
      # this fragment's own refusal entries (§4.4: "there is no facts-
      # driven partition to compute" in a manifest-less block) — no
      # `computeMissingPartition` call exists at this site at all. Omitted
      # entirely (both fields default: `missingReasons: @[]`,
      # `probeNotComparable: false`) when this block has no optional
      # bounded procs (or refusal is disabled/no probe) — same "absent,
      # not merely empty" degradation as `driftCandidates` elsewhere.
      var reportIf = newNimNode(nnkIfStmt)
      reportIf.add(newNimNode(nnkElifBranch).add(
        probeFailedName,
        newStmtList(assignCompatReportStmt(@[("attestation", ident("atProbeFailed"))]))
      ))
      var noManifestSuccessStmts = newStmtList()
      var noManifestFields: seq[(string, NimNode)] = @[
        ("runtimeVersion", probedVersionName),
        ("attestation", ident("atNoManifest"))]
      if declaredBoundOptionalCandidates.len > 0 or declaredBoundRequiredCandidates.len > 0:
        # §4.4: no facts-driven partition exists in a manifest-less block —
        # a required hit's own report (built inside `unwindStmt`) carries
        # ONLY its own refusal entry, hence `nil` here (see the proc's own
        # doc comment for the `atOutOfCorpus` counterpart, which DOES have
        # one to fold in).
        let (refusalStmts, reportFields) =
          declaredBoundRefusalStmts(ident("atNoManifest"), nil,
            declaredBoundRequiredCandidates, declaredBoundOptionalCandidates)
        noManifestSuccessStmts.add(refusalStmts)
        noManifestFields.add(reportFields)
      noManifestSuccessStmts.add(assignCompatReportStmt(noManifestFields))
      reportIf.add(newNimNode(nnkElse).add(noManifestSuccessStmts))
      loadBody.add(reportIf)
    else:
      # Probed AND a manifest is attached: failed -> atProbeFailed;
      # succeeded -> atAttested/atOutOfCorpus by EXACT STRING membership in
      # the manifest's own harvested corpus (embedded here as a literal —
      # the corpus is a discrete set of literally-harvested version tags,
      # not a range, so `cmpVersion`-equality would risk attesting a
      # version string that was never actually harvested; see the C2
      # handoff for the full rationale).
      let corpusLit = newLit(appliedManifest.manifest.corpus)

      # `allPtrNames` (the required-refusal unwind's `resetPtrs`) is built
      # once, above, ahead of `declaredBoundRefusalStmts()` — this branch
      # and that fragment share the same array.

      # RFC-0001 §9/§C.2, slice C3: the absence partition (`mrExpected`/
      # `mrAnomalous`), computed AT MOST once per successful, manifest-
      # attested load — only when there is something to partition at all
      # (`hasOptional`; a block with no optional procs can never have a
      # `missingReasons` entry). Deliberately NOT gated on atAttested-vs-
      # atOutOfCorpus: the manifest's header-fact INTERVALS (§B.3) are
      # ranges, independent of whether `probedVersion` is a literally-
      # harvested corpus point — that literal-membership question is what
      # `corpusLit`'s `in` check above answers for `attestation`, a
      # different question from "do the harvested interval facts say
      # something about this specific version" (judgment call; see the C3
      # handoff for the full rationale). `computeMissingPartition` (bound
      # via `bindSym`, like `parseVersion`/`isSome` above) is the pure-func
      # bridge — no nontrivial decision logic inlined as raw AST here.
      var missingPartitionFields: seq[(string, NimNode)] = @[]
      var missingPartitionLet = newEmptyNode()
      if hasOptional:
        # RFC-0002 §4.9, slice C4a: sourced from the canonical
        # `boundCNames`/`boundSinceVersions`/`boundUntilVersions` embedding
        # built once, above, for the whole `block:` — no local rebuild.
        # Passing the WIDENED arrays (now including required and
        # until-only procs) is behavior-preserving here, see the
        # embedding's own comment for why.
        #
        # RFC-0002 §4.3, slice C1: `boundUntilVersions` is now consumed
        # too (was built but unused as of C4a) — `computeMissingPartition`
        # threads it straight into `classifyAbsence`'s new `untilVersion`
        # param, demoting an at-or-above-`until` absence to `acExpected`.
        let missingPartitionSym = genSym(nskLet, "missingPartition")
        missingPartitionLet = newLetStmt(missingPartitionSym, newCall(
          bindSym("computeMissingPartition"),
          ident("softlinkCompatFacts" & baseName),
          missingName,
          newLit(boundCNames),
          newLit(boundSinceVersions),
          newLit(boundUntilVersions),
          probedVersionName
        ))
        missingPartitionFields.add(("missingReasons", missingPartitionSym))

      # RFC-0001 §C.3, slice C4b: drift refusal. Fires ONLY in the
      # atAttested branch below — policy: "refusal only on known
      # mismatch; out-of-corpus versions load normally" (§C.3). Built as
      # its own statement list (`attestedStmts`) rather than folding into
      # the shared `missingPartitionFields` directly, so the
      # atOutOfCorpus branch below is completely untouched by it.
      # `driftCandidates` is the OPTIONAL subset of `mismatchCNames`
      # (computed earlier, alongside the wrapper loop) — empty whenever
      # this block has no manifest, no probe, or no optional symbol with
      # a recorded `mismatch` interval, in which case this degrades to
      # exactly today's atAttested body (`attestedMissingFields ==
      # missingPartitionFields`, unchanged).
      #
      # Per-candidate shape (only emitted for symbols in
      # `driftCandidates`): if the pointer is still non-nil (Phase 3
      # resolved it — an ALREADY-nil pointer, e.g. absent at runtime, is
      # Phase 2's concern and is skipped here BY CONSTRUCTION, which is
      # exactly the "no double-count" guarantee: an absent symbol's own
      # `mismatch` fact is folded into `mrAnomalous` by
      # `computeMissingPartition`/`classifyAbsence` above, never touched
      # by this block at all) AND `firstMismatchInterval` finds a
      # matching interval at the probed version: re-nil the pointer, add
      # the symbol to the SAME `missing` seq Phase 2 built (turning an
      # otherwise-`lrOk` load `lrOkPartial`, and feeding
      # `LoadResult.missing` for free), stash the drift story, and record
      # an `mrDriftRefused` partition entry.
      var attestedStmts = newStmtList()
      var attestedMissingFields = missingPartitionFields

      # RFC-0001 §C.3, slice C4c: REQUIRED-symbol drift refusal — checked
      # FIRST, in declaration order, "first hit wins" (mirrors Phase 1's
      # own first-required-symbol-missing-wins early-fail): a hit unwinds
      # the WHOLE load via `unwindStmt`'s third shape (see its own doc
      # comment) rather than re-nilling one pointer, preserving `lrOk` ⟹
      # every required wrapper is safe to call. `requiredDriftCandidates`
      # is by construction resolved (Phase 1 guarantees every required
      # symbol resolved before this point ever runs), so — unlike the
      # OPTIONAL loop just below — no `if not isNil(ptr)` guard is needed;
      # the RFC's own wording ("Phase 1 guarantees all resolved") makes
      # that guard always-true, hence a no-op if added, so it is omitted
      # rather than emitted as dead-but-harmless ceremony.
      for p in requiredDriftCandidates:
        let symNameLit = newStrLitNode(p.cName)
        let mismatchSym = genSym(nskLet, "reqMismatch")
        let versionSnapshotSym = genSym(nskLet, "reqDriftVersion")
        let reqMissingSym = genSym(nskVar, "reqMissingPartition")
        let storyExpr = newNimNode(nnkInfix).add(ident("&"),
          newNimNode(nnkInfix).add(ident("&"),
            newStrLitNode(p.cName & ": signature drift at "),
            newCall(bindSym("formatInterval"), newCall(bindSym("get"), mismatchSym))),
          newStrLitNode(" per compat manifest; refusing unsafe dispatch"))
        var hitStmts = newStmtList()
        # Snapshot the probed version into its OWN let BEFORE calling
        # unwindStmt with resetProbeState = true: a plain Nim `string` let
        # copies the value, so the report below carries the REAL probed
        # version even though `softlinkProbedVersion<Base>` itself gets
        # reset to "" as part of the same unwind (see unwindStmt's own
        # doc comment for why this ordering matters).
        hitStmts.add(newLetStmt(versionSnapshotSym, probedVersionName))
        hitStmts.add(newCall(newDotExpr(driftStoriesName, ident("add")),
          newNimNode(nnkTupleConstr).add(
            newNimNode(nnkExprColonExpr).add(ident("symbol"), symNameLit),
            newNimNode(nnkExprColonExpr).add(ident("story"), storyExpr))))
        # RFC-0001 §C.3, slice C4c design guidance: the report's
        # `missingReasons` on a required refusal includes the C3 partition
        # entries already computed for THIS load (more honest than a
        # minimal one-entry report, and free — the partition was already
        # computed above), plus this symbol's own `mrDriftRefused` entry.
        hitStmts.add(newNimNode(nnkVarSection).add(newNimNode(nnkIdentDefs).add(
          reqMissingSym,
          newNimNode(nnkBracketExpr).add(ident("seq"), bindSym("MissingReasonEntry")),
          newEmptyNode())))
        if hasOptional:
          # `missingPartitionFields[0][1]` is the `missingPartitionSym`
          # NimNode built above — referenced through the seq (rather than
          # the macro-time Nim identifier `missingPartitionSym` itself,
          # which is scoped to the `if hasOptional:` block it was declared
          # in and is not visible here), exactly like the existing C4b
          # code's own `baseMissingNode = missingPartitionFields[0][1]`
          # does a little further below.
          hitStmts.add(newAssignment(reqMissingSym, missingPartitionFields[0][1]))
        # RFC-0002 §4.9, slice C2: this is the ATTESTED-MISMATCH leg of the
        # evidence-interval rule — `mismatchSym` (below) is this symbol's
        # own `firstMismatchInterval` result, already known `isSome` (this
        # statement only runs inside the `isSome(mismatchSym)` branch), so
        # `.get` is safe and the interval is strictly the manifest's own,
        # not the proc's declared `since`/`until`.
        hitStmts.add(newCall(newDotExpr(reqMissingSym, ident("add")),
          newNimNode(nnkTupleConstr).add(
            newNimNode(nnkExprColonExpr).add(ident("symbol"), symNameLit),
            newNimNode(nnkExprColonExpr).add(ident("reason"), ident("mrDriftRefused")),
            newNimNode(nnkExprColonExpr).add(ident("interval"),
              newCall(bindSym("get"), mismatchSym)))))
        hitStmts.add(unwindStmt(
          unloadHandle = true,
          resultKind = ident("lrSymbolNotFound"),
          resultFields = @[("symbol", symNameLit)],
          reportFields = @[
            ("runtimeVersion", versionSnapshotSym),
            ("attestation", ident("atAttested")),
            ("missingReasons", reqMissingSym)],
          resetPtrs = allPtrNames,
          resetProbeState = true))
        attestedStmts.add(newLetStmt(mismatchSym, newCall(bindSym("firstMismatchInterval"),
          ident("softlinkCompatFacts" & baseName), symNameLit, probedVersionName)))
        attestedStmts.add(newIfStmt((newCall(bindSym("isSome"), mismatchSym), hitStmts)))

      if driftCandidates.len > 0:
        let driftPartitionSym = genSym(nskVar, "driftRefusedPartition")
        attestedStmts.add(newNimNode(nnkVarSection).add(newNimNode(nnkIdentDefs).add(
          driftPartitionSym,
          newNimNode(nnkBracketExpr).add(ident("seq"), bindSym("MissingReasonEntry")),
          newEmptyNode())))
        for p in driftCandidates:
          let symNameLit = newStrLitNode(p.cName)
          let mismatchSym = genSym(nskLet, "mismatch")
          let storyExpr = newNimNode(nnkInfix).add(ident("&"),
            newNimNode(nnkInfix).add(ident("&"),
              newStrLitNode(p.cName & ": signature drift at "),
              newCall(bindSym("formatInterval"), newCall(bindSym("get"), mismatchSym))),
            newStrLitNode(" per compat manifest; refusing unsafe dispatch"))
          var refuseStmts = newStmtList()
          refuseStmts.add(newAssignment(p.ptrName, newNilLit()))
          refuseStmts.add(newCall(newDotExpr(missingName, ident("add")), symNameLit))
          refuseStmts.add(newCall(newDotExpr(driftStoriesName, ident("add")),
            newNimNode(nnkTupleConstr).add(
              newNimNode(nnkExprColonExpr).add(ident("symbol"), symNameLit),
              newNimNode(nnkExprColonExpr).add(ident("story"), storyExpr))))
          # RFC-0002 §4.9, slice C2: same attested-mismatch leg as the
          # required-symbol loop above — `mismatchSym.get`, not the
          # proc's declared bounds (this symbol may carry none at all,
          # e.g. `testlib_gated`, which has no `since`/`until` pragma).
          refuseStmts.add(newCall(newDotExpr(driftPartitionSym, ident("add")),
            newNimNode(nnkTupleConstr).add(
              newNimNode(nnkExprColonExpr).add(ident("symbol"), symNameLit),
              newNimNode(nnkExprColonExpr).add(ident("reason"), ident("mrDriftRefused")),
              newNimNode(nnkExprColonExpr).add(ident("interval"),
                newCall(bindSym("get"), mismatchSym)))))
          let candBlock = newStmtList(
            newLetStmt(mismatchSym, newCall(bindSym("firstMismatchInterval"),
              ident("softlinkCompatFacts" & baseName), symNameLit, probedVersionName)),
            newIfStmt((newCall(bindSym("isSome"), mismatchSym), refuseStmts)))
          attestedStmts.add(newIfStmt((
            prefix(newCall(ident("isNil"), p.ptrName), "not"),
            candBlock)))
        # missingPartitionFields has exactly one entry,
        # ("missingReasons", <sym>), whenever driftCandidates is nonempty
        # (its members are all optional, so hasOptional is necessarily true
        # here too) — extend THAT node with `& driftPartitionSym` for this
        # branch only.
        let baseMissingNode = missingPartitionFields[0][1]
        attestedMissingFields = @[("missingReasons",
          newNimNode(nnkInfix).add(ident("&"), baseMissingNode, driftPartitionSym))]

      # RFC-0002 §4.4, code-review finding CR1-1 (Critical): the ATTESTED
      # path's own declared-bound refusal, restricted to bounded procs
      # ABSENT from the attached manifest (`declaredBoundRequiredCandidatesAbsent`/
      # `declaredBoundOptionalCandidatesAbsent`, computed once above,
      # alongside the full lists). `checkUntil`/`checkSince` vacuously pass
      # on a manifest-absent symbol (nothing recorded to check the
      # declaration against), so — unlike a manifest-PRESENT bounded proc,
      # whose compile-time-validated declaration makes a runtime re-check
      # here pure redundancy (unchanged, see the required/optional loops
      # just above, both keyed on `mismatchCNames`/manifest facts only) — a
      # manifest-absent bounded proc got ZERO enforcement on this path
      # before this fix, even when the probe attests an in-corpus version
      # at-or-above its declared bound. Emitted AFTER both mismatch-fact
      # loops above (required-drift, then optional-drift): a symbol can
      # only ever be a candidate for ONE of the three mechanisms (mismatch-
      # fact loops only ever see manifest-PRESENT symbols; this fragment
      # only ever sees manifest-ABSENT ones), so the ordering doesn't change
      # any existing symbol's outcome — it is purely additive, and (for the
      # required flavor) "first hit wins" still holds trivially since no
      # symbol can hit both mechanisms.
      if declaredBoundRequiredCandidatesAbsent.len > 0 or
         declaredBoundOptionalCandidatesAbsent.len > 0:
        let priorMissingFieldAttested =
          if attestedMissingFields.len > 0: attestedMissingFields[0][1] else: nil
        let (absentRefusalStmts, reportFields) =
          declaredBoundRefusalStmts(ident("atAttested"), priorMissingFieldAttested,
            declaredBoundRequiredCandidatesAbsent, declaredBoundOptionalCandidatesAbsent)
        attestedStmts.add(absentRefusalStmts)
        attestedMissingFields = reportFields

      attestedStmts.add(assignCompatReportStmt(@[
        ("runtimeVersion", probedVersionName),
        ("attestation", ident("atAttested"))] & attestedMissingFields))

      var corpusIf = newNimNode(nnkIfStmt)
      corpusIf.add(newNimNode(nnkElifBranch).add(
        newNimNode(nnkInfix).add(ident("in"), probedVersionName, corpusLit),
        attestedStmts
      ))
      # RFC-0002 §4.4/§4.9, slice C4b/C4c: this `atOutOfCorpus` else-branch
      # is the other site §4.4 names for the declared-bound refusal check —
      # the SAME `declaredBoundRefusalStmts()` fragment the `atNoManifest`
      # arm above calls. `missingPartitionFields` (the C3 absence
      # partition, computed once above via `missingPartitionLet`, BEFORE
      # `corpusIf` — see `successStmts` below) is read here FIRST, then
      # this fragment's own `mrDriftRefused` entries are appended — the
      # "no double-count" emission-order §4.4 specifies. Whenever
      # `declaredBoundOptionalCandidates` is nonempty, `hasOptional` is
      # necessarily true too (its members are all optional), so
      # `missingPartitionFields` is guaranteed to hold exactly the one
      # `("missingReasons", <sym>)` entry `computeMissingPartition` built —
      # same precondition the `atAttested` branch's own `driftCandidates`
      # merge (`baseMissingNode`, above) already relies on. UNLIKE the
      # optional-only C4b guard, `declaredBoundRequiredCandidates` is NOT
      # gated on `p.isOptional`, so a block with only required bounded
      # procs (no optional ones at all) can reach here with `hasOptional`
      # false and an empty `missingPartitionFields` — guarded explicitly
      # below rather than assumed.
      var outOfCorpusStmts = newStmtList()
      var outOfCorpusFields = missingPartitionFields
      if declaredBoundOptionalCandidates.len > 0 or declaredBoundRequiredCandidates.len > 0:
        let priorMissingField = if hasOptional: missingPartitionFields[0][1] else: nil
        let (refusalStmts, reportFields) =
          declaredBoundRefusalStmts(ident("atOutOfCorpus"), priorMissingField,
            declaredBoundRequiredCandidates, declaredBoundOptionalCandidates)
        outOfCorpusStmts.add(refusalStmts)
        outOfCorpusFields = reportFields
      outOfCorpusStmts.add(assignCompatReportStmt(@[
        ("runtimeVersion", probedVersionName),
        ("attestation", ident("atOutOfCorpus"))] & outOfCorpusFields))
      corpusIf.add(newNimNode(nnkElse).add(outOfCorpusStmts))
      var reportIf = newNimNode(nnkIfStmt)
      reportIf.add(newNimNode(nnkElifBranch).add(
        probeFailedName,
        newStmtList(assignCompatReportStmt(@[("attestation", ident("atProbeFailed"))]))
      ))
      var successStmts = newStmtList()
      if hasOptional:
        successStmts.add(missingPartitionLet)
      successStmts.add(corpusIf)
      reportIf.add(newNimNode(nnkElse).add(successStmts))
      loadBody.add(reportIf)

    # Cache and return result
    if hasOptional:
      # if missing.len > 0: cache lrOkPartial else: cache lrOk
      var cacheIfElse = newNimNode(nnkIfStmt)
      cacheIfElse.add(newNimNode(nnkElifBranch).add(
        newNimNode(nnkInfix).add(ident(">"),
          newDotExpr(missingName, ident("len")),
          newIntLitNode(0)),
        newStmtList(newAssignment(cachedResultName,
          newNimNode(nnkObjConstr).add(
            ident("LoadResult"),
            newNimNode(nnkExprColonExpr).add(ident("kind"), ident("lrOkPartial")),
            newNimNode(nnkExprColonExpr).add(ident("missing"), missingName)
          )
        ))
      ))
      cacheIfElse.add(newNimNode(nnkElse).add(
        newStmtList(newAssignment(cachedResultName,
          newNimNode(nnkObjConstr).add(
            ident("LoadResult"),
            newNimNode(nnkExprColonExpr).add(ident("kind"), ident("lrOk"))
          )
        ))
      ))
      loadBody.add(cacheIfElse)
    else:
      # cache lrOk
      loadBody.add(newAssignment(cachedResultName,
        newNimNode(nnkObjConstr).add(
          ident("LoadResult"),
          newNimNode(nnkExprColonExpr).add(ident("kind"), ident("lrOk"))
        )
      ))

    # return cachedResult
    loadBody.add(newNimNode(nnkReturnStmt).add(cachedResultName))

    result.add(newProc(
      name = postfix(loadProcName, "*"),
      params = [ident("LoadResult")],
      body = loadBody,
    ))

  # unloadXxx*()
  block:
    var unloadBody = newStmtList()

    # RFC-0001 §9/§C.1: the same reentrancy guard as loadX above — a probe
    # calling unloadX() recursively must raise, not silently unload the
    # library out from under the still-in-progress loadX pipeline that is
    # running it. Unconditional (checked before the `handle.isNil` test
    # below): the RFC's guard applies "while it is set", regardless of
    # load state.
    if hasProbe:
      unloadBody.add(newIfStmt((
        loadInProgressName,
        newStmtList(reentrancyRaiseStmt("unload" & baseName))
      )))

    var ifBody = newStmtList()
    ifBody.add(newCall(ident("unloadLib"), handleName))
    ifBody.add(newAssignment(handleName, newNilLit()))
    for p in procs:
      ifBody.add(newAssignment(p.ptrName, newNilLit()))
    # Reset cached result. The value doesn't matter because the idempotent
    # guard in loadXxx checks the handle (now nil), so it will recompute.
    ifBody.add(newAssignment(cachedResultName,
      newNimNode(nnkObjConstr).add(
        ident("LoadResult"),
        newNimNode(nnkExprColonExpr).add(ident("kind"), ident("lrOk"))
      )
    ))
    unloadBody.add(newIfStmt((
      prefix(newCall(ident("isNil"), handleName), "not"),
      ifBody
    )))

    # RFC-0001 §9/§C.2/§C.3, slice C4c: the report/probe-state/drift-story
    # resets below are UNCONDITIONAL — deliberately NOT nested inside the
    # `if not handle.isNil` guard above (where they lived pre-C4c). C4c's
    # required-drift-refusal unwind can leave `handle` ALREADY nil (the
    # unwind itself unloads the library, see the `dynlib` macro's
    # `requiredDriftCandidates` loop) while `softlinkCompatReport<Base>`
    # still carries THAT failure's drift story — calling unloadXxx() after
    # such a failure must still zero the report (RFC-0001 §C.2:
    # `fooCompat()` after `unloadFoo()` must never serve a previous load's
    # trust signals), which the OLD handle-guarded placement could not do,
    # since `not handle.isNil` is false in exactly that state.
    #
    # This is a behavior-preserving generalization, not a new runtime
    # effect, for every block reachable before C4c: every OTHER path that
    # leaves `handle` nil (the initial zero state; a Phase-1 early-fail,
    # whose own `unwindStmt` call already writes this block's own
    # "probe hasn't run" report directly) already has these vars at
    # exactly this same value by the time unloadXxx would run, so
    # re-assigning them here is an idempotent no-op in every one of those
    # cases — only C4c's new non-zero-report-with-nil-handle state makes
    # the distinction observable at all.
    # RFC-0001 §9/§C.2, finding #11: reset the compat report to this
    # block's own "probe hasn't run" state — `atProbeNotRun` if this block
    # declares a `versionProbe` (a reload will run it again), or the bare
    # zero-value `atNoProbe` if it doesn't — via the same `probeNotRunFields
    # ()` every other "not run yet" site uses. `fooCompat()` called after
    # `unloadFoo()` must never serve a previous load's trust signals.
    # Unconditional wrt `hasProbe` too, like the report var's own
    # declaration (every dynlib block gets a report, not just
    # probe-declaring ones) — unchanged from pre-C4c/pre-#11 in shape, only
    # the probe-bearing block's actual VALUE differs now.
    unloadBody.add(assignCompatReportStmt(probeNotRunFields()))
    if hasProbe:
      # RFC-0001 §9/§C.1: reset the probe's outcome alongside the report
      # above — `fooCompat()` (RFC-0001 §C.2) called after `unloadFoo()`
      # must never serve a previous load's probe result.
      unloadBody.add(newAssignment(probedVersionName, newStrLitNode("")))
      unloadBody.add(newAssignment(probeFailedName, newLit(false)))
    if driftCandidates.len > 0 or requiredDriftCandidates.len > 0 or
       declaredBoundOptionalCandidates.len > 0 or
       declaredBoundRequiredCandidates.len > 0:
      # RFC-0001 §C.3, slice C4b/C4c: reset the drift-story seq alongside
      # every other piece of per-load state above — a reload must re-run
      # refusal fresh, never carry forward a previous load's stories.
      unloadBody.add(newAssignment(driftStoriesName, prefix(newNimNode(nnkBracket), "@")))

    result.add(newProc(
      name = postfix(unloadProcName, "*"),
      body = unloadBody,
    ))

  # xxxLoaded*(): bool
  result.add(newProc(
    name = postfix(loadedProcName, "*"),
    params = [ident("bool")],
    body = newStmtList(prefix(newCall(ident("isNil"), handleName), "not")),
  ))

  # xxxCompat*(): CompatReport — RFC-0001 §9/§C.2, slice C2: generated for
  # EVERY dynlib block, unconditionally (a probe-less block's query proc
  # simply always returns the report var's permanent zero value,
  # `atNoProbe`; a probe-bearing block's returns `atProbeNotRun` before its
  # first load and after every unload — finding #11).
  # `verifyProcs` has no counterpart — see `CompatReport`'s own doc comment.
  let compatProcName = ident(baseNameLower & "Compat")
  result.add(newProc(
    name = postfix(compatProcName, "*"),
    params = [ident("CompatReport")],
    body = newStmtList(compatReportName),
  ))

proc collectVProcs(body: NimNode): tuple[procs: seq[SoftlinkProc], directive: CompatManifestDirective, versionMacros: VersionMacrosDirective] =
  ## Parse a block of proc declarations for verification. Each must carry a
  ## calling convention and a {.header.} pragma (same rules as `dynlib`,
  ## enforced by the shared `parseProcPragmas`), but `optional`/`noverify`
  ## are rejected — the block exists solely to verify.
  var seenNames: HashSet[string]
  var manifestDirective: CompatManifestDirective
  var versionMacrosDirective: VersionMacrosDirective
  for stmt in body:
    if isCompatManifestCall(stmt):
      let d = parseCompatManifestDirective(stmt, "verifyProcs")
      if manifestDirective.present:
        error(compatManifestDupError("verifyProcs", manifestDirective, d), stmt)
      else:
        manifestDirective = d
      continue
    if isVersionProbeStmt(stmt):
      # RFC-0001 §9/§C.1, judgment call (not stated explicitly by the
      # RFC): verifyProcs has no library identity, no loadX, no runtime
      # footprint at all — there is no pipeline for a probe to run inside.
      # Rejected outright, in every shape, analogous to how `noverify` is
      # rejected in verifyProcs mode above ("meaningless... simply omit").
      error("versionProbe has no meaning in verifyProcs — it has no " &
            "runtime footprint (no loadX to run it inside); omit it", stmt)
      continue
    if isTrustedWrappersCall(stmt):
      # RFC 0011 S0b, work item (i)(j), judgment call (not stated
      # explicitly by the RFC): `verifyProcs` generates NO wrappers at all
      # (RFC-0001 §B.5a's documented CEILING — "no library identity, no
      # loadX, no pointers, no wrappers"), so `trustedWrappers`'
      # entire effect (generated wrappers become `{.raises: [].}`) has
      # nothing to apply to. Rejected outright, in every shape, exactly
      # like `versionProbe` immediately above and `noverify` in
      # `softlink/pragmas.parseProcPragmas`'s `ppmVerifyProcs` arm — same
      # "meaningless here, simply omit" family, not a silent no-op hint:
      # a silently-ignored directive would read as though it did
      # something.
      error("trustedWrappers has no meaning in verifyProcs — it generates " &
            "no wrappers (verifyProcs emits signature verification only, " &
            "never runtime dispatch); omit it", stmt)
      continue
    # RFC-0002 §4.7/§5/§6, slice E1: `versionMacros` IS accepted in
    # verifyProcs (unlike `versionProbe` above) — "gates are its live
    # majority too" (§4.7). Same parse/dup-check as `dynlib`'s copy.
    if isVersionMacrosCall(stmt):
      let d = parseVersionMacrosDirective(stmt, "verifyProcs")
      if versionMacrosDirective.present:
        error(versionMacrosDupError("verifyProcs", versionMacrosDirective, d), stmt)
      else:
        versionMacrosDirective = d
      continue
    if stmt.kind != nnkProcDef:
      error("verifyProcs body must contain only proc declarations (or a " &
            "compatManifest or versionMacros directive)", stmt)
    let procName = stmt[0]
    let nameStr = $procName
    let formalParams = stmt[3]
    let hasReturn = formalParams[0].kind != nnkEmpty
    if nameStr in seenNames:
      error("duplicate proc '" & nameStr & "' in verifyProcs block", stmt)
    seenNames.incl(nameStr)
    let facts = parseProcPragmas(stmt, nameStr, ppmVerifyProcs)
    result.procs.add(SoftlinkProc(name: procName, nameStr: nameStr, cName: facts.cName,
      ptrName: procName,
      formalParams: formalParams, callConv: facts.callConv, headerFile: facts.headerFile,
      isOptional: false, verifyWhen: facts.verifyWhen, prototype: facts.prototype,
      sinceVersion: facts.sinceVersion, untilVersion: facts.untilVersion,
      hasReturn: hasReturn))
  result.directive = manifestDirective
  result.versionMacros = versionMacrosDirective

macro verifyProcs*(body: untyped): untyped =
  ## Emit ONLY compile-time C header signature verification for the given proc
  ## declarations \u2014 no loading, no wrappers, no runtime footprint. Each proc
  ## needs a calling convention and a {.header.} pragma, exactly like `dynlib`.
  ##
  ## Use this to give statically-linked `{.importc.}` bindings the same
  ## `_Static_assert`-grade signature checking that `dynlib` performs for
  ## dynamic ones. This is identity-coherent with softlink: it *verifies* FFI
  ## signatures against headers; it does not perform static linking.
  var (procs, manifestDirective, versionMacrosDirective) = collectVProcs(body)
  let tag = if procs.len > 0: procs[0].nameStr else: "anon"
  # RFC-0002 §5/§6, slice E2: gate synthesis — same ordering rule as
  # `dynlib` above: MUST run before `checkUntilRequiresGate` just below.
  synthesizeVersionGates(procs, versionMacrosDirective.present,
                          versionMacrosDirective.macroNames, "verifyProcs")
  # RFC-0002 §4.1/§5/§6, slice D1: `until` requires `verifyWhen` — same
  # unconditional, post-body-scan check `dynlib` runs, called before
  # `applyCompatManifest` for the same reason (see `checkUntilRequiresGate`'s
  # doc comment): it does not depend on a `compatManifest` being attached.
  # Runs AFTER synthesis just above, for the same reason as `dynlib`.
  checkUntilRequiresGate(procs, "verifyProcs")
  # Code-review finding CR1-12: same unused-directive hint `dynlib` emits
  # above, same post-synthesis timing.
  checkVersionMacrosConsumed(procs, versionMacrosDirective.present,
                              versionMacrosDirective.macroNames, "verifyProcs",
                              versionMacrosDirective.node)
  # RFC-0001 SS4 B.5a, slice B6a: the compile-time subset (no lib-identity
  # check -- verifyProcs has no library identity to check against).
  let appliedManifest = applyCompatManifest(ppmVerifyProcs, "", procs, manifestDirective)
  result = newStmtList()
  for n in genVerifyBlock(procs, tag, appliedManifest.attached,
                           versionMacrosDirective.headerName):
    result.add(n)
  # RFC-0001 §B.5a, slice B6b: NO const embedding for verifyProcs — "no
  # library identity, no loadX, no pointers, no wrappers... no const
  # embedding" is a documented CEILING, not an oversight. `dynlib`'s
  # `softlinkCompatFacts<Base>` block above simply has no counterpart here.

  # RFC-0001 §4 B.1, spec gap resolved: `verifyProcs` blocks have no lib
  # pattern and no derived ident base — `dynlib`'s "one file per derived
  # base name" doesn't literally apply. Base name here is
  # `"Verify" & capitalizeAscii(tag)`, reusing the SAME `tag`
  # `genVerifyBlock` already uses to name the emitted `softlinkVerify<tag>`
  # C proc (first proc's name, or "anon" for an empty block) — it is
  # already the deterministic, block-unique discriminator this macro relies
  # on (two blocks sharing a `tag` would already collide on that generated
  # proc's name and fail to compile), so reusing it introduces no new
  # naming scheme. `libPattern` is "" and `kind` is "verifyProcs", giving
  # the Stage B3 harvester an explicit way to tell the two block kinds
  # apart instead of inferring it from an empty `libPattern` alone.
  dumpProbeFacts("verifyProcs", body.lineInfoObj.filename, "",
                 "Verify" & capitalizeAscii(tag), procs, body)

macro dyntype*(headerFile: static[string], body: untyped): untyped =
  ## Verify Nim struct layouts match C header struct definitions at compile time.
  ## Emits ``_Static_assert(sizeof(NimType) == sizeof(CType))`` for each type.
  if headerFile.len == 0:
    error("dyntype requires a header file path", body)

  result = newStmtList()

  type TypeInfo = object
    nimName: NimNode
    ctype: string

  var types: seq[TypeInfo]
  var seenNames: HashSet[string]

  for stmt in body:
    if stmt.kind != nnkTypeSection:
      error("dyntype body must contain only type definitions", stmt)

    # Extract type info and strip ctype pragma before passing through
    let cleanStmt = stmt.copy()
    for i, typeDef in cleanStmt:
      # Unwrap PragmaExpr and nnkPostfix (exported types: type Foo* = ...)
      var rawName = if typeDef[0].kind == nnkPragmaExpr: typeDef[0][0]
                    else: typeDef[0]
      let nimName = if rawName.kind == nnkPostfix: rawName[1]
                    else: rawName
      let nameStr = $nimName

      # Duplicate detection
      if nameStr in seenNames:
        error("duplicate type '" & nameStr & "' in dyntype block", typeDef)
      seenNames.incl(nameStr)

      var ctype = ""

      # Check pragmas for ctype
      if typeDef[0].kind == nnkPragmaExpr:
        let pragmas = typeDef[0][1]
        for pragma in pragmas:
          if pragma.kind == nnkExprColonExpr and $pragma[0] == "ctype":
            ctype = pragma[1].strVal
          else:
            let pname = pragmaKeyName(pragma)
            if pname != "":
              error("dyntype does not support pragma '" & pname &
                    "' on type '" & $nimName & "'", pragma)

        # Strip the ctype pragma — replace PragmaExpr with rawName
        # (preserves nnkPostfix for exported types)
        cleanStmt[i][0] = rawName

      if ctype == "":
        error("type '" & $nimName &
              "' must specify a ctype pragma (e.g., {.ctype: \"my_struct_t\".})", typeDef)

      types.add(TypeInfo(nimName: nimName, ctype: ctype))

    result.add(cleanStmt)

  # Emit #include
  result.add(newNimNode(nnkPragma).add(
    newNimNode(nnkExprColonExpr).add(
      ident("emit"),
      newStrLitNode("/*INCLUDESECTION*/\n" & toIncludeDirective(headerFile))
    )
  ))

  # Emit sizeof verification at file scope per type
  for t in types:
    var emitArray = newNimNode(nnkBracket)
    emitArray.add(newStrLitNode(
      "\n#if defined(__cplusplus)\n" &
      "static_assert(sizeof("
    ))
    emitArray.add(t.nimName)
    emitArray.add(newStrLitNode(
      ") == sizeof(" & t.ctype & "),\n" &
      "  \"softlink dyntype: " & $t.nimName & " size mismatch vs " & headerFile &
      " (" & t.ctype & ")\");\n" &
      "#else\n" &
      "_Static_assert(sizeof("
    ))
    emitArray.add(t.nimName)
    emitArray.add(newStrLitNode(
      ") == sizeof(" & t.ctype & "),\n" &
      "  \"softlink dyntype: " & $t.nimName & " size mismatch vs " & headerFile &
      " (" & t.ctype & ")\");\n" &
      "#endif\n"
    ))
    result.add(newNimNode(nnkPragma).add(
      newNimNode(nnkExprColonExpr).add(
        ident("emit"),
        emitArray
      )
    ))
