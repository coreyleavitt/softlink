## `softlink/directives` — RFC-0001 §B.5/§9's `dynlib`/`verifyProcs` body
## directives (`compatManifest`, `versionProbe`) that sit alongside proc
## declarations in a block body, plus the compile-time compat-manifest
## consumption pipeline (`applyCompatManifest`) that acts on a parsed
## `compatManifest` directive. Extracted from `softlink/pragmas`
## (code-review finding R2-4): pragmas.nim's namesake concern is per-proc
## PRAGMA parsing (calling convention, `header`, `optional`, `noverify`,
## `verifyWhen`, `since`, `prototype`); block-level DIRECTIVE recognition
## (`isCompatManifestCall`/`parseCompatManifestDirective`/
## `isVersionProbeStmt`/`parseVersionProbeDirective`) and the
## I/O-performing manifest-application orchestration (`applyCompatManifest`,
## sequencing fileExists/staticRead plus nine checks) are a different thing
## — pushed here to keep pragmas.nim's public surface to its one concern.
## None of the procs below close over any `dynlib`/`verifyProcs` macro
## local — every one takes its inputs as explicit parameters (the parsed
## `NimNode`s, a `ProcPragmaMode`, a `seq[SoftlinkProc]`, ...) and returns
## plain data or emits a diagnostic anchored at the node it was given.
##
## Shared by both `dynlib` and `verifyProcs` (still in `src/softlink.nim`),
## which disagree on what a few of these directives mean but agree on the
## token recognition and AST shapes themselves.
##
## `ProcPragmaMode` (the `ppmDynlib`/`ppmVerifyProcs` enum `applyCompatManifest`
## takes) moved to `softlink/procinfo` in the same pass, rather than staying
## in `softlink/pragmas` — if this module imported `pragmas` just for that
## enum, the pragmas/directives decoupling this split is for would be
## incomplete. Both this module and `softlink/pragmas` import `procinfo`
## for it instead; neither imports the other.

import std/[macros, os, strutils]
import ./manifest
import ./procinfo
# R3-3: `abiTag` and `isCorpusTrackable` (both used below) are genuinely
# used by THIS module — imported directly here, rather than relying on
# `./manifest`'s transitive `export versions`, so the dependency is explicit
# rather than an accident of what `manifest` happens to re-export.
import ./versions

# The `compatManifest`/`versionProbe` "erroring stub" proc/template stay
# declared directly in `src/softlink.nim` rather than moving here with the
# rest of the directive-recognition machinery below (`isCompatManifestCall`,
# `isVersionProbeStmt`, etc.) — empirically (isolated repro during this
# extraction), Nim's qualified re-export syntax (`export
# someModule.someProc`) silently fails to re-export a BODYLESS
# `{.error.}`-pragma'd proc/template: the symbol is simply absent from the
# importing module's scope, with no error at the `export` site itself (only
# whole-module `export someModule` reliably carries it through, which would
# also leak every OTHER symbol in this file — not acceptable, since most of
# them were module-private before this extraction). Declaring both stubs
# directly in `softlink.nim`, where their own `*` already makes them public,
# sidesteps the issue entirely and preserves the pre-extraction behavior
# byte-for-byte. `isCompatManifestCall`/`isVersionProbeStmt` recognize a
# CORRECTLY-placed directive structurally and never reference the stub
# symbols themselves, so nothing here depends on them.

type
  CompatManifestDirective* = object
    ## RFC-0001 §B.5/§B.5a, slice B6a: one parsed `compatManifest` body
    ## directive. `present == false` is the zero value (no directive in
    ## this block) — every check downstream short-circuits on it.
    present*: bool
    pathLit*: string     ## the string literal argument, as written
    refuse*: bool         ## parsed value of `refuse = ...`; false if absent
    refuseGiven*: bool    ## RFC-0001 §B.5a: was `refuse` written at all?
                         ## (verifyProcs rejects it outright regardless of
                         ## value — "nothing to refuse" there)
    node*: NimNode        ## the directive call node, for diagnostic anchoring

func isCompatManifestCall*(stmt: NimNode): bool =
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

proc parseCompatManifestDirective*(stmt: NimNode, macroName: string): CompatManifestDirective =
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

proc compatManifestDupError*(macroName: string, first, second: CompatManifestDirective): string =
  ## RFC-0001 §B.5: "at most one compatManifest per block, any position."
  ## Voiced like the existing #14 dup-block guard (`src/softlink.nim`'s
  ## `dynlib` macro) — softlink-authored, names both paths, tells the
  ## author what to do, never an opaque "redefinition of ...".
  "softlink: " & macroName & ": duplicate compatManifest directive in one " &
  "block ('" & first.pathLit & "' and '" & second.pathLit & "') — merge " &
  "them into a single compatManifest directive; a dynlib/verifyProcs " &
  "block may attach at most one compat manifest."

type
  VersionProbeDirective* = object
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
    present*: bool
    bodyStmts*: NimNode
    node*: NimNode

func isVersionProbeStmt*(stmt: NimNode): bool =
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

proc parseVersionProbeDirective*(stmt: NimNode, macroName: string): VersionProbeDirective =
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
const versionProbeDupErrorMsg* =
  "softlink: dynlib: duplicate versionProbe directive in one block — " &
  "merge the probes into a single versionProbe: body; a dynlib block may " &
  "contain at most one version probe."

type
  VersionMacrosDirective* = object
    ## RFC-0002 §5/§6, slice E1: one parsed `versionMacros` body directive —
    ## at most one per block, any position (mirrors `CompatManifestDirective`/
    ## `VersionProbeDirective` above). `present == false` is the zero value
    ## (no directive in this block). This slice only parses and stores the
    ## macro name list; nothing downstream consumes it yet — Stage E2 wires
    ## it into gate synthesis (§5 Layer 2).
    present*: bool
    macroNames*: seq[string]  ## most-significant-first, e.g.
                               ## @["Z3_MAJOR_VERSION", "Z3_MINOR_VERSION"]
    headerName*: string  ## RFC-0002 §5/§6 Z3 extension: the optional
      ## `header = "..."` named argument's value, in the SAME quoted/
      ## angle-bracket convention as a proc's own `{.header.}`
      ## (`softlink/verify.toIncludeDirective`); "" (the zero value) means
      ## absent — every downstream emission check tests this directly
      ## rather than a separate presence flag, mirroring `noVerifyReason`'s
      ## own "" = absent convention on `SoftlinkProc`. Exists because
      ## `versionMacros`'s synthesized `#if`/`#ifndef` gate assumes ONE of
      ## this block's procs' `{.header.}`s transitively #includes whatever
      ## header actually DEFINES the named macro(s) — true for mbedtls-
      ## style umbrella headers, but false for Z3: `z3.h` does not include
      ## `z3_version.h`, so `Z3_MAJOR_VERSION`/`Z3_MINOR_VERSION` are never
      ## in scope by the time the synthesized gate evaluates, and the
      ## `#ifndef`/`#error` visibility guard (`emitVersionMacroGuards`)
      ## fires with no in-directive fix. `header = "z3_version.h"` names
      ## the header that actually defines them; `genVerifyBlock` adds it to
      ## the block's own `#include` list (see its doc comment) so the
      ## macros are in scope before the synthesized `#if` (and the guard)
      ## ever run — without requiring a hand-rolled bridge header or an
      ## extra `-I` flag from the binding author.
    node*: NimNode             ## the directive call node, for diagnostic anchoring

func isValidCIdentifier(s: string): bool =
  ## A valid C identifier: `[A-Za-z_][A-Za-z0-9_]*`. Local to this module —
  ## the only consumer is `parseVersionMacrosDirective` below (a
  ## `versionMacros` argument names a C preprocessor macro, which must be a
  ## legal C identifier for `#ifndef`/`#if` to reference it at all).
  if s.len == 0: return false
  if s[0] != '_' and not s[0].isAlphaAscii: return false
  for i in 1 ..< s.len:
    let c = s[i]
    if c != '_' and not c.isAlphaAscii and not c.isDigit: return false
  true

func isVersionMacrosCall*(stmt: NimNode): bool =
  ## True when `stmt` is a `versionMacros ...` directive statement —
  ## `versionMacros("A", "B")` (`nnkCall`) or `versionMacros "A", "B"`
  ## (`nnkCommand`) — checked structurally against the bare identifier
  ## text, exactly like `isCompatManifestCall` above (the block's body is
  ## `untyped`, so nothing has been resolved to an actual symbol yet).
  stmt.kind in {nnkCall, nnkCommand} and stmt.len >= 1 and
    stmt[0].kind == nnkIdent and $stmt[0] == "versionMacros"

proc parseVersionMacrosDirective*(stmt: NimNode, macroName: string): VersionMacrosDirective =
  ## RFC-0002 §5/§6, slice E1 (extended for the Z3 `header =` case): parse
  ## one recognized `versionMacros` directive statement's argument shape —
  ## one or more positional string-literal arguments, each a valid C
  ## identifier, most-significant macro first (e.g.
  ## `versionMacros("Z3_MAJOR_VERSION", "Z3_MINOR_VERSION")`), plus an
  ## OPTIONAL `header = "..."` named argument accepted at any position
  ## among them (conventionally last) — see `VersionMacrosDirective.
  ## headerName`'s doc comment for why it exists. A non-string-literal
  ## positional argument, an argument that isn't a valid C identifier, a
  ## call with zero macro names, an unsupported named argument (anything
  ## but `header`), a non-string-literal or empty `header` value, or a
  ## second `header = ...` in the same call is a directive-specific macro
  ## error here, never the generic body-shape error `dynlib`/`verifyProcs`
  ## raise for an unrecognized statement.
  result.present = true
  result.node = stmt
  var names: seq[string] = @[]
  var headerSet = false
  for i in 1 ..< stmt.len:
    let arg = stmt[i]
    if arg.kind == nnkExprEqExpr:
      # A named argument (`name = value`) — `header` is the only one
      # `versionMacros` supports (mirrors `compatManifest`'s `refuse =`
      # handling above: a wrong name is an error naming the one supported
      # key, not a silent no-op or a generic-shape complaint).
      if arg.len == 2 and arg[0].kind == nnkIdent and $arg[0] == "header":
        if headerSet:
          error(macroName & ": versionMacros's 'header' argument was given " &
                "more than once — specify it at most once per " &
                "versionMacros(...) call", arg)
        headerSet = true
        if arg[1].kind notin {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
          error(macroName & ": versionMacros's 'header' argument must be a " &
                "string literal naming a C header, e.g. header = " &
                "\"z3_version.h\" (or header = \"<z3_version.h>\" for an " &
                "angle-bracket #include)", arg[1])
        elif arg[1].strVal.strip().len == 0:
          error(macroName & ": versionMacros's 'header' argument must be " &
                "non-empty", arg[1])
        else:
          result.headerName = arg[1].strVal
      else:
        let gotName = if arg.len >= 1 and arg[0].kind == nnkIdent: $arg[0]
                      else: "?"
        error(macroName & ": versionMacros's only supported named argument " &
              "is 'header' (got '" & gotName & "') — e.g. " &
              "versionMacros(\"FOO_MAJOR_VERSION\", header = " &
              "\"foo_version.h\")", arg)
    elif arg.kind notin {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
      error(macroName & ": versionMacros arguments must be string literals " &
            "naming C preprocessor macros, e.g. " &
            "versionMacros(\"FOO_MAJOR_VERSION\", \"FOO_MINOR_VERSION\")", arg)
    else:
      let name = arg.strVal
      if not isValidCIdentifier(name):
        error(macroName & ": versionMacros argument '" & name & "' is not " &
              "a valid C identifier ([A-Za-z_][A-Za-z0-9_]*)", arg)
      names.add(name)
  if names.len == 0:
    error(macroName & ": versionMacros requires at least one macro name " &
          "(e.g. versionMacros(\"FOO_MAJOR_VERSION\"))", stmt)
  result.macroNames = names

proc versionMacrosDupError*(macroName: string, first, second: VersionMacrosDirective): string =
  ## RFC-0002 §5/§6, slice E1: "at most one versionMacros per block, any
  ## position." Voiced like `compatManifestDupError` above (`versionMacros`,
  ## like `compatManifest` and unlike `versionProbe`, is accepted in BOTH
  ## `dynlib` and `verifyProcs`, so the message needs a `macroName` — the
  ## `versionProbeDupErrorMsg` const below can hardcode "dynlib" only
  ## because `versionProbe` never reaches `verifyProcs`'s duplicate check).
  "softlink: " & macroName & ": duplicate versionMacros directive in one " &
  "block (" & first.macroNames.join(", ") & " and " &
  second.macroNames.join(", ") & ") — merge them into a single " &
  "versionMacros(...) directive; a dynlib/verifyProcs block may declare " &
  "version macros at most once."

func isValidNimIdentifier(s: string): bool =
  ## RFC 0011 S0a item 1: is `s` a legal Nim identifier fragment for
  ## `identBase`'s override? Starts with an ASCII letter (never `_` — the
  ## SAME "must start with a letter" rule the pattern-derived `baseName`
  ## already enforces in the `dynlib` macro, right after its own
  ## derivation — requiring it here too means both paths converge on one
  ## shared invariant instead of two), each subsequent character a letter,
  ## digit, or a single underscore (Nim's identifier grammar forbids two
  ## consecutive underscores and a trailing one). The override is spliced
  ## by string concatenation into every generated identifier (`load<Base>`,
  ## `softlinkHandle<Base>`, `<lowerBase>Loaded`, ...), so it must be
  ## independently legal here — an invalid fragment would otherwise surface
  ## as an opaque parse error deep in the macro's OWN generated code, not a
  ## softlink diagnostic (CONTRIBUTING.md's "every macro error is
  ## softlink-authored" rule).
  if s.len == 0: return false
  if not s[0].isAlphaAscii: return false
  if s[^1] == '_': return false
  for i in 1 ..< s.len:
    let c = s[i]
    if c != '_' and not c.isAlphaAscii and not c.isDigit: return false
    if c == '_' and s[i - 1] == '_': return false
  true

type
  IdentBaseDirective* = object
    ## RFC 0011 S0a item 1: one parsed `identBase` body directive — at most
    ## one per `dynlib` block, any position (mirrors `CompatManifestDirective`
    ## et al above). UNLIKE those, `identBase` is not consumed by the
    ## `dynlib` macro's own per-statement body loop — its result must be
    ## known BEFORE `baseName` is derived, since `baseName` immediately
    ## drives every generated identifier the moment it's computed (see
    ## `scanIdentBase` below, and the `dynlib` macro's call to it ahead of
    ## its `baseName` derivation). `present == false` is the zero value (no
    ## directive in this block — `baseName` falls back to
    ## `libNameToIdent(libPattern)`, unchanged).
    present*: bool
    overrideName*: string  ## the validated identifier base, as written
    node*: NimNode          ## the directive call node, for diagnostic anchoring

func isIdentBaseCall*(stmt: NimNode): bool =
  ## True when `stmt` is an `identBase ...` directive statement —
  ## `identBase "Glib"` (`nnkCommand`) or `identBase("Glib")` (`nnkCall`) —
  ## checked structurally against the bare identifier text, exactly like
  ## `isCompatManifestCall` above (the block's body is `untyped`, so
  ## nothing has been resolved to an actual symbol yet).
  stmt.kind in {nnkCall, nnkCommand} and stmt.len >= 1 and
    stmt[0].kind == nnkIdent and $stmt[0] == "identBase"

proc parseIdentBaseDirective*(stmt: NimNode, macroName: string): IdentBaseDirective =
  ## RFC 0011 S0a item 1: parse one recognized `identBase` directive
  ## statement's argument shape — exactly one non-empty string-literal
  ## argument that is itself a valid Nim identifier (`isValidNimIdentifier`
  ## above). Any other shape (no argument, more than one, a non-literal
  ## argument, an empty string, or an invalid identifier) is a
  ## directive-specific macro error here, never the generic body-shape
  ## error `dynlib` raises for an unrecognized statement.
  result.present = true
  result.node = stmt
  if stmt.len != 2 or stmt[1].kind notin {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
    error(macroName & ": identBase requires exactly one string literal " &
          "argument naming the identifier base, e.g. identBase(\"Glib\")", stmt)
    return
  let name = stmt[1].strVal
  if name.len == 0:
    error(macroName & ": identBase's argument must be non-empty", stmt[1])
    return
  if not isValidNimIdentifier(name):
    error(macroName & ": identBase's argument '" & name &
          "' is not a valid Nim identifier", stmt[1])
    return
  result.overrideName = name

proc identBaseDupError*(macroName: string, first, second: IdentBaseDirective): string =
  ## RFC 0011 S0a item 1: "at most one identBase per block, any position" —
  ## voiced like `compatManifestDupError`/`versionMacrosDupError` above.
  "softlink: " & macroName & ": duplicate identBase directive in one " &
  "block ('" & first.overrideName & "' and '" & second.overrideName &
  "') — merge them into a single identBase directive; a dynlib block may " &
  "override its identifier base at most once."

proc scanIdentBase*(body: NimNode, macroName: string): IdentBaseDirective =
  ## RFC 0011 S0a item 1: scan `body` for an `identBase` directive BEFORE
  ## the `dynlib` macro's own per-statement body loop runs. This is why
  ## `identBase` is NOT a drop-in fourth case alongside `compatManifest`/
  ## `versionProbe`/`versionMacros`: those three are recognized inside that
  ## loop and consumed strictly AFTER it finishes, while `baseName` is
  ## derived BEFORE the loop even starts and immediately drives every
  ## generated identifier from that point on — so `identBase`'s result has
  ## to be available earlier than the loop, not later. The loop still
  ## recognizes `isIdentBaseCall` and `continue`s past any statement
  ## accepted here (this proc has already fully validated and consumed
  ## it), so it's never mistaken for a proc declaration and never
  ## re-emitted. Works "usable regardless of position in the block" by
  ## construction: this scan sees the WHOLE body up front, same as the
  ## macro's main loop does for the other three directives.
  for stmt in body:
    if isIdentBaseCall(stmt):
      let d = parseIdentBaseDirective(stmt, macroName)
      if result.present:
        error(identBaseDupError(macroName, result, d), stmt)
      else:
        result = d

type
  NoVerifyDirective* = object
    ## RFC 0011 S0a item 6: one parsed block-level `noverify: "reason"`
    ## directive — at most one per `dynlib` block, any position (mirrors
    ## `CompatManifestDirective`/`VersionMacrosDirective`/`IdentBaseDirective`
    ## above). UNLIKE `identBase`, this directive's effect (defaulting every
    ## bodyless proc with no OTHER verification source into
    ## `{.noverify: reason.}`) does not need to be known before anything
    ## else is derived — `baseName` doesn't depend on it — so it is
    ## recognized INSIDE the `dynlib` macro's ordinary per-statement body
    ## loop, exactly like `compatManifest`/`versionProbe`/`versionMacros`,
    ## and applied in a post-body-scan pass over the finalized `procs` list
    ## (`softlink/pragmas.applyNoVerifyDefault`) — the same restructuring
    ## `versionMacros`' gate synthesis (`synthesizeVersionGates`) already
    ## uses, and for the identical reason: the directive is
    ## position-independent and may appear anywhere in the block, including
    ## after every proc it defaults for. `present == false` is the zero
    ## value (no directive in this block — no proc is ever defaulted).
    present*: bool
    reason*: string  ## the validated, non-empty justification, as written
    node*: NimNode    ## the directive call node, for diagnostic anchoring

func isNoVerifyCall*(stmt: NimNode): bool =
  ## True when `stmt` is a block-level `noverify: "reason"` directive
  ## statement. The ONLY recognized shape is `nnkCall` whose sole argument
  ## is an `nnkStmtList` — Nim's colon-block call sugar, exactly like
  ## `isVersionProbeStmt` above (empirically confirmed: `noverify: "x"` at
  ## statement level parses to `Call(Ident"noverify", StmtList(StrLit"x"))`,
  ## never a bare `nnkCommand`/plain `nnkCall` with the string as a direct
  ## argument, unlike `compatManifest`/`identBase`'s own recognizers).
  ## Checked structurally against the bare identifier text, exactly like
  ## every other directive recognizer in this file — the block's body is
  ## `untyped`, so nothing has been resolved to an actual symbol yet.
  ##
  ## Deliberately narrower than `isCompatManifestCall`/`isIdentBaseCall`
  ## (which also accept `nnkCommand`, space-separated call syntax):
  ## `noverify` is ALSO a per-proc PRAGMA name recognized inside a
  ## `{.pragma, list.}`, never as a bare top-level command call today, so
  ## there is no existing `noverify "reason"` spelling to stay compatible
  ## with — requiring the colon form keeps the block-level spelling
  ## visually identical to the per-proc pragma's own
  ## `{.noverify: "...".}`, one spelling for two positions (block body vs.
  ## pragma list).
  stmt.kind == nnkCall and stmt.len == 2 and stmt[0].kind == nnkIdent and
    $stmt[0] == "noverify" and stmt[1].kind == nnkStmtList

proc parseNoVerifyDirective*(stmt: NimNode, macroName: string): NoVerifyDirective =
  ## RFC 0011 S0a item 6: parse one recognized block-level `noverify: ...`
  ## directive statement. The only well-formed shape is a colon-block body
  ## of EXACTLY one non-empty string literal — `noverify: "<justification>"`.
  ## UNLIKE the per-proc `{.noverify.}` pragma (whose justification is
  ## OPTIONAL — bare `{.noverify.}` is legal, see `parseNoVerifyReasonExpr`,
  ## `softlink/pragmas`), the block-level form REQUIRES one: an empty/bare
  ## block default would silently waive verification for every bodyless
  ## proc in the block that carries no other verification source, a far
  ## bigger blast radius than one proc's own opt-out, and deserves a real
  ## reason on its face (RFC 0011 S0a item 6 design guidance). Any other
  ## shape — an empty colon-block body, more than one statement in it, a
  ## non-string-literal expression, or an empty string — is a
  ## directive-specific macro error here, never the generic body-shape
  ## error `dynlib` raises for an unrecognized statement.
  result.present = true
  result.node = stmt
  let bodyStmts = stmt[1]
  if bodyStmts.len != 1 or bodyStmts[0].kind notin {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
    error(macroName & ": block-level noverify requires exactly one string " &
          "literal justification, e.g. noverify: \"private symbol, no " &
          "public header at any version\" — unlike the per-proc " &
          "{.noverify.} pragma, the block-level default cannot be bare: a " &
          "whole-block opt-out needs a real reason", stmt)
    return
  let reason = bodyStmts[0].strVal
  if reason.strip().len == 0:
    error(macroName & ": block-level noverify's justification must be " &
          "non-empty", bodyStmts[0])
    return
  result.reason = reason

proc noVerifyDupError*(macroName: string, first, second: NoVerifyDirective): string =
  ## RFC 0011 S0a item 6: "at most one block-level noverify per block, any
  ## position" — voiced like `compatManifestDupError`/`versionMacrosDupError`/
  ## `identBaseDupError` above.
  "softlink: " & macroName & ": duplicate block-level noverify directive " &
  "in one block ('" & first.reason & "' and '" & second.reason & "') — " &
  "merge them into a single noverify: \"...\" directive; a dynlib block " &
  "may declare a block-level noverify default at most once."

type
  AppliedManifest* = object
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

proc applyCompatManifest*(mode: ProcPragmaMode, libNameForIdentity: string,
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
    let sc = checkSince(m, p.cName, p.sinceVersion)
    if sc.contradicted:
      error(sc.message, p.name)

  # Check 6b (RFC-0002 §4.2/§6, slice B2): until-contradiction — same call
  # site, hard error, no escape hatch, mirroring Check 6 above exactly.
  # `checkUntil` (softlink/manifest) runs its own three-rule spec (over-
  # claim, over-caution/revert, positive-evidence) and computes the
  # corrected bound in its message; this loop's only job is turning a
  # `contradicted` result into a macro error anchored at the proc, same as
  # Check 6. Order relative to Check 6 doesn't matter (RFC-0002 §4.2): a
  # proc with both `since` and `until` gets both checked, independently,
  # against the same manifest.
  for p in procs:
    if p.untilVersion.len == 0: continue
    let uc = checkUntil(m, p.cName, p.sinceVersion, p.untilVersion)
    if uc.contradicted:
      error(uc.message, p.name)

  # Bound, harvester-trackable C names — `isCorpusTrackable` (softlink/
  # versions, code-review finding #21) is the SAME predicate `tools/harvest/
  # harvester.nim`'s `harvest` uses to decide what it records: excludes
  # `noverify` (nothing to probe) and prototype-only procs (corpus-
  # invariant, never in a manifest by design). Shared by checks 7 and 8.
  var trackable: seq[string] = @[]
  for p in procs:
    if isCorpusTrackable(p.noVerify, p.headerFile.len > 0): trackable.add p.cName

  # Check 7: mismatch warning. Partitioned per the nim-z3 report
  # (softlink-mismatch-warning-issue.md) / CHECK7-WARNING.handoff.md: a
  # symbol's recorded `mismatch` interval is either UNCOVERED (no declared
  # bound explains it — genuine unexpected drift, keep the WARNING, text
  # UNCHANGED so the existing nimble grep pins for the unbounded fixture
  # stay valid) or bound-COVERED (`mismatchCoveredByUntil`, softlink/
  # manifest — every mismatch interval lies at-or-above a declared
  # `{.until.}`, downgraded to a HINT: expected, not a surprise).
  #
  # `covered` can ONLY mean "declares `until`, and the bound is consistent"
  # — no other shape reaches here. Every symbol Check 6 (checkSince) and
  # Check 6b (checkUntil) validated above already hard-`error`ed out of
  # expansion if its bound were inconsistent with the manifest: checkSince
  # rule (b) hard-errors a `verified`/`mismatch` fact BELOW a declared
  # `since` (so a `since`-only symbol's mismatch, if any, is never below
  # its own lower bound — but `since` alone says nothing about an UPPER
  # bound, so a since-only mismatch is never "covered", only ever
  # uncovered/genuine drift), and checkUntil rule (a) hard-errors a
  # `mismatch` fact INSIDE the declared `[since|-∞, until)` window. A
  # symbol that both declares `until` and survives to this point therefore
  # has every mismatch interval at-or-above that `until` by construction —
  # `mismatchCoveredByUntil` re-derives this from the manifest data
  # directly (invariant-independent: it doesn't merely trust the check
  # ordering above) rather than assuming it.
  let mismatched = mismatchedSymbols(m, trackable)
  var uncoveredMismatch, coveredMismatch: seq[string] = @[]
  for name in mismatched:
    var untilForName = ""
    for p in procs:
      if p.cName == name:
        untilForName = p.untilVersion
        break
    if mismatchCoveredByUntil(m, name, untilForName):
      coveredMismatch.add name
    else:
      uncoveredMismatch.add name

  if uncoveredMismatch.len > 0:
    warning("softlink: " & macroName & ": compat manifest " & absPath &
            ": " & $uncoveredMismatch.len & " symbol" &
            (if uncoveredMismatch.len != 1: "s" else: "") &
            " recorded a 'mismatch' interval: " & uncoveredMismatch.join(", ") &
            " — see the drift alarm / softlink harvest for details",
            directive.node)

  if coveredMismatch.len > 0:
    let coveredMsg = "softlink: " & macroName & ": compat manifest " & absPath &
            ": " & $coveredMismatch.len & " bound-covered mismatch" &
            (if coveredMismatch.len != 1: "es" else: "") &
            " (expected; declared {.until.}): " & coveredMismatch.join(", ") &
            " — the recorded drift is fully explained by the declared " &
            "bound; see the drift alarm / softlink harvest for details"
    when defined(softlinkStrictVerify):
      warning(coveredMsg, directive.node)
    else:
      hint(coveredMsg, directive.node)

  # Check 8: not-in-manifest hint. RFC-0002 §4.4, code-review finding CR1-1:
  # a bounded (`{.since/until.}`) proc entirely absent from the manifest gets
  # NO compile-time `checkSince`/`checkUntil` validation at all (both
  # vacuously pass on `findSymbol(...).isNone`) and, at runtime, relies
  # solely on the attested-path declared-bound refusal this same finding adds
  # (`softlink.nim`) — this hint is the one compile-time signal such a gap
  # ever gets. Escalated to a Warning under `-d:softlinkStrictVerify`, same
  # audit-mode convention as the `{.noverify.}` hint and the drifted-but-
  # required hint (`softlink.nim`'s own two trust-point hints) — still a
  # Hint, never a hard error, in default builds: the maintainer chose
  # runtime enforcement over forcing a re-harvest.
  let missing = notInManifest(m, trackable)
  if missing.len > 0:
    let notInManifestMsg = "softlink: " & macroName & ": " & $missing.len & " symbol" &
         (if missing.len != 1: "s" else: "") & " not in compat manifest " &
         absPath & " — regenerate with softlink harvest"
    when defined(softlinkStrictVerify):
      warning(notInManifestMsg, directive.node)
    else:
      hint(notInManifestMsg, directive.node)

  # Check 9 (the degraded-tier warning) is emitted by `genVerifyBlock`
  # itself, into the graceful `#else` fallback branch — this proc's
  # `attached: true` return is the signal that tells it to. `manifest: m`
  # is the B6b addition: the fully parsed manifest, handed back so the
  # `dynlib` macro can embed its `symbols` verbatim into
  # `softlinkCompatFacts<Base>`.
  AppliedManifest(attached: true, manifest: m)
