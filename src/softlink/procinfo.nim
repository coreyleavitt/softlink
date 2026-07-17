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
    verifyWhen*: string  ## C preprocessor expr gating verification; "" = always
    prototype*: string   ## raw {.prototype: "...".} string; "" if absent
    sinceVersion*: string  ## RFC-0001 §B.5/§C.2: {.since: "x.y.z".} claim; "" if absent
    hasReturn*: bool
