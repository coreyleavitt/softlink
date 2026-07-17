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
# Exported because macro-generated code resolves these identifiers at the call site.
export stdDynlib.LibHandle, stdDynlib.loadLibPattern, stdDynlib.symAddr,
       stdDynlib.unloadLib
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
    of lrLibNotFound, lrOk:
      discard

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
    missingReasons*: seq[tuple[symbol: string, reason: MissingReason]]

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
                              sinceCNames, sinceVersions: seq[string],
                              probedVersion: string):
                              seq[tuple[symbol: string, reason: MissingReason]] =
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
  ## (this block's OPTIONAL procs' own `{.since.}` claims only — required
  ## symbols never appear in `missingSymbols` on a successful load, so
  ## their claims are irrelevant here) rather than a `seq` of pairs, purely
  ## so the macro can embed them with the same plain `newLit(seq[string])`
  ## shape already proven elsewhere in this file (`corpusLit`), with no new
  ## exported aggregate type for generated code to reference by name.
  for sym in missingSymbols:
    var since = ""
    for i in 0 ..< sinceCNames.len:
      if sinceCNames[i] == sym:
        since = sinceVersions[i]
        break
    case classifyAbsence(symbols, sym, probedVersion, since)
    of acExpected: result.add (symbol: sym, reason: mrExpected)
    of acAnomalous: result.add (symbol: sym, reason: mrAnomalous)
    of acNone: discard

# `toIncludeDirective`/`emitPrototypeDecl` moved to `softlink/verify` (code-
# review finding #13's "genVerifyBlock + verification tiers" seam) —
# `toIncludeDirective` is exported from there (`dyntype` below still calls
# it); `emitPrototypeDecl` is used only inside `genVerifyBlock` itself and
# stays private to that module.

func libNameToIdent(libPattern: string): string =
  ## Derive an identifier base name from a library pattern string.
  ## Strips "lib" prefix, truncates at first dot, removes non-alphanumeric
  ## characters (underscores, hyphens, etc.), and capitalizes.
  ## Examples: "libmbedtls.so(.16|)" → "Mbedtls", "libfoo_bar.so" → "Foobar"
  var name = libPattern
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
  ## `cName` duplicates `nimName`: softlink has no `{.importc: "...".}`-
  ## style rename axis today — the C symbol `symAddr`/the verify assert
  ## look up IS the proc's Nim name (see `dynlib`'s `loadXxx` body and
  ## `genVerifyBlock`, both keyed on `nameStr`). Both keys are still
  ## emitted so the harvester's schema doesn't have to special-case their
  ## current equality if that axis is ever added.
  ##
  ## `since` (RFC-0001 §B.5/§C.2, slice B6a: {.since: "x.y.z".} lands in
  ## THIS slice) now carries the real per-proc value — "" when the pragma
  ## is absent, same as every other optional fact here. The key itself was
  ## already reserved (always `""`) before this slice, precisely so the
  ## harvester's key set would not churn when a real value arrived.
  %*{
    "nimName": p.nameStr,
    "cName": p.nameStr,
    "header": p.headerFile,
    "prototype": p.prototype,
    "verifyWhen": p.verifyWhen,
    "optional": p.isOptional,
    "noverify": p.noVerify,
    "noverifyReason": p.noVerifyReason,
    "since": p.sinceVersion
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
  ## Extracts a plain identifier name from a call/command node's callee
  ## position (`n`), when that position is either a bare ident (`P(x)`'s
  ## callee IS `P`) or the field/callee half of a dot-call/UFCS expression
  ## (`x.P(...)`'s callee is `DotExpr(x, P)` — the caller passes THAT node's
  ## `[1]` here, i.e. `P`). A single-token `` `P` `` (`nnkAccQuoted`) in
  ## that position is also unwrapped, so `` x.`P`(...) `` resolves the same
  ## as `x.P(...)`. Returns `""` for anything else (multi-token accquoted,
  ## a computed/non-ident expression, etc.) — callers treat `""` as "not a
  ## recognizable direct callee name", never as a match.
  if n.kind == nnkIdent:
    $n
  elif n.kind == nnkAccQuoted and n.len == 1 and n[0].kind == nnkIdent:
    $n[0]
  else:
    ""

proc normalizeCalleeNode(n: NimNode): NimNode =
  ## Code-review finding R2-1: repeatedly strips a single-child `nnkPar` —
  ## a parenthesized expression, e.g. `(P)` or the doubly-wrapped `((P))` —
  ## around a call's callee position, so `(P)(x)` and `((P))(x)` are seen
  ## exactly as directly as the unparenthesized `P(x)`. An `nnkPar` with
  ## `len != 1` is a TUPLE CONSTRUCTOR (`(a, b)`), never a grouped
  ## expression, and is deliberately left untouched — stripping it would
  ## silently treat an unrelated AST shape as a callee.
  ##
  ## Must run BEFORE the `nnkDotExpr` unwrap in
  ## `scanProbeBodyForDriftCalls`: a paren can wrap a dot-expr callee too
  ## (`(x.P)(...)`), so parens have to come off first for the subsequent
  ## dot-unwrap to see the `DotExpr` underneath.
  result = n
  while result.kind == nnkPar and result.len == 1:
    result = result[0]

proc scanProbeBodyForDriftCalls(stmts: NimNode, mismatchCNames: HashSet[string]): bool =
  ## RFC-0001 §C.1/§C.3, slice C4b: "the version probe may only call
  ## symbols with no known drift ranges" (RFC §C.1: "the probe must not be
  ## the drift"). Walks `stmts` (the versionProbe body, still raw AST at
  ## macro-expansion time — the manifest is already parsed by now) looking
  ## for a DIRECT call (`nnkCall`/`nnkCommand`) whose callee is a bare ident
  ## matching `mismatchCNames` — this block's own symbols (required OR
  ## optional; required-symbol RUNTIME refusal is C4c's territory, but the
  ## call-safety risk this scan guards against exists for both) that carry
  ## ANY `mismatch` interval in the attached manifest. The dot-call/UFCS
  ## form (`x.P(...)`, AST `Call(DotExpr(x, P), ...)`) is ALSO matched: the
  ## callee's `P` half is exactly as direct and exactly as detectable as
  ## the bare-ident form `P(x)` — UFCS is sugar, not an indirection, so
  ## treating it as unseeable would be a real gap, not a documented one.
  ## The callee position is first run through `normalizeCalleeNode` (R2-1),
  ## which strips any wrapping single-child `nnkPar`, so a parenthesized
  ## callee — `(P)(x)`, `((P))(x)`, or the paren-wrapped-UFCS `(x.P)(x)` —
  ## is detected identically to its unparenthesized form; detection here is
  ## now paren/UFCS-insensitive. Emits ONE macro error at the offending
  ## call node and stops (returns `true`) — a probe with several such calls
  ## gets one diagnostic, not a pile-up. Indirect calls TRULY through a
  ## variable, a closure, or a method value can't be seen statically; that
  ## residual risk is accepted and documented here, not pretended away, per
  ## the RFC's own words.
  if stmts.kind in {nnkCall, nnkCommand} and stmts.len > 0:
    let normalizedCallee = normalizeCalleeNode(stmts[0])
    let calleeNode =
      if normalizedCallee.kind == nnkDotExpr and normalizedCallee.len == 2: normalizedCallee[1]
      else: normalizedCallee
    let callee = calleeIdentName(calleeNode)
    if callee.len > 0 and callee in mismatchCNames:
      error("softlink: dynlib: versionProbe directly calls '" & callee &
            "', which has a recorded 'mismatch' interval in the attached " &
            "compat manifest — the version probe may only call symbols " &
            "with no known drift ranges (RFC-0001 §C.1: \"the probe must " &
            "not be the drift\"); indirect calls cannot be detected " &
            "statically and remain a documented residual risk", stmts)
      return true
  for child in stmts:
    if scanProbeBodyForDriftCalls(child, mismatchCNames):
      return true
  false

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
  # Derive the ident base from the *logical* name (the macro argument), NOT the
  # OS-expanded pattern: deriveLibPattern's Windows form "(libz3|z3).dll" would
  # mangle through libNameToIdent to "Libz3z3", breaking cross-OS ident
  # stability (loadLibz3z3 on Windows vs loadZ3 elsewhere). Using libPattern
  # makes the generated idents identical across every target by construction.
  # (For explicit patterns, resolvedPattern == libPattern, so this is a no-op.)
  let baseName = libNameToIdent(libPattern)
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

  # Collect proc info and generate pointer vars
  var procs: seq[SoftlinkProc]
  var seenNames: HashSet[string]
  var manifestDirective: CompatManifestDirective
  var versionProbeDirective: VersionProbeDirective

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

    if stmt.kind != nnkProcDef:
      error("dynlib body must contain only proc declarations (or a " &
            "compatManifest directive)", stmt)

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

    procs.add(SoftlinkProc(name: procName, nameStr: nameStr, ptrName: ptrName,
                        formalParams: formalParams, callConv: facts.callConv,
                        headerFile: facts.headerFile, isOptional: facts.isOptional,
                        noVerify: facts.noVerify, noVerifyReason: facts.noVerifyReason,
                        verifyWhen: facts.verifyWhen,
                        prototype: facts.prototype, sinceVersion: facts.sinceVersion,
                        hasReturn: hasReturn))

    # Build proc type for the var — C functions can't raise Nim exceptions
    var procTy = newNimNode(nnkProcTy)
    procTy.add(formalParams.copy())
    procTy.add(newNimNode(nnkPragma).add(
      ident(facts.callConv),
      newNimNode(nnkExprColonExpr).add(
        ident("raises"),
        newNimNode(nnkBracket)
      )
    ))

    # var fpXxx: proc(...) {.callConv.}
    result.add(newNimNode(nnkVarSection).add(
      newNimNode(nnkIdentDefs).add(
        ptrName,
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
    var unverified: seq[string]
    for p in procs:
      if p.noVerify:
        let reasonPart =
          if p.noVerifyReason.len > 0: "\"" & p.noVerifyReason & "\""
          else: "(no justification)"
        unverified.add(p.nameStr & " — " & reasonPart)
    if unverified.len > 0:
      let msg = "softlink: dynlib \"" & libPattern & "\": " &
        $unverified.len & (if unverified.len == 1: " symbol" else: " symbols") &
        " not header-verified ({.noverify.}): " & unverified.join(", ")
      when defined(softlinkStrictVerify):
        warning(msg, body)
      else:
        hint(msg, body)

  # RFC-0001 §B.5, slice B6a: compile-time compat-manifest consumption —
  # no-op unless a `compatManifest` directive was found above. Must run
  # before `genVerifyBlock` so its `attached` bit (whether a manifest is
  # attached, ABI-ignored or not) can gate the degraded-tier warning.
  let appliedManifest = applyCompatManifest(ppmDynlib, baseNameLower, procs, manifestDirective)

  for verifyNode in genVerifyBlock(procs, baseName, appliedManifest.attached):
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
      let symOpt = findSymbol(appliedManifest.manifest, p.nameStr)
      if symOpt.isSome and symOpt.get.header[fkMismatch].len > 0:
        mismatchCNames.incl(p.nameStr)

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
      if p.nameStr in mismatchCNames:
        if p.isOptional: driftCandidates.add(p)
        else: requiredDriftCandidates.add(p)
  var driftCandidateNames: HashSet[string]
  for p in driftCandidates: driftCandidateNames.incl(p.nameStr)
  for p in requiredDriftCandidates: driftCandidateNames.incl(p.nameStr)

  # RFC-0001 §C.3, slice C4b design guidance (extended by C4c to the
  # required subset too): one drift-story seq per block —
  # `softlinkDriftStories<Base>: seq[tuple[symbol, story: string]]` —
  # populated at refusal time inside loadXxx below, scanned (linearly,
  # error-path only) by the wrapper's nil-pointer branch, and reset by
  # unloadXxx. Zero footprint when nothing could ever be refused (both
  # candidate lists empty): gated on the ACTUAL refusal-candidate lists,
  # not merely `appliedManifest.attached`, since a manifest with mismatch
  # facts but no probe, or `refuse = false`/`-d:softlinkNoDriftRefusal`,
  # generates no refusal code at all and would leave this var write-only.
  let driftStoriesName = ident("softlinkDriftStories" & baseName)
  if driftCandidates.len > 0 or requiredDriftCandidates.len > 0:
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
  for p in procs:
    let nameStr = newStrLitNode(p.nameStr)

    # Build arg list for forwarding call
    var callNode = newCall(p.ptrName)
    for i in 1 ..< p.formalParams.len:
      let identDefs = p.formalParams[i]
      for j in 0 ..< identDefs.len - 2:
        callNode.add(identDefs[j].copy())

    # nil check + call
    var wrapperBody = newStmtList()
    # RFC-0001 §C.3, slice C4b design guidance: for a symbol eligible for
    # drift refusal (`p.nameStr in driftCandidateNames` — always false,
    # hence a no-op addition, when this block has no such symbol), check
    # `softlinkDriftStories<Base>` FIRST: a hit means this pointer was
    # resolved once and then re-nilled for known drift, and the wrapper
    # must raise the FULL drift story, not the generic "not loaded"
    # message. A miss (never refused, or refused-but-not-THIS-symbol)
    # falls through to the unchanged `raiseNotLoaded` call below.
    var nilBranch = newStmtList()
    if p.nameStr in driftCandidateNames:
      let storySym = genSym(nskLet, "driftStory")
      nilBranch.add(newLetStmt(storySym,
        newCall(bindSym("findDriftStory"), driftStoriesName, nameStr)))
      nilBranch.add(newIfStmt((
        newNimNode(nnkInfix).add(ident(">"), newDotExpr(storySym, ident("len")), newIntLitNode(0)),
        newStmtList(newCall(ident("raiseDriftRefused"), libPatternLit, nameStr, storySym))
      )))
    nilBranch.add(newCall(ident("raiseNotLoaded"), libPatternLit, nameStr))
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
    wrapperProc.addPragma(newNimNode(nnkExprColonExpr).add(
      ident("raises"),
      newNimNode(nnkBracket).add(ident("SoftlinkError"))
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
    var loadBody = newStmtList()
    let missingName = ident("softlinkMissing")

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

    # handle = loadLibPattern(pattern)
    loadBody.add(newAssignment(handleName, newCall(ident("loadLibPattern"), libPatternLit)))

    # if handle.isNil: write this block's own "probe hasn't run" report
    # (RFC-0001 §9/§C.2, finding #11 — `probeNotRunFields()`: `atProbeNotRun`
    # if this block has a probe, else the bare zero-value `atNoProbe` — this
    # Phase-1 early return happens only before the first ever load, or right
    # after unloadX already reset the probe state vars to their own zero
    # values, so this IS the correct value here, not merely a placeholder)
    # + return LoadResult(kind: lrLibNotFound)
    loadBody.add(newIfStmt((
      newCall(ident("isNil"), handleName),
      unwindStmt(unloadHandle = false, resultKind = ident("lrLibNotFound"),
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
      let symName = newStrLitNode(p.nameStr)
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
      let symName = newStrLitNode(p.nameStr)
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
      var reportIf = newNimNode(nnkIfStmt)
      reportIf.add(newNimNode(nnkElifBranch).add(
        probeFailedName,
        newStmtList(assignCompatReportStmt(@[("attestation", ident("atProbeFailed"))]))
      ))
      reportIf.add(newNimNode(nnkElse).add(newStmtList(
        assignCompatReportStmt(@[
          ("runtimeVersion", probedVersionName),
          ("attestation", ident("atNoManifest"))])
      )))
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

      # RFC-0001 §C.3, slice C4c: every proc's own pointer var in this
      # block, for the required-refusal unwind's `resetPtrs` — a required
      # refusal walks back the ENTIRE load (mirroring unloadX's own
      # per-proc reset loop), not just the one drifted symbol's pointer.
      var allPtrNames: seq[NimNode] = @[]
      for p in procs: allPtrNames.add(p.ptrName)

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
        var sinceCNames: seq[string] = @[]
        var sinceVersions: seq[string] = @[]
        for p in procs:
          if p.isOptional and p.sinceVersion.len > 0:
            sinceCNames.add(p.nameStr)
            sinceVersions.add(p.sinceVersion)
        let missingPartitionSym = genSym(nskLet, "missingPartition")
        missingPartitionLet = newLetStmt(missingPartitionSym, newCall(
          bindSym("computeMissingPartition"),
          ident("softlinkCompatFacts" & baseName),
          missingName,
          newLit(sinceCNames),
          newLit(sinceVersions),
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
        let symNameLit = newStrLitNode(p.nameStr)
        let mismatchSym = genSym(nskLet, "reqMismatch")
        let versionSnapshotSym = genSym(nskLet, "reqDriftVersion")
        let reqMissingSym = genSym(nskVar, "reqMissingPartition")
        let storyExpr = newNimNode(nnkInfix).add(ident("&"),
          newNimNode(nnkInfix).add(ident("&"),
            newStrLitNode(p.nameStr & ": signature drift at "),
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
          seqOfTupleType([("symbol", "string"), ("reason", "MissingReason")]),
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
        hitStmts.add(newCall(newDotExpr(reqMissingSym, ident("add")),
          newNimNode(nnkTupleConstr).add(
            newNimNode(nnkExprColonExpr).add(ident("symbol"), symNameLit),
            newNimNode(nnkExprColonExpr).add(ident("reason"), ident("mrDriftRefused")))))
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
          seqOfTupleType([("symbol", "string"), ("reason", "MissingReason")]),
          newEmptyNode())))
        for p in driftCandidates:
          let symNameLit = newStrLitNode(p.nameStr)
          let mismatchSym = genSym(nskLet, "mismatch")
          let storyExpr = newNimNode(nnkInfix).add(ident("&"),
            newNimNode(nnkInfix).add(ident("&"),
              newStrLitNode(p.nameStr & ": signature drift at "),
              newCall(bindSym("formatInterval"), newCall(bindSym("get"), mismatchSym))),
            newStrLitNode(" per compat manifest; refusing unsafe dispatch"))
          var refuseStmts = newStmtList()
          refuseStmts.add(newAssignment(p.ptrName, newNilLit()))
          refuseStmts.add(newCall(newDotExpr(missingName, ident("add")), symNameLit))
          refuseStmts.add(newCall(newDotExpr(driftStoriesName, ident("add")),
            newNimNode(nnkTupleConstr).add(
              newNimNode(nnkExprColonExpr).add(ident("symbol"), symNameLit),
              newNimNode(nnkExprColonExpr).add(ident("story"), storyExpr))))
          refuseStmts.add(newCall(newDotExpr(driftPartitionSym, ident("add")),
            newNimNode(nnkTupleConstr).add(
              newNimNode(nnkExprColonExpr).add(ident("symbol"), symNameLit),
              newNimNode(nnkExprColonExpr).add(ident("reason"), ident("mrDriftRefused")))))
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
      attestedStmts.add(assignCompatReportStmt(@[
        ("runtimeVersion", probedVersionName),
        ("attestation", ident("atAttested"))] & attestedMissingFields))

      var corpusIf = newNimNode(nnkIfStmt)
      corpusIf.add(newNimNode(nnkElifBranch).add(
        newNimNode(nnkInfix).add(ident("in"), probedVersionName, corpusLit),
        attestedStmts
      ))
      corpusIf.add(newNimNode(nnkElse).add(newStmtList(
        assignCompatReportStmt(@[
          ("runtimeVersion", probedVersionName),
          ("attestation", ident("atOutOfCorpus"))] & missingPartitionFields)
      )))
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
    if driftCandidates.len > 0 or requiredDriftCandidates.len > 0:
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

proc collectVProcs(body: NimNode): tuple[procs: seq[SoftlinkProc], directive: CompatManifestDirective] =
  ## Parse a block of proc declarations for verification. Each must carry a
  ## calling convention and a {.header.} pragma (same rules as `dynlib`,
  ## enforced by the shared `parseProcPragmas`), but `optional`/`noverify`
  ## are rejected — the block exists solely to verify.
  var seenNames: HashSet[string]
  var manifestDirective: CompatManifestDirective
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
    if stmt.kind != nnkProcDef:
      error("verifyProcs body must contain only proc declarations (or a compatManifest directive)", stmt)
    let procName = stmt[0]
    let nameStr = $procName
    let formalParams = stmt[3]
    let hasReturn = formalParams[0].kind != nnkEmpty
    if nameStr in seenNames:
      error("duplicate proc '" & nameStr & "' in verifyProcs block", stmt)
    seenNames.incl(nameStr)
    let facts = parseProcPragmas(stmt, nameStr, ppmVerifyProcs)
    result.procs.add(SoftlinkProc(name: procName, nameStr: nameStr, ptrName: procName,
      formalParams: formalParams, callConv: facts.callConv, headerFile: facts.headerFile,
      isOptional: false, verifyWhen: facts.verifyWhen, prototype: facts.prototype,
      sinceVersion: facts.sinceVersion, hasReturn: hasReturn))
  result.directive = manifestDirective

macro verifyProcs*(body: untyped): untyped =
  ## Emit ONLY compile-time C header signature verification for the given proc
  ## declarations \u2014 no loading, no wrappers, no runtime footprint. Each proc
  ## needs a calling convention and a {.header.} pragma, exactly like `dynlib`.
  ##
  ## Use this to give statically-linked `{.importc.}` bindings the same
  ## `_Static_assert`-grade signature checking that `dynlib` performs for
  ## dynamic ones. This is identity-coherent with softlink: it *verifies* FFI
  ## signatures against headers; it does not perform static linking.
  let (procs, manifestDirective) = collectVProcs(body)
  let tag = if procs.len > 0: procs[0].nameStr else: "anon"
  # RFC-0001 SS4 B.5a, slice B6a: the compile-time subset (no lib-identity
  # check -- verifyProcs has no library identity to check against).
  let appliedManifest = applyCompatManifest(ppmVerifyProcs, "", procs, manifestDirective)
  result = newStmtList()
  for n in genVerifyBlock(procs, tag, appliedManifest.attached):
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
