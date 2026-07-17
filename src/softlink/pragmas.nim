## `softlink/pragmas` — RFC-0001's per-proc pragma parsing (calling
## convention, `header`, `optional`, `noverify`, `verifyWhen`, `since`,
## `prototype`) that sit alongside proc declarations in a `dynlib`/
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

