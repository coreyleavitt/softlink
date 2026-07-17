## `softlink/pragmas` — RFC-0001's per-proc pragma parsing (calling
## convention, `header`, `optional`, `noverify`, `verifyWhen`, `since`,
## `prototype`) and the `dynlib`/`verifyProcs` body directives
## (`compatManifest`, `versionProbe`) that sit alongside proc declarations
## in a block body, plus the compile-time compat-manifest consumption
## pipeline (`applyCompatManifest`) that acts on a parsed `compatManifest`
## directive. Extracted from `src/softlink.nim` (code-review finding #13):
## none of the procs below close over any `dynlib`/`verifyProcs` macro
## local — every one takes its inputs as explicit parameters (the parsed
## `NimNode`s, a `ProcPragmaMode`, a `seq[SoftlinkProc]`, ...) and returns
## plain data or emits a diagnostic anchored at the node it was given.
##
## Shared by both `dynlib` and `verifyProcs` (still in `src/softlink.nim`),
## which disagree on what a few of these pragmas/directives mean
## (`ProcPragmaMode` exists precisely to let ONE parser encode both sets of
## rules) but agree on the token recognition and AST shapes themselves.

import std/[macros, strutils, os]
import ./versions
import ./manifest
import ./prototype
import ./procinfo

func pragmaKeyName*(pragma: NimNode): string =
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
  ProcPragmaMode* = enum
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

proc parseProcPragmas*(stmt: NimNode, nameStr: string, mode: ProcPragmaMode): ProcPragmaFacts =
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
