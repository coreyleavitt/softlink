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
# Exported because macro-generated code resolves these identifiers at the call site.
export stdDynlib.LibHandle, stdDynlib.loadLibPattern, stdDynlib.symAddr,
       stdDynlib.unloadLib
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
    ## RFC-0001 §C.2, slice C2: `CompatReport.attestation` — five
    ## diagnostically distinct "how much do we trust this runtime" states,
    ## kept apart so a caller never has to infer "no information" from the
    ## absence of some other field (`atUnattested` collapsing `atNoManifest`
    ## and "probed but not in corpus" was the round-2 mistake the RFC
    ## itself calls out).
    atNoProbe      ## block declares no versionProbe, OR the probe never
                   ## ran (the load failed in Phase 1, before Phase 3/the
                   ## probe ever executed) — the zero value, by construction
                   ## the default for a freshly zero-initialized `CompatReport`.
    atProbeFailed  ## probe ran and raised, or returned an unparseable string
    atNoManifest   ## probe ok, but no compatManifest attached to check against
    atOutOfCorpus  ## probed version outside the manifest's harvested corpus
    atAttested     ## probed version inside the manifest's harvested corpus

  MissingReason* = enum
    ## RFC-0001 §C.2: why one `CompatReport.missing` symbol didn't resolve.
    ## The type is defined now (public surface); the partition that
    ## populates `missing` is later slices — C3 (`mrExpected`/`mrAnomalous`)
    ## and C4b/C4c (`mrDriftRefused`). Slice C2 itself never adds an entry.
    mrExpected      ## manifest/since: this runtime predates the symbol
    mrAnomalous     ## this version's headers declare it, yet it did not resolve
    mrDriftRefused  ## resolved, but refused for known signature drift (§C.3)

  CompatReport* = object
    ## RFC-0001 §C.2: a query proc (`fooCompat*(): CompatReport`) generated
    ## per `dynlib` block — deliberately NOT fields on `LoadResult` (dead
    ## weight on every non-attestation-relevant failure kind). Written on
    ## EVERY `loadX` return path (including the Phase-1 early returns, which
    ## do not write the cached `LoadResult`); `unloadX` resets it to this
    ## type's zero value (`atNoProbe`, `""`, `@[]`) alongside its other
    ## pointer/cache resets — `fooCompat()` after `unloadFoo()` must never
    ## serve a previous load's trust signals. `verifyProcs` generates no
    ## `fooCompat` at all (no runtime footprint, consistent with its
    ## `versionProbe` rejection).
    runtimeVersion*: string   ## "" unless the probe succeeded
    attestation*: Attestation
    missing*: seq[tuple[symbol: string, reason: MissingReason]]

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
  ## `AbsenceClass`) and `CompatReport.missing`'s `MissingReason`. Called
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

func toIncludeDirective(header: string): string =
  ## Convert a header path to a C #include directive.
  ## Supports angle-bracket syntax: ``"<mbedtls/ssl.h>"`` → ``#include <mbedtls/ssl.h>``
  ## and quoted syntax: ``"mbedtls/ssl.h"`` → ``#include "mbedtls/ssl.h"``
  if header.len >= 2 and header[0] == '<' and header[^1] == '>':
    "#include " & header & "\n"
  else:
    "#include \"" & header & "\"\n"

func emitPrototypeDecl(prototype: string, verifyWhen: string): string =
  ## Render RFC-0001 §3 A.1's vendored-prototype file-scope `extern`
  ## declaration for one proc's `{.prototype: "<C prototype>".}`. Emitted
  ## into the verify TU after the block's `#include`s (so named types
  ## resolve) and before the verify proc body — the same `includeCode`
  ## blob `genVerifyBlock` already builds for headers, just appended.
  ##
  ## Wrapped in `extern "C" { ... }` under the C++ backend: C11 6.7p4 makes
  ## an incompatible same-scope redeclaration a mandatory diagnostic, but
  ## without C linkage a drifted upstream declaration is a legal *overload*
  ## in C++ — overload resolution would quietly pick the header's
  ## declaration and the drift tripwire (benefit 3 of A.1) would never
  ## fire. The `#if defined(__cplusplus)` guard is inert (but present) in
  ## the C-backend output too — the emitted text is backend-agnostic; only
  ## the C preprocessor decides which branch survives.
  ##
  ## When `{.verifyWhen.}` is also present, the declaration itself is gated
  ## by the same `#if (EXPR)` as its assert (A.1: "composes... both the
  ## emitted declaration and its assert are gated by the #if") — needed
  ## when the vendored prototype references types absent from old headers.
  var decl = "#if defined(__cplusplus)\nextern \"C\" {\n#endif\n" &
    "extern " & prototype & ";\n" &
    "#if defined(__cplusplus)\n}\n#endif\n"
  if verifyWhen.len > 0:
    decl = "#if (" & verifyWhen & ") /* softlink verifyWhen: prototype decl */\n" &
      decl & "#endif /* softlink verifyWhen */\n"
  decl

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

type
  SoftlinkProc* = object
    name: NimNode
    nameStr: string
    ptrName: NimNode
    formalParams: NimNode
    callConv: string
    headerFile: string
    isOptional: bool
    noVerify: bool
    noVerifyReason: string  ## RFC-0001 §3 A.2: {.noverify: "why".} justification; "" if none given
    verifyWhen: string  ## C preprocessor expr gating verification; "" = always
    prototype: string   ## raw {.prototype: "...".} string; "" if absent
    sinceVersion: string  ## RFC-0001 §B.5/§C.2: {.since: "x.y.z".} claim; "" if absent
    hasReturn: bool

func pragmaKeyName(pragma: NimNode): string =
  ## The identifying name of a proc pragma node: bare (`cdecl`) or
  ## key:value (`header: "foo.h"`). "" for shapes we don't recognize.
  if pragma.kind == nnkIdent: $pragma
  elif pragma.kind == nnkExprColonExpr: $pragma[0]
  else: ""

proc parseVerifyWhenExpr(pragma, stmt: NimNode): string =
  ## Extract and validate the {.verifyWhen: "EXPR".} condition — a non-empty
  ## C preprocessor expression string. Shared by `dynlib` and `verifyProcs`.
  if pragma.kind == nnkExprColonExpr and
     pragma[1].kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit} and
     pragma[1].strVal.strip().len > 0:
    pragma[1].strVal
  else:
    error("verifyWhen pragma requires a non-empty C preprocessor " &
          "expression (e.g., {.verifyWhen: \"FOO_VERSION >= 0x0300\".})", stmt)
    ""

proc parseSinceExpr(pragma, stmt: NimNode, nameStr: string): string =
  ## RFC-0001 §C.2/§B.5, slice B6a: extract and validate one proc's
  ## {.since: "x.y.z".} claim — a non-empty string literal that must
  ## additionally `parseVersion` successfully (`softlink/versions`), since
  ## a lower bound that can't even be compared is worse than none. Shared
  ## by `dynlib` and `verifyProcs`: the since-contradiction check
  ## (`softlink/manifest.checkSince`) needs it in both, and Stage C's
  ## runtime consumption (§C.2/§C.3, `dynlib`-only) is a separate, later
  ## concern from this pragma's parse.
  if pragma.kind == nnkExprColonExpr and
     pragma[1].kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit} and
     pragma[1].strVal.strip().len > 0:
    let v = pragma[1].strVal
    if parseVersion(v).isNone:
      error("proc '" & nameStr & "': since pragma value '" & v &
            "' does not parse as a version (softlink/versions.parseVersion " &
            "found no digit or alphabetic run in it)", stmt)
    v
  else:
    error("proc '" & nameStr &
          "' since pragma requires a non-empty version string literal " &
          "(e.g., {.since: \"4.15.0\".})", stmt)
    ""

proc parseNoVerifyReasonExpr(pragma, stmt: NimNode, nameStr: string): string =
  ## RFC-0001 §3 A.2: extract the optional {.noverify: "justification".}
  ## string. Bare `{.noverify.}` (an `nnkIdent`, no colon) carries no
  ## justification — "" is returned, and the hint falls back to
  ## "(no justification)". When a value IS supplied (`nnkExprColonExpr`),
  ## it must be a non-empty string literal (same shape as `verifyWhen`);
  ## anything else is a macro error rather than a silent discard — the
  ## whole point of A7 is that this string is no longer thrown away.
  if pragma.kind == nnkExprColonExpr:
    if pragma[1].kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit} and
       pragma[1].strVal.strip().len > 0:
      pragma[1].strVal
    else:
      error("proc '" & nameStr & "': noverify justification must be a " &
            "non-empty string literal (e.g., {.noverify: \"private " &
            "symbol, no public header\".}), or omit the value entirely " &
            "for {.noverify.} with no justification", stmt)
      ""
  else:
    ""

type
  PrototypeTokenKind = enum
    ## `ptkIdent`: a C identifier (`[A-Za-z_][A-Za-z0-9_]*`) — this includes
    ## C keywords like `const`/`void`; the tokenizer does no declarator-
    ## grammar analysis, so callers filter keywords themselves if needed
    ## (see A6's builtin-type detection).
    ## `ptkPunct`: single-character punctuation (`(`, `)`, `*`, `,`, `;`,
    ## `[`, `]`, ...), or the three-character `...` ellipsis, emitted as one
    ## token.
    ptkIdent
    ptkPunct

  PrototypeToken = object
    ## One token of a tokenized C prototype string. `depth` is the paren
    ## nesting level: for identifiers/other punctuation it's the level the
    ## token sits at; for `(`/`)` it's the level of the group being opened/
    ## closed (i.e. a matching `(`/`)` pair share the same `depth`), so "the
    ## first `(` at paren depth 0" (RFC-0001 §3 A.1) is exactly
    ## `tokens.find(tok => tok.text == "(" and tok.depth == 0)`.
    ## Fields are exported (not the type itself) so the test suite — which
    ## imports this module with `{.all.}` — can unit-test the tokenizer
    ## directly; object field visibility is independent of `{.all.}`.
    kind*: PrototypeTokenKind
    text*: string
    depth*: int

func tokenizePrototype(prototype: string): seq[PrototypeToken] =
  ## Minimal C-prototype tokenizer: identifiers, punctuation, and paren
  ## depth only — no full declarator grammar (RFC-0001 §3 A.1, "round 2"
  ## name-extraction rule). A pure function, reused as-is by two consumers:
  ## A1's name extraction / function-pointer-return / variadic detection
  ## (`analyzePrototype` below), and (later) A6's builtin-type detection,
  ## which scans the same identifier tokens against a builtin-type
  ## allowlist. Whitespace (including embedded newlines/indentation from
  ## triple-quoted, upstream-formatted prototypes) is skipped entirely —
  ## inert for tokenization, exactly as it is in the emitted C.
  var i = 0
  var depth = 0
  let n = prototype.len
  while i < n:
    let c = prototype[i]
    if c in Whitespace:
      inc i
    elif c == '_' or c.isAlphaAscii:
      let start = i
      inc i
      while i < n and (prototype[i] == '_' or prototype[i].isAlphaNumeric):
        inc i
      result.add(PrototypeToken(kind: ptkIdent, text: prototype[start ..< i], depth: depth))
    elif c == '.' and i + 2 < n and prototype[i + 1] == '.' and prototype[i + 2] == '.':
      result.add(PrototypeToken(kind: ptkPunct, text: "...", depth: depth))
      i += 3
    elif c == '(':
      result.add(PrototypeToken(kind: ptkPunct, text: "(", depth: depth))
      inc depth
      inc i
    elif c == ')':
      if depth > 0: dec depth
      result.add(PrototypeToken(kind: ptkPunct, text: ")", depth: depth))
      inc i
    else:
      # Any other single character (`*`, `,`, `;`, `[`, `]`, digits of a
      # numeric literal, ...) — inert for the rules above, emitted
      # one-at-a-time so paren depth stays exact around it.
      result.add(PrototypeToken(kind: ptkPunct, text: $c, depth: depth))
      inc i

type
  PrototypeAnalysis = object
    ## A1-specific analysis over one prototype's token stream. Fields
    ## exported for the same `{.all.}`-import reason as `PrototypeToken`.
    ok*: bool                       ## false: no depth-0 '(' found (malformed)
    name*: string                   ## identifier before the first depth-0 '('
    isFunctionPointerReturn*: bool  ## '(' immediately followed by '*' — name
                                     ## is nested inside the return type
    hasVariadic*: bool              ## a `...` token appears anywhere

func analyzePrototype(prototype: string): PrototypeAnalysis =
  ## Run the shared tokenizer and extract the facts A1's prototype
  ## validation needs: the candidate symbol name, whether the prototype has
  ## a function-pointer return type (name unextractable — the classic
  ## `void (*signal(int, void (*)(int)))(int)` shape), and whether it's
  ## variadic. Pure function over `tokenizePrototype`'s output; kept
  ## separate from the tokenizer itself so A6 can consume the token stream
  ## directly without inheriting A1's naming rules.
  let tokens = tokenizePrototype(prototype)
  var parenIdx = -1
  for idx, tok in tokens:
    if tok.kind == ptkPunct and tok.text == "(" and tok.depth == 0:
      parenIdx = idx
      break
  if parenIdx == -1:
    return PrototypeAnalysis(ok: false)
  result.ok = true
  if parenIdx + 1 < tokens.len and tokens[parenIdx + 1].text == "*":
    result.isFunctionPointerReturn = true
  elif parenIdx > 0 and tokens[parenIdx - 1].kind == ptkIdent:
    result.name = tokens[parenIdx - 1].text
  for tok in tokens:
    if tok.text == "...":
      result.hasVariadic = true
      break

const builtinCTypeKeywords = [
  ## RFC-0001 §3 A.1, slice A6: the C keywords a prototype can use without
  ## needing any header to resolve them — base types, qualifiers, and
  ## storage-adjacent keywords that are part of the C grammar itself
  ## rather than something a header `typedef`s or declares as a struct/
  ## enum tag. Deliberately excludes `size_t`/`ptrdiff_t`/etc. — those are
  ## real typedefs from `<stddef.h>` and friends, not language keywords, so
  ## a prototype using them genuinely does need a header (or at least the
  ## standard one that defines them; softlink does not special-case the
  ## standard library headers per RFC-0001 §3 A.1: "softlink does not
  ## attempt full detection").
  "void", "char", "short", "int", "long", "float", "double",
  "signed", "unsigned", "const", "volatile", "restrict",
  "_Bool", "_Complex", "_Imaginary"
]

func nonBuiltinIdentifiers(prototype: string): seq[string] =
  ## RFC-0001 §3 A.1, slice A6: scan a vendored prototype for identifiers
  ## that are neither the C builtin-type allowlist above nor (best-effort)
  ## the function name / parameter names, returning them in first-seen
  ## order with duplicates removed. A non-empty result means the prototype
  ## references a typedef/struct/enum tag only a header could define —
  ## exactly the case where dropping `{.header.}` is likely a mistake.
  ##
  ## Reuses the shared A1 tokenizer (`tokenizePrototype`) — "one primitive,
  ## two consumers" per that proc's doc comment. Deliberately NOT a full
  ## declarator parse (RFC: "softlink does not attempt full detection"):
  ## - The return type is every depth-0 token before the first depth-0
  ##   `(`, minus the trailing one (the function name itself — already
  ##   validated elsewhere to match the proc's Nim name).
  ## - Each top-level parameter is a comma-separated span at depth 1
  ##   between the matching parens. Only that parameter's OWN depth-1
  ##   tokens are considered; anything nested deeper (a function-pointer
  ##   parameter's internal parameter list, e.g. the `cb`/`int` inside
  ##   `void (*cb)(int)`) is out of scope and simply not classified —
  ##   erring toward fewer false hints rather than more, on the
  ##   documented assumption that this rare shape is not the common case
  ##   this hint targets.
  ## - Within a parameter's depth-1 tokens, a trailing identifier is
  ##   treated as the parameter's NAME (not its type) whenever something
  ##   else precedes it (`unsigned char y` → `y` is the name); a lone
  ##   identifier with nothing else in the parameter is instead an
  ##   unnamed, typedef'd-type parameter (`Z3_context` alone) and IS
  ##   classified — C prototypes have no other way to write "a single
  ##   bare identifier" in a parameter position.
  let tokens = tokenizePrototype(prototype)
  var parenIdx = -1
  for idx, tok in tokens:
    if tok.kind == ptkPunct and tok.text == "(" and tok.depth == 0:
      parenIdx = idx
      break
  if parenIdx == -1:
    return @[]  # malformed; parsePrototypePragma already reports this

  var seen: HashSet[string]
  template consider(tok: PrototypeToken) =
    if tok.kind == ptkIdent and tok.text notin builtinCTypeKeywords and
       tok.text notin seen:
      seen.incl(tok.text)
      result.add(tok.text)

  # Return-type identifiers: depth-0 tokens before the paren, minus the
  # trailing function-name token.
  for i in 0 ..< parenIdx - 1:
    consider(tokens[i])

  # The matching close paren that returns to depth 0.
  var closeIdx = -1
  for idx in parenIdx + 1 ..< tokens.len:
    if tokens[idx].kind == ptkPunct and tokens[idx].text == ")" and
       tokens[idx].depth == 0:
      closeIdx = idx
      break
  if closeIdx == -1:
    return  # malformed; shouldn't happen once parsePrototypePragma passed

  # Parameter spans: split the range between the parens on depth-1 commas.
  var segStart = parenIdx + 1
  var segments: seq[tuple[a, b: int]]
  for idx in parenIdx + 1 ..< closeIdx:
    if tokens[idx].kind == ptkPunct and tokens[idx].text == "," and
       tokens[idx].depth == 1:
      segments.add((segStart, idx))
      segStart = idx + 1
  segments.add((segStart, closeIdx))

  for (a, b) in segments:
    var depth1: seq[PrototypeToken]
    for idx in a ..< b:
      if tokens[idx].depth == 1: depth1.add(tokens[idx])
    if depth1.len == 0:
      continue
    let dropTrailingName = depth1.len > 1 and depth1[^1].kind == ptkIdent
    let stop = if dropTrailingName: depth1.len - 1 else: depth1.len
    for i in 0 ..< stop:
      consider(depth1[i])

proc parsePrototypePragma(pragma, stmt: NimNode, nameStr: string): tuple[raw, name: string] =
  ## Extract and validate the `{.prototype: "<C prototype>".}` pragma
  ## (RFC-0001 §3 A.1): a non-empty string literal — triple-quoted/
  ## multi-line strings are explicitly blessed so upstream's own
  ## multi-line formatting can be pasted verbatim — containing a single C
  ## function prototype. Runs the shared tokenizer-based name extraction,
  ## rejects function-pointer return types (name unextractable — route
  ## through a typedef'd return type instead), rejects `...` (variadic —
  ## mirrors the existing `varargs` rejection: C lets you call a variadic
  ## function with only its fixed arguments, so the assert would type-check
  ## without verifying the variadic tail), and requires the extracted name
  ## to match the proc's C name. Shared by `dynlib` and `verifyProcs` —
  ## both select a declaration source on this axis (RFC-0001 §3, "four
  ## pragma axes"). A1 only validates; nothing is emitted from the result
  ## yet (extern declaration + verify-TU wiring is slice A2).
  if not (pragma.kind == nnkExprColonExpr and
          pragma[1].kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit}):
    error("proc '" & nameStr & "': prototype pragma requires a C prototype " &
          "string literal (e.g., {.prototype: \"int " & nameStr &
          "(int x)\".}); triple-quoted strings are accepted for upstream's " &
          "own multi-line formatting", stmt)
    ("", "")
  else:
    let raw = pragma[1].strVal
    if raw.strip().len == 0:
      error("proc '" & nameStr &
            "': prototype pragma requires a non-empty C prototype string", stmt)
      ("", "")
    else:
      let analysis = analyzePrototype(raw)
      if not analysis.ok:
        error("proc '" & nameStr & "': could not find a top-level '(' " &
              "introducing the parameter list in prototype: " & raw, stmt)
        (raw, "")
      elif analysis.isFunctionPointerReturn:
        error("proc '" & nameStr & "': prototype has a function-pointer " &
              "return type, so its name is nested inside the return type " &
              "(e.g. `void (*signal(int))(int)`) and can't be extracted " &
              "by name — introduce a typedef for the return type and use " &
              "it instead (e.g. `typedef void (*signal_handler)(int); " &
              "signal_handler signal(int)`)", stmt)
        (raw, "")
      elif analysis.hasVariadic:
        error("proc '" & nameStr & "': prototype must not be variadic " &
              "('...') — mirrors the existing varargs rejection: C " &
              "permits calling a variadic function with only its fixed " &
              "arguments, so the compile-time check would type-check " &
              "without verifying the variadic tail; write a prototype " &
              "for the fixed-arity form only", stmt)
        (raw, "")
      elif analysis.name != nameStr:
        error("proc '" & nameStr & "': prototype declares '" & analysis.name &
              "', which does not match the proc's name '" & nameStr &
              "' — the prototype must describe the same C symbol as the " &
              "proc", stmt)
        (raw, "")
      else:
        (raw, analysis.name)

type
  ProcPragmaMode = enum
    ## Which caller is parsing pragmas — `dynlib` and `verifyProcs` share the
    ## same token recognition but disagree on what `optional`/`noverify` mean
    ## (dynlib: runtime-optional escape hatches; verifyProcs: meaningless,
    ## since the block exists solely to verify) and on their diagnostic
    ## wording. New pragmas Stage A adds (`prototype`, etc.) get their rules
    ## defined once here instead of drifting between two hand-rolled loops.
    ppmDynlib
    ppmVerifyProcs

  ProcPragmaFacts = object
    ## Pragma-derived facts for one proc, independent of the proc's name/
    ## signature — merged by each caller into its own per-proc record
    ## (`SoftlinkProc`).
    callConv*: string
    headerFile*: string
    isOptional*: bool
    noVerify*: bool
    noVerifyReason*: string  ## RFC-0001 §3 A.2: {.noverify: "why".} justification; "" if none given
    verifyWhen*: string  ## C preprocessor expr gating verification; "" = always
    prototype*: string   ## raw {.prototype: "...".} string; "" if absent
    prototypeName*: string  ## tokenizer-extracted C name; "" if absent
    sinceVersion*: string  ## RFC-0001 §B.5/§C.2: {.since: "x.y.z".} claim; "" if absent

const callingConventions = ["cdecl", "stdcall", "fastcall", "syscall", "noconv"]

proc parseProcPragmas(stmt: NimNode, nameStr: string, mode: ProcPragmaMode): ProcPragmaFacts =
  ## Parse and validate one proc's pragma list, enforcing the calling-convention
  ## + header + optional/noverify/verifyWhen rules shared by `dynlib` and
  ## `verifyProcs`. All error/hint reporting for pragma recognition and the
  ## cross-pragma rules lives here; callers only add their own per-proc
  ## bookkeeping (name collisions, formal params, etc.) around the call.
  ##
  ## Mode-specific behavior preserved from the pre-extraction code:
  ## - `ppmDynlib`: `optional` and `noverify` are accepted; a second calling
  ##   convention pragma is a hard error; `header` is required unless
  ##   `noverify`; `verifyWhen` + `noverify` together is a contradiction error.
  ## - `ppmVerifyProcs`: `optional` and `noverify` are rejected (the latter
  ##   with its own wording — "meaningless in verifyProcs"); a repeated
  ##   calling convention pragma is silently overwritten by the last one
  ##   (matching the original `collectVProcs`, which never checked for
  ##   duplicates); `header` is unconditionally required.
  let macroName = if mode == ppmDynlib: "dynlib" else: "verifyProcs"
  let pragmas = stmt[4]
  if pragmas.kind == nnkPragma:
    for pragma in pragmas:
      let pragmaName = pragmaKeyName(pragma)
      if pragmaName in callingConventions:
        if mode == ppmDynlib and result.callConv != "":
          error("proc '" & nameStr & "' has multiple calling conventions", stmt)
        result.callConv = pragmaName
      elif pragmaName == "optional":
        if mode == ppmDynlib:
          result.isOptional = true
        else:
          error("verifyProcs does not support pragma 'optional' on proc '" &
                nameStr & "'", stmt)
      elif pragmaName == "noverify":
        if mode == ppmDynlib:
          result.noVerify = true
          result.noVerifyReason = parseNoVerifyReasonExpr(pragma, stmt, nameStr)
        else:
          error("noverify is meaningless in verifyProcs — the block exists " &
                "solely to verify; simply omit proc '" & nameStr & "'", stmt)
      elif pragmaName == "verifyWhen":
        result.verifyWhen = parseVerifyWhenExpr(pragma, stmt)
      elif pragmaName == "since":
        result.sinceVersion = parseSinceExpr(pragma, stmt, nameStr)
      elif pragmaName == "prototype":
        let (raw, name) = parsePrototypePragma(pragma, stmt, nameStr)
        result.prototype = raw
        result.prototypeName = name
      elif pragmaName == "header":
        if pragma.kind == nnkExprColonExpr:
          result.headerFile = pragma[1].strVal
        else:
          error("header pragma requires a value (e.g., {.header: \"foo.h\".})", stmt)
      elif pragmaName != "":
        error(macroName & " does not support pragma '" & pragmaName &
              "' on proc '" & nameStr & "'", stmt)

  if result.callConv == "":
    error("proc '" & nameStr &
          "' must specify a calling convention pragma (e.g., {.cdecl.})", stmt)

  if mode == ppmDynlib:
    if result.noVerify and result.verifyWhen.len > 0:
      error("proc '" & nameStr & "': {.verifyWhen.} contradicts {.noverify.} — " &
            "one requests conditional verification, the other none. Use " &
            "verifyWhen alone for symbols the header declares only in some " &
            "versions, or noverify alone for symbols no header declares", stmt)
    if result.noVerify and result.prototype.len > 0:
      error("proc '" & nameStr & "': {.prototype.} contradicts {.noverify.} — " &
            "both select a declaration source (a vendored prototype to " &
            "verify against vs. skipping verification entirely). Use " &
            "prototype alone if you have a vendored C declaration, or " &
            "noverify alone if none exists", stmt)
    if result.headerFile == "" and not result.noVerify and result.prototype.len == 0:
      error("proc '" & nameStr &
            "' must specify a header pragma (e.g., {.header: \"foo.h\".}), " &
            "a prototype pragma (e.g., {.prototype: \"" & nameStr &
            "(...)\".}), or {.noverify.} to skip compile-time header " &
            "verification", stmt)
  else:
    if result.headerFile == "" and result.prototype.len == 0:
      error("proc '" & nameStr &
            "' must specify a header pragma (e.g., {.header: \"foo.h\".}) " &
            "or a prototype pragma (e.g., {.prototype: \"" & nameStr &
            "(...)\".})", stmt)

  # RFC-0001 §3 A.1, slice A6: "`header` becomes optional when `prototype`
  # is present iff the prototype uses only builtin C types. softlink does
  # not attempt full detection, but when `header` is absent and the
  # prototype contains identifiers outside a builtin-type allowlist ...
  # it emits a hint ... so the failure mode is a softlink diagnostic first
  # and a raw C error second." The lift itself stays unconditional (slice
  # A1/A2 behavior, preserved) — this is diagnostic-only, never an error:
  # a non-builtin identifier is *usually* a sign `{.header.}` was dropped
  # by mistake, but the RFC never demotes that to a hard requirement, and
  # cross-checking (`prototype` + `header` together) is a legitimate
  # reason to still have no builtin-only prototype rejected. Shared by
  # both modes — `dynlib` and `verifyProcs` disagree on nothing here.
  # Same hint-normally/warning-under-strict convention as the {.noverify.}
  # trust-point hint below (RFC design principle 2: "trust points are
  # visible").
  if result.headerFile == "" and result.prototype.len > 0:
    let unresolved = nonBuiltinIdentifiers(result.prototype)
    if unresolved.len > 0:
      let msg = "softlink: " & macroName & ": proc '" & nameStr &
        "': this prototype may need `header:` to resolve " &
        unresolved.join(", ")
      when defined(softlinkStrictVerify):
        warning(msg, stmt)
      else:
        hint(msg, stmt)

## RFC-0001 §B.5's "erroring stub" message: exported so a
## `compatManifest(...)` call OUTSIDE a `dynlib`/`verifyProcs` block
## resolves, via ordinary overload resolution, to the `compatManifest`
## proc below — whose `{.error.}` pragma turns the call into a
## softlink-authored diagnostic instead of a bare "undeclared
## identifier" (the #14 lesson, reapplied here: an opaque compiler
## error pointing nowhere useful is worse than a clear one).
## Correctly-placed directives never reach that proc at all — the
## `dynlib`/`verifyProcs` macros recognize and consume the
## `compatManifest` statement structurally (see `isCompatManifestCall`
## below) and never re-emit it into the generated code, exactly like
## every proc declaration in the same body is consumed and regenerated
## rather than passed through verbatim.
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
## `isVersionProbeStmt` below) before it is ever resolved as an identifier;
## `verifyProcs` does the same, but ALWAYS rejects it with its own
## directive-specific error (no runtime footprint there — see
## `collectVProcs`).
const versionProbeStubMsg =
  "softlink: versionProbe is a body directive of dynlib blocks (RFC-0001 " &
  "§9/§C.1) — it must appear directly inside a `dynlib \"lib\": ...` " &
  "block (e.g. `versionProbe: parseFooVersion($Foo_get_version())`), not " &
  "called outside one."

template versionProbe*(body: untyped) {.error: versionProbeStubMsg.} =
  discard

type
  CompatManifestDirective = object
    ## RFC-0001 §B.5/§B.5a, slice B6a: one parsed `compatManifest` body
    ## directive. `present == false` is the zero value (no directive in
    ## this block) — every check downstream short-circuits on it.
    present: bool
    pathLit: string     ## the string literal argument, as written
    refuse: bool         ## parsed value of `refuse = ...`; false if absent
    refuseGiven: bool    ## RFC-0001 §B.5a: was `refuse` written at all?
                         ## (verifyProcs rejects it outright regardless of
                         ## value — "nothing to refuse" there)
    node: NimNode        ## the directive call node, for diagnostic anchoring

func isCompatManifestCall(stmt: NimNode): bool =
  ## True when `stmt` is a `compatManifest ...` directive statement —
  ## `compatManifest "path"` (parses as `nnkCommand`) or
  ## `compatManifest("path", refuse = true)` (`nnkCall`). Checked
  ## structurally against the bare identifier text, exactly like every
  ## other body-shape recognition in this file (`stmt.kind != nnkProcDef`
  ## below) — the block's body is `untyped`, so nothing has been resolved
  ## to an actual symbol yet; that only happens (deliberately) for a
  ## MISPLACED directive, via the erroring stub above.
  stmt.kind in {nnkCall, nnkCommand} and stmt.len >= 1 and
    stmt[0].kind == nnkIdent and $stmt[0] == "compatManifest"

proc parseCompatManifestDirective(stmt: NimNode, macroName: string): CompatManifestDirective =
  ## RFC-0001 §B.5: parse one recognized `compatManifest` directive
  ## statement's argument shape — a string literal path, and an optional
  ## `refuse = <bool literal>` named argument (§5.3's drift-refusal scope
  ## flag; this slice only parses and stores it, see `refuseGiven` above).
  ## Any other shape (non-literal path, unknown named arg, non-bool
  ## `refuse`, or a bare `compatManifest` with no path at all) is a
  ## directive-specific macro error here, never the generic body-shape
  ## error `dynlib`/`verifyProcs` raise for an unrecognized statement.
  result.present = true
  result.node = stmt
  var pathSet = false
  for i in 1 ..< stmt.len:
    let arg = stmt[i]
    if arg.kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit} and not pathSet:
      result.pathLit = arg.strVal
      pathSet = true
    elif arg.kind == nnkExprEqExpr and arg.len == 2 and
         arg[0].kind == nnkIdent and $arg[0] == "refuse":
      result.refuseGiven = true
      if arg[1].kind == nnkIdent and $arg[1] in ["true", "false"]:
        result.refuse = $arg[1] == "true"
      else:
        error(macroName & ": compatManifest's 'refuse' argument must be a " &
              "bool literal (true or false)", stmt)
    else:
      error(macroName & ": compatManifest directive has an unrecognized " &
            "argument — expected compatManifest(\"lib.compat.json\") or " &
            "compatManifest(\"lib.compat.json\", refuse = true/false)", stmt)
  if not pathSet:
    error(macroName & ": compatManifest requires a string literal manifest " &
          "path, e.g. compatManifest(\"z3.compat.json\")", stmt)
  if result.pathLit.strip().len == 0 and pathSet:
    error(macroName & ": compatManifest's manifest path must be non-empty", stmt)

proc compatManifestDupError(macroName: string, first, second: CompatManifestDirective): string =
  ## RFC-0001 §B.5: "at most one compatManifest per block, any position."
  ## Voiced like the existing #14 dup-block guard (`src/softlink.nim`'s
  ## `dynlib` macro) — softlink-authored, names both paths, tells the
  ## author what to do, never an opaque "redefinition of ...".
  "softlink: " & macroName & ": duplicate compatManifest directive in one " &
  "block ('" & first.pathLit & "' and '" & second.pathLit & "') — merge " &
  "them into a single compatManifest directive; a dynlib/verifyProcs " &
  "block may attach at most one compat manifest."

type
  VersionProbeDirective = object
    ## RFC-0001 §9/§C.1, slice C1b: one parsed `versionProbe` body
    ## directive — at most one per `dynlib` block, any position (mirrors
    ## `CompatManifestDirective` above). `present == false` is the zero
    ## value (no directive in this block). A malformed shape (see
    ## `parseVersionProbeDirective`) still sets `present = true` — having
    ## already reported its own directive-specific error — but leaves
    ## `bodyStmts` as an empty `nnkStmtList`, so every downstream check
    ## keyed on "does this block have a REAL probe to splice/guard for"
    ## tests `present and bodyStmts.len > 0` rather than crashing on a nil
    ## node or double-reporting the same mistake.
    present: bool
    bodyStmts: NimNode
    node: NimNode

func isVersionProbeStmt(stmt: NimNode): bool =
  ## True when `stmt` is a `versionProbe` directive statement in ANY shape:
  ## bare `versionProbe` (parses as a plain `nnkIdent`), `versionProbe()`
  ## (an `nnkCall` with no further arguments), or the well-formed
  ## `versionProbe: <body>` (an `nnkCall` whose last argument is a
  ## `nnkStmtList` — Nim's colon-block call sugar). Checked structurally
  ## against the bare identifier text, exactly like `isCompatManifestCall`
  ## above — the block's body is `untyped`, so nothing has been resolved to
  ## an actual symbol yet; that only happens (deliberately) for a directive
  ## written OUTSIDE any block, via the erroring stub template above.
  (stmt.kind == nnkIdent and $stmt == "versionProbe") or
  (stmt.kind == nnkCall and stmt.len >= 1 and stmt[0].kind == nnkIdent and
   $stmt[0] == "versionProbe")

proc parseVersionProbeDirective(stmt: NimNode, macroName: string): VersionProbeDirective =
  ## RFC-0001 §9/§C.1: parse one recognized `versionProbe` directive
  ## statement. The only well-formed shape is `versionProbe: <stmts>` — an
  ## `nnkCall` of exactly two children, the second an `nnkStmtList`. Every
  ## other shape reaching here (bare `versionProbe`, empty-parens
  ## `versionProbe()`, or a plain call `versionProbe(someArg)`) is a
  ## directive-specific macro error, never the generic "body must contain
  ## only proc declarations" error `dynlib` raises for an unrecognized
  ## statement shape.
  result.present = true
  result.node = stmt
  result.bodyStmts = newStmtList()
  if stmt.kind == nnkCall and stmt.len == 2 and stmt[1].kind == nnkStmtList:
    result.bodyStmts = stmt[1]
  else:
    error(macroName & ": versionProbe requires a statement body returning " &
          "a version string — write `versionProbe: <expr-or-stmts>` (e.g. " &
          "`versionProbe: parseZ3Version($Z3_get_full_version())`); bare " &
          "`versionProbe` or `versionProbe()` with no block is not a " &
          "valid probe", stmt)

## RFC-0001 §9/§C.1: "at most one versionProbe per block, any position."
## Voiced like `compatManifestDupError` above (itself voiced like the #14
## dup-block guard) — softlink-authored, tells the author what to do,
## never an opaque redeclaration error. Only `dynlib` ever reaches this —
## `verifyProcs` rejects EVERY `versionProbe` occurrence outright (see
## `collectVProcs`), so there is no separate "duplicate" concept there.
const versionProbeDupErrorMsg =
  "softlink: dynlib: duplicate versionProbe directive in one block — " &
  "merge the probes into a single versionProbe: body; a dynlib block may " &
  "contain at most one version probe."

type
  AppliedManifest = object
    ## RFC-0001 §B.5/§9, slice B6b: `applyCompatManifest`'s return value.
    ## `attached` is the one bit `genVerifyBlock` has needed since B6a
    ## ("a manifest was attached AND not ABI-ignored"); `manifest` is the
    ## fully parsed `CompatManifest` itself — meaningful only when
    ## `attached` is true — which the `dynlib` macro's NEW const-embedding
    ## codegen (`softlinkCompatFacts<Base>`, RFC §B.5) needs downstream.
    ## This is the exact seam the B6a handoff doc flagged: B6a returned a
    ## bare `bool` because nothing yet needed the parsed manifest back;
    ## B6b is that consumer.
    attached*: bool
    manifest*: CompatManifest

proc applyCompatManifest(mode: ProcPragmaMode, libNameForIdentity: string,
                          procs: seq[SoftlinkProc],
                          directive: CompatManifestDirective): AppliedManifest =
  ## RFC-0001 §B.5/§B.5a, slice B6a (return shape extended in B6b): the
  ## compile-time manifest-consumption orchestration. Every actual
  ## DECISION is a pure `softlink/manifest` predicate (independently
  ## unit-tested there); this proc's only job is sequencing them in the
  ## RFC's own order and turning each into an `error`/`warning`/`hint`
  ## anchored at the directive or the offending proc. No runtime behavior
  ## changes here — everything below runs at macro-expansion time only,
  ## and without a `compatManifest` directive this proc returns
  ## immediately (additive: existing blocks are byte-for-byte unaffected).
  ##
  ## Returns `AppliedManifest(attached: true, manifest: m)` iff a manifest
  ## was attached AND not ABI-ignored; every early-return path below
  ## (missing directive, unreadable file, malformed JSON, unsupported
  ## schema, wrong lib, ABI mismatch) yields the zero value —
  ## `attached: false` via a bare `return`, `manifest` left as the
  ## zero-value `CompatManifest` (never read by a caller that checks
  ## `attached` first, per the field doc above).
  if not directive.present: return

  let macroName = if mode == ppmDynlib: "dynlib" else: "verifyProcs"

  # RFC-0001 §B.5a: verifyProcs has no loadX/drift-refusal surface at all —
  # an ACCEPTED `refuse` argument would silently promise a policy knob that
  # does nothing ("an accepted-but-dead parameter would be a lie").
  if mode == ppmVerifyProcs and directive.refuseGiven:
    error(macroName & ": compatManifest's 'refuse' argument has nothing " &
          "to refuse on verifyProcs — there is no loadX/drift-refusal " &
          "surface here (RFC-0001 §B.5a); omit 'refuse' entirely",
          directive.node)

  # Path resolution: relative to the MODULE containing this block (the
  # directive call node's own line info), never the compiler's cwd — a
  # binding package ships its manifest alongside its module.
  let absPath = directive.node.lineInfoObj.filename.parentDir / directive.pathLit
  if not fileExists(absPath):
    error("softlink: " & macroName & ": compatManifest: manifest file not " &
          "found: " & absPath, directive.node)
    return

  # `staticRead` (not a plain compile-time `readFile`) registers the
  # manifest as a compile dependency, so editing it retriggers
  # compilation — design guidance's stated reason for preferring it here.
  let jsonText = staticRead(absPath)
  var m: CompatManifest
  try:
    m = parseManifest(jsonText, absPath)
  except ManifestError as e:
    error(e.msg, directive.node)
    return

  # Check 2: schema policy — an unsupported (newer) schema is a compile
  # error naming the required schema, never a silent partial read.
  if not schemaSupported(m):
    error("softlink: " & macroName & ": compat manifest " & absPath &
          " has schema " & $m.schema & ", but this softlink version only " &
          "supports schema " & $supportedSchema & " — upgrade softlink to " &
          "consume it", directive.node)
    return

  # Check 3: lib identity (dynlib only — verifyProcs has no library
  # identity to check against, RFC-0001 §B.5a).
  if mode == ppmDynlib:
    if not libIdentityOk(m, libNameForIdentity):
      error("softlink: dynlib: compat manifest " & absPath & " is for " &
            "library '" & m.lib & "', but this block's library is '" &
            libNameForIdentity & "' — wrong-file paste protection " &
            "(RFC-0001 §B.3): point compatManifest at the right file, or " &
            "regenerate it for this library", directive.node)
      return

  # Check 4: ABI. A mismatch degrades to no-manifest behavior entirely —
  # every check below (5 through 9) is skipped, per the RFC ("a manifest
  # asserting confidence across a different OS/data-model would be worse
  # than none").
  let targetAbi = abiTag()
  if not abiOk(m, targetAbi):
    warning("softlink: " & macroName & ": compat manifest " & absPath &
            " was harvested for ABI '" & m.abi & "', but this build's " &
            "target ABI is '" & targetAbi & "' — ignoring the compat " &
            "manifest entirely for this compile (a manifest asserting " &
            "confidence across a different OS/data-model would be worse " &
            "than none)", directive.node)
    return

  # Check 5: disjoint/exhaustive validation — every violation found, not
  # just the first (a hand-merge mistake should surface completely).
  for v in validateDisjointExhaustive(m):
    let what = if v.matchCount == 0: "is in NO fact interval (a gap)"
               else: "is in " & $v.matchCount &
                     " fact intervals at once (an overlap)"
    error("softlink: " & macroName & ": compat manifest " & absPath &
          ": symbol '" & v.cname & "' at version '" & v.version & "' " &
          what & " — the four header fact-interval sets must be disjoint " &
          "and exhaustive over the corpus (RFC-0001 §B.3); fix the " &
          "manifest (likely a hand-merge mistake)", directive.node)

  # Check 6: since-contradiction — hard error, no escape hatch, message
  # includes the corrected bound (softlink/manifest.checkSince computes it).
  for p in procs:
    if p.sinceVersion.len == 0: continue
    let sc = checkSince(m, p.nameStr, p.sinceVersion)
    if sc.contradicted:
      error(sc.message, p.name)

  # Bound, harvester-trackable C names — same predicate `tools/harvest/
  # harvester.nim`'s `harvest` uses to decide what it records: excludes
  # `noverify` (nothing to probe) and prototype-only procs (corpus-
  # invariant, never in a manifest by design). Shared by checks 7 and 8.
  var trackable: seq[string] = @[]
  for p in procs:
    if not p.noVerify and p.headerFile.len > 0: trackable.add p.nameStr

  # Check 7: mismatch warning.
  let mismatched = mismatchedSymbols(m, trackable)
  if mismatched.len > 0:
    warning("softlink: " & macroName & ": compat manifest " & absPath &
            ": " & $mismatched.len & " symbol" &
            (if mismatched.len != 1: "s" else: "") &
            " recorded a 'mismatch' interval: " & mismatched.join(", ") &
            " — see the drift alarm / softlink harvest for details",
            directive.node)

  # Check 8: not-in-manifest hint.
  let missing = notInManifest(m, trackable)
  if missing.len > 0:
    hint("softlink: " & macroName & ": " & $missing.len & " symbol" &
         (if missing.len != 1: "s" else: "") & " not in compat manifest " &
         absPath & " — regenerate with softlink harvest", directive.node)

  # Check 9 (the degraded-tier warning) is emitted by `genVerifyBlock`
  # itself, into the graceful `#else` fallback branch — this proc's
  # `attached: true` return is the signal that tells it to. `manifest: m`
  # is the B6b addition: the fully parsed manifest, handed back so the
  # `dynlib` macro can embed its `symbols` verbatim into
  # `softlinkCompatFacts<Base>`.
  AppliedManifest(attached: true, manifest: m)

const softlinkProbeOnly {.strdefine.} = ""
  ## RFC-0001 §4 B.2: with `-d:softlinkProbeOnly=<CName>`, `genVerifyBlock`
  ## suppresses the ENTIRE verification apparatus (the call-based
  ## `_Static_assert` chain AND any `{.prototype.}` extern declaration —
  ## see `emitPrototypeDecl`) for every proc EXCEPT the one whose C name
  ## equals `<CName>`. Block-level `#include`s are STILL emitted regardless
  ## — the harvester's baseline probe exists precisely to detect broken
  ## corpus headers, so the includes must run even when nothing else does.
  ## The sentinel value `"-"` suppresses verification for every proc (the
  ## harvester's baseline mode: "do the headers even compile").
  ##
  ## RFC §4 B.2's optional fast-path (slice B7): `<CName>` may instead be a
  ## comma-separated LIST of C names (`<CName1,CName2,...>`) — the
  ## suppression rule generalizes to "suppress every proc whose C name is
  ## NOT a member of the list." A singleton list behaves identically to the
  ## pre-B7 single-name form (backward compatible by construction — see
  ## `isSuppressed`). This supersedes the B2-era comment that used to live
  ## here, which said a comma-containing value "degrades to suppress
  ## everything": that was true only because no list parsing existed yet.
  ## `parseProbeOnlyList` (below) now does the real parsing:
  ## - list elements are used VERBATIM — never trimmed. Defines are
  ##   machine-generated by the harvester's bisection, never hand-typed, so
  ##   a legitimate list is always a clean comma-join with no incidental
  ##   whitespace; a whitespace-padded element (e.g. from hand-editing)
  ##   simply never equals any real C name, so it fails CLOSED (that
  ##   element selects nothing) rather than requiring a second validation
  ##   pass to detect it.
  ## - an EMPTY element (from a leading/trailing/doubled comma, e.g.
  ##   `a,,b`) is always a macro-expansion-time error naming the malformed
  ##   define — same no-silent-degradation principle as everywhere else in
  ##   this file: a malformed list must never silently partial-match.
  ## Harvest-only, like `softlinkDumpProbes`: a dedicated single-shot
  ## invocation, not something left set in ordinary dev/CI builds. Default
  ## `""` (unset) is a no-op — every existing `dynlib`/`verifyProcs` block
  ## compiles byte-identically, because every check below short-circuits on
  ## `softlinkProbeOnly.len == 0` before touching emission at all.

const softlinkProbeExistence {.booldefine.} = false
  ## RFC-0001 §4 B.2: with `-d:softlinkProbeExistence` (meaningful only
  ## together with `-d:softlinkProbeOnly=<CName>` naming a real symbol),
  ## the probed symbol's verification is replaced by a bare
  ## declaration-existence reference — `__typeof__(&sym)` / `decltype(&sym)`
  ## through the SAME three-tier compiler gating the call-based assert
  ## uses — instead of the full call-based assert chain: it compiles iff
  ## the corpus headers declare the symbol at ANY signature, independent of
  ## what that signature is. The probed symbol's own `{.prototype.}` extern
  ## declaration (if any) is ALSO suppressed in this mode: emitting it would
  ## let `__typeof__`/`decltype` resolve against the *vendored* prototype
  ## even when the corpus header doesn't declare the symbol at all, making
  ## `absent` unclassifiable for header+prototype procs (the RFC's
  ## classification table depends on the existence probe reflecting the
  ## HEADER alone). A `{.verifyWhen.}` gate on the probed proc wraps the
  ## existence reference exactly as it would wrap the assert. Set without
  ## `softlinkProbeOnly` naming a real symbol (unset, or the `"-"`
  ## all-suppress sentinel) is a meaningless probe configuration — see the
  ## macro error raised in `genVerifyBlock` below — rather than silently
  ## compiling as some other mode. RFC §4 B.2 slice B7: a MULTI-symbol
  ## `softlinkProbeOnly` list combined with this define is ALSO a macro
  ## error (see `genVerifyBlock`) — existence is a per-singleton stage of
  ## the standard three-probe pipeline; a group existence probe is
  ## meaningless (the fast path's bisection only ever runs multi-symbol
  ## compiles in verify mode).

proc parseProbeOnlyList(raw: string, posNode: NimNode): seq[string] =
  ## RFC-0001 §4 B.2, slice B7: parses a non-empty, non-`"-"`
  ## `softlinkProbeOnly` value into its list of target C names. Callers
  ## only invoke this once `raw` is known to be neither `""` (unset) nor
  ## `"-"` (the all-suppress sentinel) — both are handled by their own
  ## checks before this is ever reached.
  ##
  ## A value with no comma is the pre-B7 singleton form, returned as a
  ## one-element list (so every downstream check — `isSuppressed`,
  ## `isProbedExistence` — written in terms of list membership is
  ## byte-for-byte backward compatible with the pre-list-support behavior).
  ##
  ## A comma-containing value splits on `,`, verbatim, no trimming (see the
  ## `softlinkProbeOnly` const's doc comment for why untrimmed is the
  ## chosen — not merely default — behavior). Any resulting EMPTY element
  ## (a leading, trailing, or doubled comma) is a macro-expansion-time
  ## error: the harvester's own bisection always emits a clean comma-join,
  ## so an empty element only ever means a hand-malformed define, and per
  ## this project's no-silent-degradation principle (identical in spirit
  ## to B2's original guidance for this exact spot) that must be a loud
  ## error, never a silent partial match.
  if "," notin raw:
    return @[raw]
  let parts = raw.split(",")
  for i, part in parts:
    if part.len == 0:
      error("softlink: malformed -d:softlinkProbeOnly=\"" & raw & "\" — " &
        "element " & $(i + 1) & " of " & $parts.len & " is empty (from a " &
        "leading, trailing, or doubled comma). RFC-0001 §4 B.2's fast-path " &
        "bisection (slice B7) always emits a clean comma-joined list of C " &
        "names with no empty elements — this is a malformed define, and " &
        "per this project's no-silent-degradation principle it is a " &
        "compile-time error rather than a silent partial match.", posNode)
  parts

proc genVerifyBlock(allProcs: seq[SoftlinkProc], tag: string,
                     hasManifestAttached: bool = false): seq[NimNode] =
  ## Generate the compile-time C header signature verification nodes
  ## (include section + a file-local _Static_assert proc). Shared by
  ## `dynlib` and `verifyProcs`.
  ##
  ## `hasManifestAttached` (RFC-0001 §B.5 check 9, slice B6a): true iff
  ## `applyCompatManifest` attached a (non-ABI-ignored) compat manifest to
  ## this block. When true, every proc's graceful `#else` fallback (the
  ## no-verification tier — see the "Fallback: graceful degradation"
  ## comment below) gains a `#pragma message` noting that this specific
  ## compile did NOT re-verify the manifest's facts — a green manifest and
  ## a degraded verification tier must never blur together into one
  ## "everything is fine" signal. `false` (the default) reproduces today's
  ## emission byte-for-byte.
  # {.noverify.} procs are excluded entirely — no _Static_assert AND no
  # #include of their header. A noverify symbol typically doesn't exist in
  # the installed headers (that's why verification is skipped), and its call
  # expression would be an implicit-declaration error in C. See #14/Defect B:
  # {.optional.} alone is runtime-optional but still compile-time verified.
  #
  # A {.prototype.} proc (RFC-0001 §3 A.1) verifies even with no {.header.}:
  # the vendored prototype is emitted as a file-scope `extern` declaration
  # (see `emitPrototypeDecl`) below the block's #includes, giving the
  # subsequent call-based _Static_assert something real to check against —
  # no implicit-declaration error, because the symbol is now declared.
  # A proc carrying BOTH {.header.} and {.prototype.} (cross-checking) gets
  # BOTH declarations; if they disagree, the C compiler itself reports the
  # conflict (opportunistic conflict checking, benefit 2 of A.1 — the actual
  # conflict fixture is slice A4).
  var procs: seq[SoftlinkProc]
  for p in allProcs:
    if not p.noVerify and (p.headerFile != "" or p.prototype.len > 0): procs.add(p)
  if procs.len == 0:
    return @[]

  # RFC-0001 §4 B.2: probe-mode config validation + per-proc classification.
  # `probeOnlyActive` is false whenever `softlinkProbeOnly` is at its default
  # "" value, so every predicate below is unreachable/false in the control
  # path — pre-B2 emission is untouched by construction, not merely by test.
  let probeOnlyActive = softlinkProbeOnly.len > 0
  if softlinkProbeExistence and (softlinkProbeOnly == "" or softlinkProbeOnly == "-"):
    let gotDesc =
      if softlinkProbeOnly == "": "<unset>"
      else: "'-' (the all-suppress sentinel, not a symbol name)"
    let msg = "softlink: -d:softlinkProbeExistence requires " &
      "-d:softlinkProbeOnly=<CName> naming a real probed symbol — an " &
      "existence-only probe is meaningless without exactly one target " &
      "symbol. Got softlinkProbeOnly=" & gotDesc & ". Pass the exact C " &
      "name of the symbol being probed, e.g. -d:softlinkProbeOnly=" &
      procs[0].nameStr & "."
    error(msg, allProcs[0].name)

  # RFC-0001 §4 B.2, slice B7: `probeOnlyList` is the parsed form of
  # `softlinkProbeOnly` — empty for the unset/"" and "-" (all-suppress)
  # cases (neither is ever list-membership-tested; `isSuppressed` checks
  # them directly, exactly as before B7), otherwise one or more C names.
  # `parseProbeOnlyList` itself raises a macro error (and returns its best-
  # effort partial parse, execution continuing per this file's `error()`
  # convention elsewhere) on a malformed list — see its own doc comment.
  let probeOnlyList: seq[string] =
    if softlinkProbeOnly == "" or softlinkProbeOnly == "-": @[]
    else: parseProbeOnlyList(softlinkProbeOnly, allProcs[0].name)

  if softlinkProbeExistence and probeOnlyList.len > 1:
    let msg = "softlink: -d:softlinkProbeExistence requires exactly ONE " &
      "probed symbol — got " & $probeOnlyList.len & " names in " &
      "-d:softlinkProbeOnly=" & softlinkProbeOnly & ". Existence mode is a " &
      "per-singleton stage of the standard three-probe pipeline " &
      "(RFC-0001 §4 B.2); a MULTI-symbol existence probe is meaningless. " &
      "The multi-symbol form of -d:softlinkProbeOnly is a verify-mode-only " &
      "fast-path bisection tool (RFC-0001 §4 B.2, slice B7) — drop " &
      "-d:softlinkProbeExistence to bisect, or narrow the list to exactly " &
      "one symbol to probe its existence."
    error(msg, allProcs[0].name)

  template isSuppressed(p: SoftlinkProc): bool =
    ## RFC-0001 §4 B.2 (list support: slice B7): true when this proc's
    ## entire verification apparatus (call-based assert chain AND any
    ## {.prototype.} extern decl) must be omitted this compile — probing is
    ## active and this proc is neither the "-" sentinel's "everything"
    ## target nor a member of `probeOnlyList`. A singleton list reduces to
    ## exactly the pre-B7 `p.nameStr != softlinkProbeOnly` check (byte-
    ## identical behavior — see `parseProbeOnlyList`'s doc comment).
    probeOnlyActive and (softlinkProbeOnly == "-" or p.nameStr notin probeOnlyList)

  template isProbedExistence(p: SoftlinkProc): bool =
    ## RFC-0001 §4 B.2: true when this proc IS the probed symbol AND
    ## existence-only mode was requested — its call-based assert is
    ## replaced by a bare declaration-existence reference, and its own
    ## {.prototype.} extern decl (if any) is ALSO suppressed (see the
    ## `softlinkProbeExistence` const doc comment for why that matters).
    ## `probeOnlyList.len == 1` is redundant with the macro error raised
    ## above whenever `softlinkProbeExistence` and a multi-symbol list
    ## coexist, but guards this predicate against acting on a partially-
    ## parsed multi-symbol list while that error is still propagating.
    probeOnlyActive and softlinkProbeExistence and probeOnlyList.len == 1 and
      p.nameStr == probeOnlyList[0]

  var nodes: seq[NimNode] = @[]
  # Compile-time header verification. Compares each symbol's type from
  # the C header against Nim's generated function pointer type.
  # Three-tier fallback for maximum compiler compatibility:
  #   1. C23 typeof (standard)
  #   2. __typeof__ (GCC/Clang extension, also MSVC 2022+)
  #   3. C++ decltype + std::is_same (for --backend:cpp)
  # No linking required — pure compile-time check.
  block:
    var headers: HashSet[string]
    var includeCode = ""
    for p in procs:
      # `procs` now includes prototype-only entries (no {.header.}) per
      # RFC-0001 §3 A.1 slice A2 — the empty-headerFile guard here is load-
      # bearing, not defensive dead code: without it a prototype-only proc
      # would emit `#include ""`, a compile error.
      if p.headerFile != "" and p.headerFile notin headers:
        headers.incl(p.headerFile)
        includeCode.add(toIncludeDirective(p.headerFile))

    # Vendored-prototype extern declarations (RFC-0001 §3 A.1), emitted
    # after all of this block's #includes so any named types the prototype
    # references resolve, and before the type_traits/verify-proc code below.
    # A proc with both {.header.} and {.prototype.} gets both declarations —
    # cross-checking (A.1 benefit 2); the C compiler itself flags disagreement.
    #
    # RFC-0001 §4 B.2: a suppressed proc's decl is omitted entirely — a
    # suppressed proc's vendored prototype conflicting with a corpus header
    # would fail the whole TU and poison the probe of the TARGET symbol. The
    # probed symbol's OWN decl is also omitted under existence mode — see
    # `isProbedExistence`'s doc comment for why that's load-bearing, not
    # merely symmetric.
    for p in procs:
      if p.prototype.len > 0 and not isSuppressed(p) and not isProbedExistence(p):
        includeCode.add(emitPrototypeDecl(p.prototype, p.verifyWhen))

    # Emit #include directives + C++ type_traits if needed
    nodes.add(newNimNode(nnkPragma).add(
      newNimNode(nnkExprColonExpr).add(
        ident("emit"),
        newStrLitNode("/*INCLUDESECTION*/\n" & includeCode &
          "#if defined(__cplusplus)\n" &
          "#include <type_traits>\n" &
          "#ifndef SOFTLINK_STRIP_PTR_CONST_DEFINED\n" &
          "#define SOFTLINK_STRIP_PTR_CONST_DEFINED 1\n" &
          "template<typename T> struct softlink_strip_ptr_const { typedef T type; };\n" &
          "template<typename T> struct softlink_strip_ptr_const<const T*> { typedef T* type; };\n" &
          "#endif\n" &
          "#endif\n")
      )
    ))

    # Emit per-proc verification inside a dummy proc to ensure the
    # assertions appear after function pointer var declarations in
    # the generated C code (file-scope emit can't reference these vars).
    # NOTE: {.used.} alone is not sufficient — Nim's dead code elimination
    # drops the proc entirely. {.exportc.} forces Nim to emit the proc.
    # {.codegenDecl: "static ...".} makes it file-local in C — no linker
    # collisions, no binary bloat. _Static_assert is evaluated at C
    # compilation time (during gcc -c), before LTO runs at link time —
    # the assertions cannot be eliminated by link-time optimization.
    var verifyBody = newStmtList()
    for p in procs:
      # RFC-0001 §4 B.2: a suppressed proc gets NO verification apparatus at
      # all this compile — not even the dummy param vars, which exist only
      # to feed the call-based assert chain this proc isn't getting.
      if isSuppressed(p):
        continue

      if isProbedExistence(p):
        # RFC-0001 §4 B.2: existence-only mode for the probed symbol — a
        # bare declaration-existence reference through the SAME three-tier
        # compiler gating the call-based assert uses, instead of the call-
        # based assert itself. No dummy param vars are needed (nothing is
        # called); the reference must compile iff the symbol is declared,
        # with NO dependence on its signature — `sizeof(__typeof__(&sym))` /
        # `sizeof(decltype(&sym))` (the C++ tier) fit exactly: they name the
        # symbol (so an undeclared symbol is a hard compile error) but
        # `sizeof` never evaluates its operand, so any real signature works.
        var existArray = newNimNode(nnkBracket)
        if p.verifyWhen.len > 0:
          existArray.add(newStrLitNode(
            "\n#if (" & p.verifyWhen & ") /* softlink verifyWhen */"))
        existArray.add(newStrLitNode(
          "\n#if defined(__cplusplus)\n(void)sizeof(decltype(&" &
          p.nameStr & "));\n" &
          "#elif defined(__GNUC__)\n(void)sizeof(__typeof__(&" &
          p.nameStr & "));\n" &
          "#elif defined(_MSC_VER) && defined(__STDC_VERSION__) && __STDC_VERSION__ >= 202311L\n" &
          "(void)sizeof(__typeof__(&" & p.nameStr & "));\n"))
        when defined(softlinkStrictVerify):
          existArray.add(newStrLitNode(
            "#else\n#error \"softlink: existence probe unavailable here " &
            "(need C++, GCC/Clang, or MSVC /std:clatest); remove " &
            "-d:softlinkStrictVerify to skip\"\n#endif\n"))
        else:
          existArray.add(newStrLitNode(
            "#else\n/* softlink: existence probe skipped — unsupported " &
            "compiler/mode */\n#endif\n"))
        if p.verifyWhen.len > 0:
          existArray.add(newStrLitNode("#endif /* softlink verifyWhen */\n"))
        verifyBody.add(newNimNode(nnkPragma).add(
          newNimNode(nnkExprColonExpr).add(ident("emit"), existArray)
        ))
        continue

      # Generate dummy variables for each param — Nim emits typed C locals.
      # These are passed to the C function call, enabling const-tolerant
      # param checking (int* implicitly converts to const int* in C).
      var dummyVars: seq[NimNode]
      for i in 1 ..< p.formalParams.len:
        let identDefs = p.formalParams[i]
        let paramType = identDefs[^2]  # type is second-to-last
        for j in 0 ..< identDefs.len - 2:  # one var per name
          let dummyName = genSym(nskVar, "softlinkP")
          var varSection = newNimNode(nnkVarSection).add(
            newNimNode(nnkIdentDefs).add(dummyName, paramType.copy(), newEmptyNode())
          )
          # Add {.used, noinit.} pragmas
          let pragmaExpr = newNimNode(nnkPragmaExpr).add(dummyName, newNimNode(nnkPragma).add(
            ident("used"), ident("noinit")
          ))
          varSection[0][0] = pragmaExpr
          verifyBody.add(varSection)
          dummyVars.add(dummyName)

      # Build the call expression arguments for emit: "symbol(p1, p2, ...)"
      # Each dummy var is a Nim node resolved to its C name via emit array.
      let declSource =
        if p.headerFile != "": p.headerFile
        elif p.prototype.len > 0: "vendored prototype"
        else: "declaration"
      let errMsg = "softlink: " & p.nameStr & " signature mismatch vs " & declSource

      # Helper: build the call args portion of emit array
      # Result: [symName, "(", p1, ", ", p2, ", ", ..., ")"]
      proc buildCallArgs(emitArr: var NimNode, symName: string, vars: seq[NimNode]) =
        emitArr.add(newStrLitNode(symName & "("))
        for i, v in vars:
          if i > 0: emitArr.add(newStrLitNode(", "))
          emitArr.add(v)
        emitArr.add(newStrLitNode(")"))

      # Helper: add a type node to emit array, handling compound nodes
      # like nnkPtrTy that the C emitter can't render directly.
      proc addTypeToEmit(emitArr: var NimNode, typeNode: NimNode) =
        if typeNode.kind == nnkPtrTy:
          addTypeToEmit(emitArr, typeNode[0])
          emitArr.add(newStrLitNode("*"))
        else:
          emitArr.add(typeNode.copy())

      var emitArray = newNimNode(nnkBracket)

      # {.verifyWhen: "EXPR".}: gate this proc's entire verification (all
      # three compiler tiers AND the strict-mode #error fallback) on a C
      # preprocessor expression — verify on systems whose headers are new
      # enough, compile cleanly on older ones. When the condition is false,
      # skipping is legitimate, so strict mode must not fire either.
      if p.verifyWhen.len > 0:
        emitArray.add(newStrLitNode(
          "\n#if (" & p.verifyWhen & ") /* softlink verifyWhen */"))

      # --- C++ path: static_assert + strip_ptr_const + decltype ---
      # strip_ptr_const removes const from pointed-to types in return values
      emitArray.add(newStrLitNode(
        "\n#if defined(__cplusplus)\nstatic_assert(\n  std::is_same<\n" &
        "    typename softlink_strip_ptr_const<decltype("))
      buildCallArgs(emitArray, p.nameStr, dummyVars)
      emitArray.add(newStrLitNode(")>::type,\n    "))
      if p.hasReturn:
        addTypeToEmit(emitArray, p.formalParams[0])
      else:
        emitArray.add(newStrLitNode("void"))
      emitArray.add(newStrLitNode(
        ">::value,\n  \"" & errMsg & "\"\n);\n"))

      # --- GCC/Clang path: __builtin_types_compatible_p + __typeof__ ---
      # For pointer returns, dereference both sides so __builtin_types_compatible_p
      # strips top-level const (e.g., const unsigned char* → const unsigned char,
      # then ignoring qualifiers matches unsigned char). No linker dependency —
      # __typeof__ is purely compile-time.
      #
      # "Pointer return" here covers both `ptr T` (nnkPtrTy in Nim AST) and
      # Nim's pointer-typed aliases that aren't structurally nnkPtrTy but
      # emit as pointer types in C (`cstring` → `char*`, `cstringArray` →
      # `char**`, `pointer` → `void*`). Without the alias check, a proc
      # returning `cstring` against a C function declared `const char *`
      # (e.g., libc's `strerror`, libz3's `Z3_string`) is rejected as a
      # signature mismatch even though it's a perfectly valid binding —
      # see #11.
      let retIsPointerLike =
        p.hasReturn and (
          p.formalParams[0].kind == nnkPtrTy or
          (p.formalParams[0].kind in {nnkIdent, nnkSym} and
           $p.formalParams[0] in ["cstring", "cstringArray", "pointer"]))
      emitArray.add(newStrLitNode(
        "#elif defined(__GNUC__)\n_Static_assert(\n  __builtin_types_compatible_p(\n    __typeof__("))
      if retIsPointerLike:
        emitArray.add(newStrLitNode("*"))
      buildCallArgs(emitArray, p.nameStr, dummyVars)
      emitArray.add(newStrLitNode("),\n    "))
      if p.hasReturn:
        if retIsPointerLike:
          emitArray.add(newStrLitNode("__typeof__(*("))
          addTypeToEmit(emitArray, p.formalParams[0])
          emitArray.add(newStrLitNode(")0)"))
        else:
          addTypeToEmit(emitArray, p.formalParams[0])
      else:
        emitArray.add(newStrLitNode("void"))
      emitArray.add(newStrLitNode(
        "),\n  \"" & errMsg & "\"\n);\n"))

      # --- MSVC C path: _Generic + __typeof__ (C23 only) ---
      # MSVC only exposes _Generic and __typeof__ in C23 mode (/std:clatest), so
      # gate the whole branch on __STDC_VERSION__ >= C23. In default mode MSVC
      # doesn't even recognize _Generic — it parses as a call and errors with
      # C2059/C2275 — so without the gate every pointer-returning proc breaks the
      # build. Gated, default-mode MSVC instead falls through to the graceful
      # fallback below (no verification, but the build works). CI forces
      # /std:clatest + -d:softlinkStrictVerify so the check is genuinely exercised
      # there and can't be silently skipped (see the fallback). For pointer
      # returns the same dereference trick as the GCC path strips pointee const;
      # `retIsPointerLike` classifies cstring/cstringArray/pointer with nnkPtrTy.
      emitArray.add(newStrLitNode(
        "#elif defined(_MSC_VER) && defined(__STDC_VERSION__) && __STDC_VERSION__ >= 202311L\n"))
      if retIsPointerLike:
        # Pointer return: dereference BOTH the return value and the declared
        # return type inside _Generic. _Generic applies lvalue conversion to its
        # controlling expression, which drops the pointee's top-level const —
        # so `*(__typeof__(f()))0` (type `const char`) converts to `char` and
        # matches the association `__typeof__(*(RET)0)` (`char`). This is the
        # same const-tolerant trick the GCC path (`__builtin_types_compatible_p`
        # on dereferenced operands) and the C++ path (`strip_ptr_const`) use, and
        # it reuses the identical `__typeof__(*(RET)0)` construct emitted above.
        # Before this, the branch compared `const char**` (from
        # `(__typeof__(f())*)0`) against `char**` and rejected every
        # `const char *`-returning proc — e.g. libz3's `Z3_string` (#11 on MSVC).
        emitArray.add(newStrLitNode(
          "_Static_assert(\n  _Generic(*(__typeof__("))
        buildCallArgs(emitArray, p.nameStr, dummyVars)
        emitArray.add(newStrLitNode("))0,\n    __typeof__(*("))
        addTypeToEmit(emitArray, p.formalParams[0])
        emitArray.add(newStrLitNode(
          ")0): 1, default: 0),\n  \"" & errMsg & "\"\n);\n"))
      else:
        # Non-pointer: call + _Generic __typeof__ pointer trick
        buildCallArgs(emitArray, p.nameStr, dummyVars)
        emitArray.add(newStrLitNode(";\n_Static_assert(\n  _Generic((__typeof__("))
        buildCallArgs(emitArray, p.nameStr, dummyVars)
        emitArray.add(newStrLitNode(")*)0,\n    "))
        if p.hasReturn:
          addTypeToEmit(emitArray, p.formalParams[0])
        else:
          emitArray.add(newStrLitNode("void"))
        emitArray.add(newStrLitNode(
          "*: 1, default: 0),\n  \"" & errMsg & "\"\n);\n"))

      # --- Fallback: graceful degradation ---
      # Compile-time signature verification is best-effort: it must never break an
      # otherwise-valid build. On a compiler/mode lacking the needed features —
      # notably default-mode MSVC, where _Generic/__typeof__ are unavailable — emit
      # nothing (the runtime FFI machinery is generated separately and is
      # unaffected). Opt into a hard error with `-d:softlinkStrictVerify` so a
      # silently-skipped check can't pass unnoticed; CI sets it (with the std flag
      # that opens the MSVC gate above) to guarantee the check is exercised.
      when defined(softlinkStrictVerify):
        emitArray.add(newStrLitNode(
          "#else\n#error \"softlink: signature verification unavailable here " &
          "(need C++, GCC/Clang, or MSVC /std:clatest); remove -d:softlinkStrictVerify to skip\"\n#endif\n"))
      else:
        var fallbackText =
          "#else\n/* softlink: signature verification skipped — unsupported compiler/mode */\n"
        if hasManifestAttached:
          # RFC-0001 §B.5 check 9: this build's own verification tier
          # degraded to the no-op fallback WHILE a compat manifest is
          # attached — the manifest may be green, but THIS compile
          # verified nothing, and those two facts must not blur.
          # `#pragma message` is portable across gcc/clang/MSVC.
          fallbackText.add(
            "#pragma message(\"softlink: compat manifest attached but " &
            "this compile's verification tier degraded to no-op — " &
            "manifest facts were NOT re-verified by this build\")\n")
        fallbackText.add("#endif\n")
        emitArray.add(newStrLitNode(fallbackText))

      if p.verifyWhen.len > 0:
        emitArray.add(newStrLitNode("#endif /* softlink verifyWhen */\n"))

      verifyBody.add(newNimNode(nnkPragma).add(
        newNimNode(nnkExprColonExpr).add(
          ident("emit"),
          emitArray
        )
      ))

    let verifyProcName = ident("softlinkVerify" & tag)
    var verifyProc = newProc(
      name = verifyProcName,
      body = verifyBody,
    )
    verifyProc.addPragma(ident("exportc"))
    # codegenDecl chooses the storage-class qualifier for the verify proc:
    #
    # - **C backend** (`nim c`): `static` gives the function internal
    #   linkage (file scope, no symbol exported, no linker collisions
    #   when the same dynlib block appears in multiple TUs).
    #
    # - **C++ backend** (`nim cpp`): `static` cannot appear inside a
    #   linkage specification per C++ [dcl.link]/4. Because Nim's
    #   `{.exportc.}` emits `extern "C" ...` under cpp, combining with
    #   `static` produces `extern "C" static void ...` which g++/clang++
    #   reject. `inline` is the C++ equivalent: ODR-relaxed (multiple
    #   definitions across TUs are merged) and compatible with
    #   `extern "C"`. The verify proc only contains compile-time
    #   `_Static_assert` / `static_assert`s, so no runtime overhead
    #   distinguishes the two. See #12.
    let codegenTemplate =
      when defined(cpp): "inline $# $#$#"
      else: "static $# $#$#"
    verifyProc.addPragma(newNimNode(nnkExprColonExpr).add(
      ident("codegenDecl"),
      newStrLitNode(codegenTemplate)
    ))
    nodes.add(verifyProc)
  return nodes

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

proc scanProbeBodyForDriftCalls(stmts: NimNode, mismatchCNames: HashSet[string]): bool =
  ## RFC-0001 §C.1/§C.3, slice C4b: "the version probe may only call
  ## symbols with no known drift ranges" (RFC §C.1: "the probe must not be
  ## the drift"). Walks `stmts` (the versionProbe body, still raw AST at
  ## macro-expansion time — the manifest is already parsed by now) looking
  ## for a DIRECT call (`nnkCall`/`nnkCommand`) whose callee is a bare
  ## ident matching `mismatchCNames` — this block's own symbols (required
  ## OR optional; required-symbol RUNTIME refusal is C4c's territory, but
  ## the call-safety risk this scan guards against exists for both) that
  ## carry ANY `mismatch` interval in the attached manifest. Emits ONE
  ## macro error at the offending call node and stops (returns `true`) — a
  ## probe with several such calls gets one diagnostic, not a pile-up.
  ## Indirect calls (through a variable, a closure, a method) can't be
  ## seen statically; that residual risk is accepted and documented here,
  ## not pretended away, per the RFC's own words.
  if stmts.kind in {nnkCall, nnkCommand} and stmts.len > 0 and stmts[0].kind == nnkIdent:
    let callee = $stmts[0]
    if callee in mismatchCNames:
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
  # block (a probe-less block's query proc simply always returns this
  # var's zero value, `atNoProbe`).
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
    ## place. `fields` omitted entirely means every field takes its
    ## zero-value default (`""`, `atNoProbe`, `@[]`) — the report's zero
    ## state.
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
                   reportFields: seq[(string, NimNode)] = @[]): NimNode =
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
    ## Both currently pass `reportFields = @[]` (the zero-state report is
    ## correct pre-first-load / right after unloadX resets state) — already
    ## threaded through so C4c can pass a non-empty (drift-story) report
    ## without touching this proc.
    ##
    ## Future extensions (NOT implemented by this slice — nothing below may
    ## call a code path this slice doesn't already exercise):
    ##   - C4c's post-probe required unwind is the SAME return-path frame,
    ##     firing later in the pipeline (after Phase 3 has assigned pointers
    ##     and the probe has run), so it needs two more leading cleanup
    ##     steps before the existing unload/report/return tail: nil every
    ##     already-assigned function-pointer var, and reset the probe state
    ##     vars (`softlinkProbedVersion<Base>`/`softlinkProbeFailed<Base>`,
    ##     mirroring unloadX's own reset shape at its call site, without
    ##     touching unloadX itself). Purely additive params, e.g.
    ##     `resetPtrs: seq[NimNode] = @[]` and `resetProbeState: bool =
    ##     false`, defaulting to today's exact behavior — shape-1/shape-2
    ##     call sites need no change when these land.
    ##   - C4b's optional re-nil (re-nil one already-resolved optional
    ##     pointer + add its name to the `missing` set) is NOT a return-path
    ##     cleanup: the pipeline keeps running to classify the remaining
    ##     symbols, so neither the compat-report assignment nor the
    ##     `return` at the tail of this shape may fire — only the leading
    ##     cleanup steps should. Still the SAME domain problem (unwinding a
    ##     symbol this load is walking back), so the read here is that it
    ##     belongs in this SAME generator behind a `terminal: bool = true`
    ##     toggle (false skips the report-assign + return, emitting only
    ##     the cleanup prefix) plus a `missingAdd` piece (nil the one ptr,
    ##     `missingVar.add(symName)`) — every existing and future shape is
    ##     then a true subset of one ordered action list, not two
    ##     unrelated things forced together. Flagged here as the part of
    ##     this design I'm least sure of: if a future implementer's
    ##     analysis disagrees once C4b's actual shape is in front of them,
    ##     that's grounds to split it into a sibling helper instead — this
    ##     doc comment is a proposal, not a locked contract.
    result = newStmtList()
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

  # var compatReport: CompatReport — RFC-0001 §9/§C.2: zero-initializes to
  # the zero state (atNoProbe, "", @[]), which is exactly right before the
  # first load (mirrors `cachedResult` above). Emitted for EVERY dynlib
  # block, unlike the probe state vars further below — `fooCompat()` is
  # generated unconditionally (see its emission point near `xxxLoaded*`).
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

  # RFC-0001 §C.3, slice C4b: the OPTIONAL subset of `mismatchCNames` —
  # the only symbols eligible for the RUNTIME drift refusal this slice
  # implements (required-symbol refusal is C4c's). Refusal also requires
  # a probe (no probed version, no refusal is ever possible), so this
  # list is empty whenever `hasProbe` is false even if the manifest has
  # mismatch facts on optional symbols — there is nothing to compare them
  # against yet.
  var driftCandidates: seq[SoftlinkProc]
  if appliedManifest.attached and hasProbe:
    for p in procs:
      if p.isOptional and p.nameStr in mismatchCNames:
        driftCandidates.add(p)
  var driftCandidateNames: HashSet[string]
  for p in driftCandidates: driftCandidateNames.incl(p.nameStr)

  # RFC-0001 §C.3, slice C4b design guidance: one drift-story seq per
  # block — `softlinkDriftStories<Base>: seq[tuple[symbol, story: string]]`
  # — populated at refusal time inside loadXxx below, scanned (linearly,
  # error-path only) by the wrapper's nil-pointer branch, and reset by
  # unloadXxx. Zero footprint when nothing could ever be refused
  # (`driftCandidates.len == 0`): gated on the ACTUAL refusal-candidate
  # list, not merely `appliedManifest.attached`, since a manifest with
  # mismatch facts but no probe, or mismatch facts only on required
  # symbols, generates no refusal code at all and would leave this var
  # write-only.
  let driftStoriesName = ident("softlinkDriftStories" & baseName)
  if driftCandidates.len > 0:
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

    # if handle.isNil: write the zero-state compat report (RFC-0001 §9/
    # §C.2 — this Phase-1 early return happens only before the first ever
    # load, or right after unloadX already reset the probe state vars to
    # their own zero values, so the zero-state report IS the correct value
    # here, not merely a placeholder) + return LoadResult(kind: lrLibNotFound)
    loadBody.add(newIfStmt((
      newCall(ident("isNil"), handleName),
      unwindStmt(unloadHandle = false, resultKind = ident("lrLibNotFound"))
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

      # if sym.isNil: unload + nil handle + zero-state compat report
      # (RFC-0001 §9/§C.2 — same "probe never ran" reasoning as the
      # lrLibNotFound early return above) + return lrSymbolNotFound
      let cleanupBlock = unwindStmt(unloadHandle = true,
        resultKind = ident("lrSymbolNotFound"), resultFields = @[("symbol", symName)])
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

      # RFC-0001 §9/§C.2, slice C3: the absence partition (`mrExpected`/
      # `mrAnomalous`), computed AT MOST once per successful, manifest-
      # attested load — only when there is something to partition at all
      # (`hasOptional`; a block with no optional procs can never have a
      # `missing` entry). Deliberately NOT gated on atAttested-vs-
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
        missingPartitionFields.add(("missing", missingPartitionSym))

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
        # missingPartitionFields has exactly one entry, ("missing", <sym>),
        # whenever driftCandidates is nonempty (its members are all
        # optional, so hasOptional is necessarily true here too) — extend
        # THAT node with `& driftPartitionSym` for this branch only.
        let baseMissingNode = missingPartitionFields[0][1]
        attestedMissingFields = @[("missing",
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
    # RFC-0001 §9/§C.2: reset the compat report to its zero state alongside
    # every other piece of per-load state above — `fooCompat()` called
    # after `unloadFoo()` must never serve a previous load's trust signals.
    # Unconditional, like the report var's own declaration (every dynlib
    # block gets a report, not just probe-declaring ones).
    ifBody.add(assignCompatReportStmt())
    if hasProbe:
      # RFC-0001 §9/§C.1: reset the probe's outcome alongside every other
      # piece of per-load state above — `fooCompat()` (RFC-0001 §C.2)
      # called after `unloadFoo()` must never serve a previous load's
      # probe result.
      ifBody.add(newAssignment(probedVersionName, newStrLitNode("")))
      ifBody.add(newAssignment(probeFailedName, newLit(false)))
    if driftCandidates.len > 0:
      # RFC-0001 §C.3, slice C4b design guidance: reset the drift-story
      # seq alongside every other piece of per-load state above — a
      # reload must re-run refusal fresh, never carry forward a previous
      # load's stories.
      ifBody.add(newAssignment(driftStoriesName, prefix(newNimNode(nnkBracket), "@")))
    unloadBody.add(newIfStmt((
      prefix(newCall(ident("isNil"), handleName), "not"),
      ifBody
    )))

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
  # simply always returns the report var's zero value, `atNoProbe`).
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
