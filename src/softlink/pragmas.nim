## `softlink/pragmas` — RFC-0001's per-proc pragma parsing (calling
## convention, `header`, `optional`, `noverify`, `verifyWhen`, `since`,
## `prototype`) plus RFC-0002's `until` that sit alongside proc
## declarations in a `dynlib`/
## `verifyProcs` block body. Extracted from `src/softlink.nim` (code-review
## finding #13): none of the procs below close over any `dynlib`/
## `verifyProcs` macro local — every one takes its inputs as explicit
## parameters (the parsed `NimNode`s, a `ProcPragmaMode`, ...) and returns
## plain data or emits a diagnostic anchored at the node it was given.
##
## Shared by both `dynlib` and `verifyProcs` (still in `src/softlink.nim`),
## which disagree on what a few of these pragmas mean (`ProcPragmaMode`
## exists precisely to let ONE parser encode both sets of rules) but agree
## on the token recognition itself.
##
## The block-level directive recognition (`compatManifest`/`versionProbe`)
## and the compat-manifest application pipeline (`applyCompatManifest`)
## that used to live here moved to `softlink/directives` (code-review
## finding R2-4) — a different concern (block-level AST shapes plus
## I/O-performing orchestration) from this module's per-proc pragma
## parsing. `ProcPragmaMode` itself moved to `softlink/procinfo` in the
## same pass, so that neither this module nor `softlink/directives` has to
## import the other just to share the enum — both import `procinfo`
## instead, and neither imports the other.

import std/[macros, strutils]
import ./versions
import ./prototype
import ./procinfo
import ./gates

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

proc parseVersionBoundExpr(pragma, stmt: NimNode, nameStr, pragmaName: string): string =
  ## Shared implementation behind `parseSinceExpr`/`parseUntilExpr` (code-
  ## review finding CR1-9: the two were copy-paste twins differing only in
  ## which pragma name — "since" or "until" — appears in the error text).
  ## Extract and validate one proc's `{.since/until: "x.y.z".}` claim — a
  ## non-empty string literal that must additionally `parseVersion`
  ## successfully (`softlink/versions`), since a bound that can't even be
  ## compared is worse than none. Shared by `dynlib` and `verifyProcs`: the
  ## since-contradiction check (`softlink/manifest.checkSince`) needs the
  ## since flavor in both, and Stage C's runtime consumption (§C.2/§C.3,
  ## `dynlib`-only) is a separate, later concern from this pragma's parse.
  ## The until flavor mirrors it exactly (RFC-0002 §4.1/§6, slice A1): an
  ## exclusive upper bound, `[since, until)`, on the interval over which the
  ## symbol's signature is attested — slice A1 does no semantics beyond
  ## parse + store + carry (no since>=until contradiction check; that's a
  ## later slice, `parseProcPragmas` below).
  if pragma.kind == nnkExprColonExpr and
     pragma[1].kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit} and
     pragma[1].strVal.strip().len > 0:
    let v = pragma[1].strVal
    if parseVersion(v).isNone:
      error("proc '" & nameStr & "': " & pragmaName & " pragma value '" & v &
            "' does not parse as a version (softlink/versions.parseVersion " &
            "found no digit or alphabetic run in it)", stmt)
    v
  else:
    error("proc '" & nameStr &
          "' " & pragmaName & " pragma requires a non-empty version string " &
          "literal (e.g., {." & pragmaName & ": \"4.15.0\".})", stmt)
    ""

proc parseSinceExpr(pragma, stmt: NimNode, nameStr: string): string =
  ## RFC-0001 §C.2/§B.5, slice B6a: thin wrapper over `parseVersionBoundExpr`
  ## for the `since` pragma.
  parseVersionBoundExpr(pragma, stmt, nameStr, "since")

proc parseUntilExpr(pragma, stmt: NimNode, nameStr: string): string =
  ## RFC-0002 §4.1/§6, slice A1: thin wrapper over `parseVersionBoundExpr`
  ## for the `until` pragma.
  parseVersionBoundExpr(pragma, stmt, nameStr, "until")

func isValidCIdentifier(s: string): bool =
  ## RFC 0011 S0a item 3: the syntactic shape `{.symbol: "...".}` must
  ## satisfy — a C identifier is `[A-Za-z_][A-Za-z0-9_]*`, nothing more.
  ## softlink splices this string as literal C text (both `symAddr`
  ## emission sites, the call-based `_Static_assert` chain), so anything
  ## else would either fail confusingly deep in generated C or, worse,
  ## "successfully" compile as something other than a plain symbol
  ## reference — this check turns that into a softlink-authored error at
  ## the pragma itself.
  if s.len == 0: return false
  if s[0] != '_' and not s[0].isAlphaAscii: return false
  for c in s:
    if c != '_' and not c.isAlphaNumeric: return false
  true

proc parseSymbolExpr(pragma, stmt: NimNode, nameStr: string): string =
  ## RFC 0011 S0a item 3: extract and validate the `{.symbol: "c_name".}`
  ## rename pragma — a non-empty string literal that is additionally a
  ## syntactically valid C identifier (see `isValidCIdentifier`). Softlink
  ## deliberately does not spell this `importc` (bare or valued) — that's a
  ## real Nim compiler pragma name for an unrelated axis (the FFI import
  ## mechanism itself), and borrowing it here while making the bare form
  ## every Nim FFI author reflexively types a hard error would be a false
  ## friend; `symbol:` matches how softlink's own source already talks
  ## about "the C symbol" vs. the Nim name. `importc`, bare or valued, is
  ## therefore simply an unrecognized pragma in a `dynlib`/`verifyProcs`
  ## body — the existing "does not support pragma" error below covers it,
  ## with no special case needed here.
  ##
  ## On a malformed value, falls back to `nameStr` (the pre-item-3 identity
  ## default) rather than "" — `error()` has already doomed this compile;
  ## the fallback only keeps the caller's prescan (which needs SOME string
  ## before the rest of this proc's per-pragma loop runs — see the
  ## `prototype` branch, which reads the resolved C name mid-loop) from
  ## operating on an empty string while the real diagnostic propagates.
  if pragma.kind == nnkExprColonExpr and
     pragma[1].kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit} and
     pragma[1].strVal.strip().len > 0:
    let v = pragma[1].strVal
    if isValidCIdentifier(v):
      v
    else:
      error("proc '" & nameStr & "': symbol pragma value '" & v &
            "' is not a valid C identifier", stmt)
      nameStr
  else:
    error("proc '" & nameStr &
          "' symbol pragma requires a non-empty C identifier string " &
          "literal (e.g., {.symbol: \"g_object_set\".})", stmt)
    nameStr

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
  ProcPragmaFacts = object
    ## Pragma-derived facts for one proc, independent of the proc's name/
    ## signature — merged by each caller into its own per-proc record
    ## (`SoftlinkProc`).
    callConv*: string
    cName*: string  ## RFC 0011 S0a item 3: the resolved EFFECTIVE C name —
      ## always non-empty (defaults to the proc's own `nameStr` when no
      ## `{.symbol: "...".}` pragma is present). See `SoftlinkProc.cName`'s
      ## own doc comment (softlink/procinfo) for the full consumer list.
    headerFile*: string
    isOptional*: bool
    noVerify*: bool
    noVerifyReason*: string  ## RFC-0001 §3 A.2: {.noverify: "why".} justification; "" if none given
    verifyWhen*: string  ## C preprocessor expr gating verification; "" = always
    prototype*: string   ## raw {.prototype: "...".} string; "" if absent
    prototypeName*: string  ## tokenizer-extracted C name; "" if absent
    sinceVersion*: string  ## RFC-0001 §B.5/§C.2: {.since: "x.y.z".} claim; "" if absent
    untilVersion*: string  ## RFC-0002 §4.1/§6, slice A1: {.until: "x.y.z".} claim; "" if absent

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

  # RFC 0011 S0a item 3: `symbol: "c_name"` is prescanned FIRST, in its own
  # pass over this proc's pragma list, independent of the main per-pragma
  # loop below — because the `prototype` branch of THAT loop needs the
  # resolved EFFECTIVE C name to validate its own name-match rule
  # (`parsePrototypePragma`'s `cName` param) regardless of whether `symbol:`
  # happens to appear before or after `prototype:` in the author's own
  # pragma order (Nim pragma lists carry no ordering guarantee softlink can
  # rely on). Scoped to just this ONE proc's own pragma list — not a
  # deferred post-body-scan pass like `applyNoVerifyDefault`'s block-level
  # directive, which can legitimately appear anywhere in the whole block —
  # so a simple prescan-before-the-real-loop suffices here; nothing outside
  # this proc's own pragmas needs to be visible yet. Duplicate `symbol:`
  # pragmas on one proc are NOT rejected — same "last one wins" convention
  # every other value-carrying pragma here already has (`header`/`since`/
  # `until`/etc. — none of them dup-check either). Uniform across both
  # `ProcPragmaMode`s (design guidance: "support it uniformly, same parsing
  # path" — a rename axis is exactly as meaningful when cross-checking a
  # vendored/header declaration in `verifyProcs` as it is for `dynlib`'s
  # runtime `symAddr` lookup), so no `mode` branch here at all.
  result.cName = nameStr
  if pragmas.kind == nnkPragma:
    for pragma in pragmas:
      if pragmaKeyName(pragma) == "symbol":
        result.cName = parseSymbolExpr(pragma, stmt, nameStr)

  if pragmas.kind == nnkPragma:
    for pragma in pragmas:
      let pragmaName = pragmaKeyName(pragma)
      if pragmaName in callingConventions:
        if mode == ppmDynlib and result.callConv != "":
          error("proc '" & nameStr & "' has multiple calling conventions", stmt)
        result.callConv = pragmaName
      elif pragmaName == "symbol":
        discard  # already resolved into result.cName by the prescan above
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
      elif pragmaName == "until":
        result.untilVersion = parseUntilExpr(pragma, stmt, nameStr)
      elif pragmaName == "prototype":
        let (raw, name) = parsePrototypePragma(pragma, stmt, nameStr, result.cName)
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

  # RFC-0002 §4.1/§6, slice A2: since >= until (including since == until) is
  # an empty interval [since, until) — nothing is ever in range. Compared via
  # `cmpVersion` (softlink/versions), never string comparison, since e.g.
  # "4.9.0" < "4.10.0" would sort backwards as strings. Shared by both
  # `dynlib` and `verifyProcs` — both funnel through this proc — so one site
  # suffices for both.
  if result.sinceVersion.len > 0 and result.untilVersion.len > 0 and
     cmpVersion(result.sinceVersion, result.untilVersion) >= 0:
    error("proc '" & nameStr & "': since '" & result.sinceVersion &
          "' >= until '" & result.untilVersion &
          "' is an empty interval [since, until) — since must be strictly " &
          "before until", stmt)

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
    # RFC-0002 §4.1/§6, slice A3: `until` requires corpus-trackability
    # (`isCorpusTrackable = not noVerify and hasHeader`, `softlink/
    # versions.nim`) — an upper bound on a symbol nothing probes is an
    # unfalsifiable claim. Symmetric to the verifyWhen+noverify and
    # prototype+noverify contradictions just above; verifyProcs never
    # reaches here since it rejects {.noverify.} outright before this
    # point (result.noVerify stays false there).
    if result.noVerify and result.untilVersion.len > 0:
      error("proc '" & nameStr & "': {.until.} contradicts {.noverify.} — " &
            "until requires the symbol to be corpus-trackable (a header " &
            "the harvester can cross-check the declared bound against), " &
            "but noverify skips verification entirely, leaving nothing to " &
            "falsify the bound against. Use until alone once the symbol " &
            "has a header, or noverify alone if it will never have one", stmt)
    # RFC 0011 S0a item 6: the "must specify a header, a prototype, or
    # {.noverify.}" check used to run RIGHT HERE, inline, per proc. It has
    # moved to `checkVerificationSourceRequired` below — a post-body-scan
    # pass over the FINALIZED `procs` seq, called after
    # `applyNoVerifyDefault` has applied any block-level `noverify: "..."`
    # default. A block-level directive is position-independent (like every
    # other body directive) and may be declared AFTER the proc it defaults
    # for; this inline, per-proc, first-pass check could never see one
    # declared later in the same block. See `checkVerificationSourceRequired`'s
    # own doc comment for the full rationale (it mirrors
    # `synthesizeVersionGates`' identical restructuring). `ppmVerifyProcs`
    # below is UNAFFECTED and keeps its own inline check: verifyProcs
    # accepts no `noverify` at all (per-proc or block-level), so it can
    # never depend on a later-declared directive and needs no deferral.
  else:
    if result.headerFile == "" and result.prototype.len == 0:
      error("proc '" & nameStr &
            "' must specify a header pragma (e.g., {.header: \"foo.h\".}) " &
            "or a prototype pragma (e.g., {.prototype: \"" & nameStr &
            "(...)\".})", stmt)

  # RFC-0002 §4.1/§6, slice A3: `until` on a prototype-only proc (no
  # {.header.}) is likewise rejected — a {.prototype.}-only symbol verifies
  # against a vendored, corpus-INVARIANT declaration that never varies by
  # installed headers (`isCorpusTrackable`, `softlink/versions.nim`), so it
  # has no per-version facts to harvest or compare and the declared bound
  # is unfalsifiable. `prototype` + `header` TOGETHER (cross-check mode) is
  # trackable via the header and stays accepted — this only fires when
  # `header` is absent. Shared by both modes: a prototype-only proc with no
  # `header` is a valid shape in `verifyProcs` too (see the `header`-or-
  # `prototype` requirement in the branch above), so `until`'s
  # non-trackability there is exactly as unfalsifiable as in `dynlib`.
  if result.untilVersion.len > 0 and result.headerFile == "" and result.prototype.len > 0:
    error("proc '" & nameStr & "': {.until.} on a prototype-only proc (no " &
          "{.header.}) is not corpus-trackable — a vendored prototype " &
          "verifies against a corpus-invariant declaration with no " &
          "per-version facts to harvest or compare, so the declared bound " &
          "is unfalsifiable. Add {.header.} to cross-check via the header " &
          "(prototype + header may coexist), or drop until", stmt)

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

proc applyNoVerifyDefault*(procs: var seq[SoftlinkProc], noVerifyBlockPresent: bool,
                            noVerifyBlockReason: string) =
  ## RFC 0011 S0a item 6: the block-level `noverify: "reason"` directive's
  ## effect — default every bodyless proc carrying NONE of its own
  ## `{.header.}`/`{.prototype.}`/`{.noverify.}` into
  ## `{.noverify: noVerifyBlockReason.}`, marking it `noVerifyFromBlockDefault`
  ## so the audit hint (`dynlib`, near its own noverify-hint block) can
  ## collapse every such proc into one summary line instead of one line
  ## each. A no-op when `noVerifyBlockPresent` is false (the overwhelming
  ## majority of blocks, which declare no block-level default at all) —
  ## purely additive, byte-for-byte unchanged for every pre-item-6 block.
  ##
  ## Deliberately takes the directive's two facts as plain parameters
  ## (`present`/`reason`) rather than `directives.NoVerifyDirective` itself
  ## — the SAME reason `synthesizeVersionGates` above takes
  ## `versionMacrosPresent`/`versionMacroNames` instead of
  ## `directives.VersionMacrosDirective`: this module's own header doc
  ## comment already establishes "neither this module nor
  ## `softlink/directives` has to import the other" as an invariant, and a
  ## plain-data parameter list preserves it instead of quietly
  ## reintroducing the dependency.
  ##
  ## MUST run as a post-body-scan pass (`procs` fully collected), called
  ## BEFORE `checkVerificationSourceRequired` below (so a defaulted proc's
  ## `noVerify` is already true by the time that check inspects it) — for
  ## the identical reason `synthesizeVersionGates` documents on itself: a
  ## block directive is position-independent and may be declared AFTER the
  ## proc(s) it affects, so nothing here can run inline during the
  ## first-pass per-proc scan (`parseProcPragmas` above).
  ##
  ## Scope, pinned by RFC 0011 S0a item 6's design guidance: a proc
  ## inherits the default iff it carries NONE of `{.header.}`,
  ## `{.prototype.}`, its OWN `{.noverify.}`, `{.verifyWhen.}`, OR
  ## `{.until.}` — not merely the first three. `{.verifyWhen.}` and
  ## `{.until.}` are excluded deliberately, even though neither is itself a
  ## verification SOURCE (a proc with only one of them and no header still
  ## has nothing to verify against): inheriting the default onto such a
  ## proc would set `noVerify = true` underneath a pragma the proc's AUTHOR
  ## never paired it with, and immediately trip the "{.verifyWhen.}
  ## contradicts {.noverify.}" / "{.until.} contradicts {.noverify.}"
  ## contradiction errors just above — errors that would misattribute the
  ## mistake to a `{.noverify.}` the author never wrote. Simpler and more
  ## honest (this is the resolution RFC 0011 S0a item 6 itself lands on
  ## after considering, and rejecting, "inherit and let the contradiction
  ## fire anyway"): such a proc is left exactly as it was pre-item-6 — its
  ## `noVerify` stays false, and `checkVerificationSourceRequired` below
  ## still rejects it with the ordinary "must specify a header pragma..."
  ## message, unaffected by whether a block-level default exists elsewhere
  ## in the same block. See `tests/tfail_noverify_block_until_no_header.nim`/
  ## `tests/tfail_noverify_block_verifywhen_no_header.nim` for the pin.
  if not noVerifyBlockPresent: return
  for i in 0 ..< procs.len:
    if procs[i].headerFile.len == 0 and procs[i].prototype.len == 0 and
       not procs[i].noVerify and procs[i].verifyWhen.len == 0 and
       procs[i].untilVersion.len == 0:
      procs[i].noVerify = true
      procs[i].noVerifyReason = noVerifyBlockReason
      procs[i].noVerifyFromBlockDefault = true

proc checkVerificationSourceRequired*(procs: seq[SoftlinkProc]) =
  ## RFC 0011 S0a item 6: dynlib's "every proc must specify a header, a
  ## prototype, or {.noverify.}" invariant — DEFERRED to a post-body-scan
  ## pass (mirrors `synthesizeVersionGates`' own restructuring rationale,
  ## `softlink/pragmas` itself already precedents this pattern) because a
  ## block-level `noverify: "reason"` directive (`applyNoVerifyDefault`
  ## above, which MUST run immediately before this proc, in the same
  ## relative order `synthesizeVersionGates`/`checkUntilRequiresGate` use)
  ## can appear anywhere in the body, including after the proc it defaults
  ## for — an inline check during the first-pass per-proc scan could never
  ## see a directive declared later in the same block.
  ##
  ## Message text is UNCHANGED from the pre-item-6 inline check (word for
  ## word) — every existing test pinning it stays green without
  ## modification; only the TIMING of when it fires moved, not its wording
  ## or its trigger condition (`headerFile == "" and not noVerify and
  ## prototype.len == 0`, exactly as before — `noVerify` is simply now
  ## possibly true via the block default rather than only ever via the
  ## proc's own pragma).
  ##
  ## `verifyProcs` has NO counterpart of this deferral: its own inline
  ## check (`parseProcPragmas`'s `ppmVerifyProcs` branch, just above)
  ## accepts no `noverify` at all — per-proc or block-level — so it can
  ## never depend on a later-declared directive.
  for p in procs:
    if p.headerFile.len == 0 and not p.noVerify and p.prototype.len == 0:
      error("proc '" & p.nameStr &
            "' must specify a header pragma (e.g., {.header: \"foo.h\".}), " &
            "a prototype pragma (e.g., {.prototype: \"" & p.nameStr &
            "(...)\".}), or {.noverify.} to skip compile-time header " &
            "verification", p.name)

proc checkUntilRequiresGate*(procs: seq[SoftlinkProc], macroName: string) =
  ## RFC-0002 §4.1/§5/§6, slice D1: `{.until.}` REQUIRES `{.verifyWhen.}` —
  ## unconditionally, manifest or no manifest. Deliberately NOT folded into
  ## `parseProcPragmas` above (which sees one proc, in isolation, at parse
  ## time): Stage E's `versionMacros` directive (§5 Layer 2) is an
  ## any-position block directive whose synthesis assigns `p.verifyWhen`
  ## in this same post-body-scan phase, upstream of this check (§4.1) — an
  ## inline per-proc check could never see a directive declared LATER in
  ## the block. So this is its own pass over the finalized `procs` seq,
  ## called once per macro expansion after the whole body has been
  ## collected, mirroring `softlink/manifest.checkSince`'s own post-loop
  ## call site (`softlink/directives.applyCompatManifest`) — except this
  ## check is NOT manifest-gated: `applyCompatManifest` returns immediately
  ## with no `compatManifest` directive attached, but an ungated bounded
  ## declaration is dangerous with or without one (the risk is intrinsic to
  ## asserting a declared signature against a live, possibly-newer-than-
  ## `until` header — RFC-0002 §4.2, "without a versionProbe at all... they
  ## are compile-time declaration + cross-check only"), so `dynlib` and
  ## `verifyProcs` both call this directly, unconditionally.
  ##
  ## Without a gate, verification asserts the DECLARED signature against
  ## whatever header is installed, unconditionally — including a header new
  ## enough to have already drifted past `until` (RFC-0002 §5: "a mechanical
  ## gate is correct by construction; a hand-written one is checkable by
  ## nobody" is the argument for Stage E's synthesis, but D1 alone already
  ## catches the strictly worse case of NO gate at all). The fix is either
  ## a hand-written `{.verifyWhen.}` (exactly like today's `since`-only
  ## style) or a block-level `versionMacros(...)` directive, whose
  ## synthesis (`synthesizeVersionGates` below, slice E2) runs immediately
  ## before this check and satisfies it without any per-proc source change.
  for p in procs:
    if p.untilVersion.len > 0 and p.verifyWhen.len == 0:
      error("softlink: " & macroName & ": proc '" & p.nameStr & "': " &
            "{.until.} requires a {.verifyWhen.} gate — without one, " &
            "verification unconditionally asserts the declared signature, " &
            "which is wrong against a header new enough to have already " &
            "drifted past 'until' (RFC-0002 §5); add {.verifyWhen: " &
            "\"...\".} by hand, or declare versionMacros(...) on this " &
            "block to synthesize it automatically", p.name)

func boundLabel(bound: BoundKind): string =
  case bound
  of bkSince: "since"
  of bkUntil: "until"

proc synthesizeVersionGates*(procs: var seq[SoftlinkProc], versionMacrosPresent: bool,
                              versionMacroNames: seq[string], macroName: string) =
  ## RFC-0002 §5/§6, slice E2: the macro-facing consumer of the pure
  ## generator in `softlink/gates` — assigns a synthesized `{.verifyWhen.}`
  ## predicate into `p.verifyWhen` for every qualifying proc. Deliberately
  ## takes the directive's two facts as plain parameters (`present`/
  ## `macroNames`) rather than `directives.VersionMacrosDirective` itself:
  ## this module's own doc comment already establishes "neither this module
  ## nor `softlink/directives` has to import the other" as an invariant
  ## (`ProcPragmaMode`'s move to `procinfo`), and a plain-data parameter
  ## list preserves it instead of quietly reintroducing the dependency.
  ##
  ## MUST run as a post-body-scan pass, called IMMEDIATELY BEFORE
  ## `checkUntilRequiresGate` (both call sites, `dynlib` and `verifyProcs`)
  ## — a successfully-synthesized predicate is assigned into `p.verifyWhen`
  ## here so that check sees a satisfied gate and never fires for it.
  ##
  ## Scope (§5): only procs carrying `untilVersion` (with or without
  ## `sinceVersion`) AND no explicit `{.verifyWhen.}` are touched.
  ## - A `since`-only proc is NEVER synthesized, even under a
  ##   `versionMacros` block declared for some OTHER proc's benefit —
  ##   RFC-0001 shipped since-only procs ungated, and `versionMacros`
  ##   existing elsewhere in the block must not silently start gating them.
  ## - An explicit `{.verifyWhen.}` on the proc ALWAYS wins (the documented
  ##   escape hatch) — this proc is skipped entirely, `verifyWhen` stays
  ##   exactly as the author wrote it, and `synthesizedGateMacros` stays
  ##   empty (so `genVerifyBlock` emits no visibility guard for it either —
  ##   §5: the override "forgoes by-construction consistency... and the
  ##   visibility guards").
  ## - No `versionMacros` directive in this block at all: a no-op, exactly
  ##   as before this slice (every `until`-carrying proc still needs a hand
  ##   `{.verifyWhen.}`, caught by `checkUntilRequiresGate` right after).
  if not versionMacrosPresent:
    return
  for i in 0 ..< procs.len:
    if procs[i].untilVersion.len == 0 or procs[i].verifyWhen.len > 0:
      continue
    let nameStr = procs[i].nameStr
    let node = procs[i].name
    let res = synthesizeGate(versionMacroNames, procs[i].sinceVersion, procs[i].untilVersion)
    if res.ok:
      procs[i].verifyWhen = res.predicate
      procs[i].synthesizedGateMacros = res.usedMacros
    else:
      let e = res.error
      case e.kind
      of geAlphaRun:
        error("softlink: " & macroName & ": proc '" & nameStr &
              "': versionMacros gate synthesis for " & boundLabel(e.bound) &
              " '" & e.value & "' failed — the bound contains a " &
              "non-numeric (alphabetic) run; there is no C macro a " &
              "pre-release/suffixed component like this could compare " &
              "against. Use an all-numeric dotted version for " &
              boundLabel(e.bound) & ", or write a hand " &
              "{.verifyWhen: \"...\".} on this proc instead", node)
      of geExcessComponents:
        error("softlink: " & macroName & ": proc '" & nameStr &
              "': versionMacros gate synthesis for " & boundLabel(e.bound) &
              " '" & e.value & "' failed — it has " & $e.componentCount &
              " components but this block's versionMacros declares only " &
              $e.macroCount &
              (if e.macroCount == 1: " macro" else: " macros") &
              " (" & versionMacroNames.join(", ") & ") — there is no C " &
              "macro for the extra component(s); add another " &
              "versionMacros entry, use a coarser " & boundLabel(e.bound) &
              ", or write a hand {.verifyWhen: \"...\".} on this proc " &
              "instead", node)

proc checkVersionMacrosConsumed*(procs: seq[SoftlinkProc], versionMacrosPresent: bool,
                                  versionMacroNames: seq[string], macroName: string,
                                  node: NimNode) =
  ## Code-review finding CR1-12: a `versionMacros(...)` block-level directive
  ## that no `{.until.}`-carrying proc ends up consuming — either because the
  ## block declares no `until` pragma at all, or because every `until` proc
  ## already carries its own explicit `{.verifyWhen.}` (which always wins
  ## over synthesis, per `synthesizeVersionGates`'s doc comment) — used to be
  ## a silent no-op: the directive parses fine, `versionMacroNames` is never
  ## read again, and the author gets no signal that it did nothing.
  ##
  ## MUST run AFTER `synthesizeVersionGates` (both call sites, `dynlib` and
  ## `verifyProcs`) — it is that pass's successful synthesis that populates
  ## `p.synthesizedGateMacros`, the field this check reads to decide whether
  ## the directive was actually used by ANY proc in the block.
  ##
  ## Deliberately a PLAIN hint, never escalated under `-d:softlinkStrictVerify`
  ## — unlike the `{.noverify.}` hint and the drifted-but-required hint
  ## (`src/softlink.nim`), both genuine TRUST points where something is going
  ## unverified or a whole block can fail silently, an unused `versionMacros`
  ## directive is a lint on the SOURCE, not a gap in what gets verified:
  ## nothing is left unverified as a result, the directive is simply inert.
  ## Escalating a lint to a warning under an audit-mode define would conflate
  ## "something here is unverified" with "this line of code does nothing" —
  ## different severities, so this stays a hint at every verify tier.
  if not versionMacrosPresent:
    return
  for p in procs:
    if p.synthesizedGateMacros.len > 0:
      return
  hint("softlink: " & macroName & ": versionMacros(" &
       versionMacroNames.join(", ") & ") is declared but never used — no " &
       "{.until.} proc in this block was gated by a synthesized " &
       "{.verifyWhen.} from it (either no proc carries {.until.}, or every " &
       "{.until.} proc already has its own explicit {.verifyWhen.}, which " &
       "always wins over synthesis). Remove the directive, or check " &
       "whether the procs it was meant to gate still need it", node)

