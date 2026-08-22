## `softlink/procinfo` — the compile-time proc-descriptor record shared
## across the three extraction seams (code-review finding #13): pragma
## parsing + directive/manifest application (`softlink/pragmas`), header
## verification codegen (`softlink/verify`), and the `dynlib`/`verifyProcs`
## macros themselves (`src/softlink.nim`). Kept in its own tiny leaf module,
## rather than folded into either `pragmas` or `verify`, so neither of those
## two seams has to import the other just to see this one shared shape —
## both import `procinfo` instead, and `softlink.nim` imports all three.
##
## All fields are exported (`*`) — unlike the pre-extraction original, where
## every field but the type name itself was module-private (the whole
## record lived in `softlink.nim`, so nothing else needed cross-module
## access). `dynlib`'s body-collection loop and `verifyProcs`' `collectVProcs`
## (both still in `softlink.nim`) construct `SoftlinkProc` object literals
## directly, and `softlink/verify`'s `genVerifyBlock` reads every field —
## both require the fields to be public now that they live in a different
## module. This is an internal-visibility change only: `SoftlinkProc` itself
## is not re-exported from `softlink.nim` (it never was part of the public
## API — only `dynlib`/`verifyProcs`/`dyntype`, `SoftlinkError`, `LoadResult`,
## `CompatReport`, and friends are), so no new public surface is added.

type
  ProcPragmaMode* = enum
    ## Which caller is parsing pragmas/directives — `dynlib` and
    ## `verifyProcs` share the same token recognition but disagree on what
    ## `optional`/`noverify` mean (dynlib: runtime-optional escape hatches;
    ## verifyProcs: meaningless, since the block exists solely to verify)
    ## and on their diagnostic wording. New pragmas Stage A adds
    ## (`prototype`, etc.) get their rules defined once instead of drifting
    ## between two hand-rolled loops.
    ##
    ## Lives here rather than in `softlink/pragmas` (whose
    ## `parseProcPragmas` is this enum's original, and still primary,
    ## consumer) so that `softlink/directives`' `applyCompatManifest` —
    ## which also takes a `ProcPragmaMode` — can see it without importing
    ## `softlink/pragmas` (code-review finding R2-4): both of those modules
    ## import `procinfo` for it, and neither imports the other.
    ppmDynlib
    ppmVerifyProcs

  SoftlinkProc* = object
    name*: NimNode
    nameStr*: string
    ptrName*: NimNode
    formalParams*: NimNode
    callConv*: string
    headerFile*: string
    isOptional*: bool
    noVerify*: bool
    noVerifyReason*: string  ## RFC-0001 §3 A.2: {.noverify: "why".} justification; "" if none given
    noVerifyFromBlockDefault*: bool  ## RFC 0011 S0a item 6: true iff `noVerify`/
      ## `noVerifyReason` above came from a block-level `noverify: "reason"`
      ## default (`softlink/pragmas.applyNoVerifyDefault`) rather than the
      ## proc's OWN `{.noverify.}` pragma. False for every proc whose
      ## `noVerify` was set by `parseProcPragmas` itself (including a bare
      ## `{.noverify.}` with no reason) — the zero value is therefore
      ## correct for every pre-item-6 proc, unchanged. The sole consumer is
      ## the `dynlib` macro's unverified-symbols audit hint, which collapses
      ## every block-defaulted proc into ONE summary line instead of one
      ## line each, while a proc's own explicit `{.noverify.}` keeps its
      ## individual line exactly as before this slice.
    verifyWhen*: string  ## C preprocessor expr gating verification; "" = always
    prototype*: string   ## raw {.prototype: "...".} string; "" if absent
    sinceVersion*: string  ## RFC-0001 §B.5/§C.2: {.since: "x.y.z".} claim; "" if absent
    untilVersion*: string  ## RFC-0002 §4.1/§6, slice A1: {.until: "x.y.z".} claim; "" if absent
    synthesizedGateMacros*: seq[string]  ## RFC-0002 §5/§6, slice E2: the
      ## `versionMacros` PREFIX actually referenced by a SYNTHESIZED
      ## `verifyWhen` (post trailing-zero-strip; see `softlink/gates.
      ## GateResult.usedMacros`) — empty unless `softlink/pragmas.
      ## synthesizeVersionGates` synthesized this proc's gate. An explicit,
      ## hand-written `{.verifyWhen.}` NEVER populates this (the documented
      ## override — §5: "forgoes by-construction consistency... and the
      ## visibility guards"), so `softlink/verify.genVerifyBlock` uses this
      ## field, not `verifyWhen.len > 0`, to decide which procs get the
      ## `#ifndef`/`#error` macro-visibility guards.
    hasReturn*: bool
