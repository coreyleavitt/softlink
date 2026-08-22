## `softlink/verify` — the compile-time C header signature verification
## codegen shared by `dynlib` and `verifyProcs`: `genVerifyBlock` (the
## three-tier `_Static_assert`/`__builtin_types_compatible_p`/`_Generic`
## fallback chain) and RFC-0001 §4 B.2's probe-mode machinery
## (`-d:softlinkProbeOnly`/`-d:softlinkProbeExistence`) that gates which
## procs in a block get verification apparatus emitted at all. Extracted
## from `src/softlink.nim` (code-review finding #13): `genVerifyBlock` and
## its helpers take their inputs as explicit parameters
## (`seq[SoftlinkProc]`, a tag string, a bool) and read only module-level
## `{.strdefine.}`/`{.booldefine.}` consts — none of it closes over any
## `dynlib`/`verifyProcs` macro local.

import std/[macros, strutils, sets]
import ./procinfo

func toIncludeDirective*(header: string): string =
  ## Convert a header path to a C #include directive.
  ## Supports angle-bracket syntax: ``"<mbedtls/ssl.h>"`` → ``#include <mbedtls/ssl.h>``
  ## and quoted syntax: ``"mbedtls/ssl.h"`` → ``#include "mbedtls/ssl.h"``
  if header.len >= 2 and header[0] == '<' and header[^1] == '>':
    "#include " & header & "\n"
  else:
    "#include \"" & header & "\"\n"

func wrapGate(gate: string, body: string, label: string = "verifyWhen"): string =
  ## RFC-0003 §4.1: collapses a hand-inlined `#if (gate) ... #endif`
  ## open/close pair around `body` into a single call, so a partial future
  ## edit can never desync an opener from its `#endif` — the shape
  ## `emitPrototypeDecl` (just below) already used, correctly, before this
  ## helper existed. `gate == ""` (no gate, e.g. ground truth defeated it
  ## via `effectiveVerifyWhen`) returns `body` unchanged — byte-identical
  ## to the ungated emission. `label` distinguishes the vendored-prototype
  ## decl's own marker ("verifyWhen: prototype decl") from the generic
  ## "verifyWhen" marker every other wrap site uses; the closing `#endif`
  ## marker is always the plain "verifyWhen" text (matches the pre-existing
  ## asymmetry `softlink.nimble`'s grep-pinned anchors already encode).
  if gate.len == 0: body
  else:
    "#if (" & gate & ") /* softlink " & label & " */\n" & body &
      "#endif /* softlink verifyWhen */\n"

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
  let decl = "#if defined(__cplusplus)\nextern \"C\" {\n#endif\n" &
    "extern " & prototype & ";\n" &
    "#if defined(__cplusplus)\n}\n#endif\n"
  wrapGate(verifyWhen, decl, "verifyWhen: prototype decl")

func emitVersionMacroGuards(macros: openArray[string]): string =
  ## RFC-0002 §4.5/§5/§6, slice E2 — the ONE `verify.nim` touch §2 promises:
  ## a defensive `#ifndef NAME` / `#error "..."` / `#endif` guard per
  ## SYNTHESIZED-gate macro. In `#if`/`#elif`, an undefined identifier is
  ## silently replaced by `0` — no error, no warning by default (§4.5); a
  ## synthesized gate referencing a macro no included header actually
  ## defines would therefore silently misverify (or silently under-verify)
  ## instead of failing loud. Emitted UNCONDITIONALLY into the verify TU —
  ## same treatment `genVerifyBlock` already gives `#include` directives
  ## themselves (built from `procs`, never gated by `isSuppressed` — see the
  ## header-collection loop above/below this call site).
  ##
  ## Scope: SYNTHESIZED gates only — `SoftlinkProc.synthesizedGateMacros`
  ## is populated exclusively by `softlink/pragmas.synthesizeVersionGates`,
  ## which never touches a proc carrying an explicit, hand-written
  ## `{.verifyWhen.}` (§5's documented override "forgoes... the visibility
  ## guards"). A hand-written gate's macros are an unparsed opaque C
  ## expression string this module cannot safely extract identifiers from
  ## (§4.5: "for hand-written gates softlink cannot parse the predicate to
  ## extract identifiers; E3's docs carry the undefined-macro warning
  ## instead") — so only the synthesizer's OWN, precisely-known macro list
  ## ever reaches this function.
  result = ""
  for name in macros:
    result.add("#ifndef " & name & "\n")
    result.add("#error \"softlink: versionMacros identifier '" & name &
      "' is not defined by this block's included headers — a synthesized " &
      "{.until/since.} gate referenced it, but #if/#elif silently treats " &
      "an undefined macro as 0, which would misverify rather than fail " &
      "loud; make sure the header declaring '" & name &
      "' is included by this block (RFC-0002 §4.5)\"\n")
    result.add("#endif\n")

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

const softlinkProbeGroundTruth {.booldefine.} = false
  ## RFC-0003 §4.1 — the ground-truth harvest semantic. Under
  ## `-d:softlinkProbeGroundTruth`, probe-mode emission defeats EVERY
  ## compatibility gate a proc's verification apparatus carries — hand-
  ## written `{.verifyWhen.}` AND synthesized `{.since/until.}` gates alike
  ## (§4.2: distinguishing a hand version-gate from a hand feature-gate is
  ## not mechanically possible, and a feature-gated symbol's corpus story is
  ## a baseline-configuration concern, not a pragma gap) — via ONE
  ## derivation point, `effectiveVerifyWhen` below, not per-site checks.
  ## `{.prototype.}` declarations are affected too: their own `{.verifyWhen.}`
  ## wrap (`emitPrototypeDecl`) routes through the SAME derivation, and the
  ## PROBED symbol's own vendored decl is additionally suppressed outright
  ## in the verify sub-mode (§5.2 iv — see `isProbedTarget` below), because
  ## ground truth means "checked against the header alone."
  ##
  ## This is harvest-only machinery, never a supported build flag: see the
  ## misuse rule in `genVerifyBlock` below (requires
  ## `-d:softlinkHarvestSession`, else a macro error) and the four-define
  ## truth table above `genVerifyBlock`.

const softlinkHarvestSession {.booldefine.} = false
  ## RFC-0003 §4.1 — the misuse-guard's missing signal. The fast-path
  ## whole-module compile sets `softlinkProbeGroundTruth` with NO
  ## `softlinkProbeOnly` at all, which makes that legitimate configuration
  ## macro-indistinguishable from a stray hand-set `-d:softlinkProbeGroundTruth`
  ## — `softlinkProbeOnly`'s presence/absence can't be the discriminator.
  ## softlink's own harvester sets `-d:softlinkHarvestSession` on EVERY
  ## compile it issues (baseline, existence, verify, bisection group,
  ## fast-path whole-module, calibration), so its presence is the reliable
  ## "this compile came from softlink's own harvester" signal the misuse
  ## rule needs. Alone (groundTruth false) this define is legal but INERT —
  ## it changes no emission by itself; see the truth table above
  ## `genVerifyBlock`.

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

template effectiveVerifyWhen(p: SoftlinkProc): string =
  ## RFC-0003 §4.1's single derivation point: every gate-wrap site below
  ## reads a proc's EFFECTIVE `verifyWhen` through this template, never
  ## `p.verifyWhen` directly — under ground truth, every gate (hand-written
  ## AND synthesized alike) is defeated, uniformly, in one place. A future
  ## gate-wrapped emission site inherits ground-truth-defeat for free by
  ## using this template instead of inventing its own check.
  (if softlinkProbeGroundTruth: "" else: p.verifyWhen)

proc wrapGate(gate: string, bodyArr: NimNode): NimNode =
  ## NimNode-array counterpart of the `wrapGate` above, for the existence-
  ## probe and assert-chain wrap sites: their wrapped content interleaves
  ## string literals with real AST nodes (dummy call-argument idents, type
  ## nodes via `addTypeToEmit`) that can't be flattened into a single
  ## string the way `emitPrototypeDecl`'s can. Takes the ALREADY-BUILT
  ## `nnkBracket` array of tiered content (`bodyArr`, populated by ordinary
  ## imperative code at the call site — deliberately NOT a closure: an
  ## earlier draft captured the call site's per-proc locals
  ## (`dummyVars`/`emitArray`) in a `proc()` callback, and Nim's closure
  ## conversion hoists a captured `var` declared inside a `for` loop to a
  ## single shared environment slot whose OWN declaration/reset only runs
  ## once — the second and later loop iterations silently kept appending to
  ## the FIRST iteration's sequence instead of starting fresh, corrupting
  ## multi-proc blocks (hand-caught via `tests/tverify_gated_drift.nim`'s
  ## second block, RED evidence: `testlib_drifted`'s assert called with
  ## `testlib_add`'s two dummy vars ahead of its own). Splicing pre-built
  ## NimNode arrays has no captured mutable state, so this class of bug is
  ## structurally impossible here) and splices the gate's open/close marker
  ## text around its children into a NEW array — reproducing the EXACT
  ## open/close marker text these two sites already emitted before this
  ## helper existed (no leading/trailing-newline change — see
  ## `softlink.nimble`'s `poExistGatedGated` exact-substring pin, which
  ## depends on the open marker NOT ending in its own newline: the wrapped
  ## body supplies that separator itself). `gate == ""` returns `bodyArr`
  ## itself, unchanged — byte-identical to the ungated emission. One call
  ## now produces both the opener and its matching `#endif` — they can
  ## never desync because there's only one call site to edit.
  if gate.len == 0:
    return bodyArr
  result = newNimNode(nnkBracket)
  result.add(newStrLitNode("\n#if (" & gate & ") /* softlink verifyWhen */"))
  for child in bodyArr:
    result.add(child)
  result.add(newStrLitNode("#endif /* softlink verifyWhen */\n"))

# RFC-0003 §4.1 — four probe-mode defines and their legal/illegal
# combinations, reconstructable only from RFC-0001 §4 B.2 and RFC-0003 §4.1
# prose without this table:
#
# | softlinkProbeOnly | ProbeExistence | ProbeGroundTruth | HarvestSession | legal? | what happens |
# |---|---|---|---|---|---|
# | unset/"" | false | false | false | yes | ordinary user compile — every probe-mode check below is unreachable/false |
# | any | any | false | any | yes | RFC-0001 standard-path probing with gates evaluated normally (dev/test probing, or a pre-ground-truth-fix harvest compile) |
# | any | any | true | false | **NO — macro error** | ground truth defeats every gate/prototype/guard to measure header truth; only softlink's own harvester may set it (misuse rule below) |
# | unset/"" | false | true | true | yes | fast-path whole-module compile under ground truth (RFC-0003 §4.3) — no `softlinkProbeOnly` at all |
# | <name(s)> | false/true | true | true | yes | standard-path probe(s)/bisection group under ground truth (RFC-0003 §4.2, §5.2 iv) |
#
# `softlinkHarvestSession` alone (`softlinkProbeGroundTruth` false) is a
# legal but INERT state — it changes no emission by itself; it exists
# purely as the misuse guard's signal for the illegal row above. The four
# defines are NOT collapsible into one mode enum: `softlinkProbeGroundTruth`
# must be settable on the fast path's define-free whole-module compile,
# which carries no `softlinkProbeOnly` at all, so gate-defeat is a
# genuinely independent bit from probeOnly/existence.
proc genVerifyBlock*(allProcs: seq[SoftlinkProc], tag: string,
                     hasManifestAttached: bool = false,
                     versionMacrosHeader: string = ""): seq[NimNode] =
  ## Generate the compile-time C header signature verification nodes
  ## (include section + a file-local _Static_assert proc). Shared by
  ## `dynlib` and `verifyProcs`.
  ##
  ## `versionMacrosHeader` (RFC-0002 §5/§6 Z3 extension): the block's
  ## `versionMacros(...)` directive's `header = "..."` value, if any ("" —
  ## the zero value — means absent, matching `VersionMacrosDirective.
  ## headerName`'s own convention). `versionMacros`'s synthesized gate
  ## assumes one of THIS block's procs' `{.header.}`s transitively
  ## #includes whatever header defines the named macro(s) — true for
  ## mbedtls-style umbrella headers, false for Z3 (`z3.h` doesn't include
  ## `z3_version.h`). When non-empty, this header joins the block's own
  ## `#include` list below, UNCONDITIONALLY on presence — not gated on
  ## whether any proc's synthesized gate actually ended up consuming the
  ## directive (`checkVersionMacrosConsumed`'s unused-directive hint is a
  ## separate, orthogonal signal; coupling the two would make one silently
  ## depend on the other for no benefit — the extra #include is harmless
  ## even when unused).
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
      procs[0].cName & "."
    error(msg, allProcs[0].name)

  # RFC-0003 §4.1 misuse rule: `softlinkProbeGroundTruth` set without
  # `softlinkHarvestSession` is a loud macro-expansion-time error, never a
  # silent probe — the fast-path whole-module compile (ground truth set, no
  # `softlinkProbeOnly` at all) would otherwise be macro-indistinguishable
  # from a stray hand-set define, which is exactly why `softlinkHarvestSession`
  # exists as this rule's own signal (see its doc comment above).
  if softlinkProbeGroundTruth and not softlinkHarvestSession:
    let msg = "softlink: -d:softlinkProbeGroundTruth requires " &
      "-d:softlinkHarvestSession in block '" & tag & "' — this define " &
      "exists only for softlink's own harvester: it defeats every " &
      "since/until/verifyWhen gate and vendored {.prototype.} declaration " &
      "in this block so the harvester can measure header ground truth, " &
      "independent of the compatibility scaffolding ordinary compiles " &
      "rely on. If you are running 'softlink harvest', this is a " &
      "harvester bug, please file an issue. If you set " &
      "-d:softlinkProbeGroundTruth by hand, remove it — it is not a " &
      "supported build flag, and ordinary compiles need their gates " &
      "evaluated to work across library versions."
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

  # RFC-0001 §4 B.2, coverage fix (code-review finding F9): `probeOnlyList`
  # is never checked against this block's own C names — a typo'd or stale
  # `-d:softlinkProbeOnly` value silently suppresses EVERY proc in the
  # block (the trivially-compiling verify TU gives no signal that anything
  # is wrong). `-d:softlinkProbeOnly` is deliberately GLOBAL to the whole
  # compilation, though: a module may legitimately contain MULTIPLE
  # `dynlib`/`verifyProcs` blocks, and the harvester's single invocation
  # targets exactly one of them by name — every OTHER block in that same
  # module correctly matches nothing and correctly suppresses everything.
  # A hard ERROR here would break that entirely legitimate multi-block
  # case, so this is a WARNING, not an error (unconditionally — there is
  # no existing precedent in this file for escalating a *warning* to an
  # *error* under `-d:softlinkStrictVerify`; the only escalation precedent
  # here is hint-to-warning, e.g. the {.noverify.} enumeration below, which
  # is a different severity pair and does not apply). Existence mode
  # (`softlinkProbeExistence`) gets the exact same warning, not a harder
  # one, for the identical reason: its single-symbol target not matching
  # THIS block is just as often the legitimate "targets a different block"
  # case as it is a typo.
  if probeOnlyList.len > 0:
    var blockCNames: HashSet[string]
    # Code-review finding R2-3: built from `procs` (the verification-
    # ELIGIBLE subset — see its own `for p in allProcs: if not
    # p.noVerify and ...` filter above), NOT `allProcs`. A `{.noverify.}`
    # proc's cname is a real symbol in this block but has NO verification
    # to gate; if it were the sole match for `probeOnlyList` against
    # `allProcs`, the "no proc in this block" warning below would never
    # fire (the name IS in `allProcs`) even though every genuinely-
    # verifiable proc in the block is being silently, totally suppressed —
    # exactly the failure mode this warning exists to catch.
    for p in procs: blockCNames.incl(p.cName)
    var unmatched: seq[string]
    for name in probeOnlyList:
      if name notin blockCNames:
        unmatched.add(name)
    if unmatched.len > 0:
      let msg = "softlink: -d:softlinkProbeOnly=" & softlinkProbeOnly &
        " names " & unmatched.join(", ") &
        (if unmatched.len == 1: " that matches" else: " that match") &
        " no proc in this '" & tag & "' block — if you intended to " &
        "target THIS block, this is a typo or stale name and every " &
        "proc's verification here is being silently suppressed (fatal if " &
        "so); if you intended a DIFFERENT dynlib/verifyProcs block in the " &
        "same module, this is expected and can be ignored (RFC-0001 §4 B.2)."
      warning(msg, allProcs[0].name)

  template isSuppressed(p: SoftlinkProc): bool =
    ## RFC-0001 §4 B.2 (list support: slice B7): true when this proc's
    ## entire verification apparatus (call-based assert chain AND any
    ## {.prototype.} extern decl) must be omitted this compile — probing is
    ## active and this proc is neither the "-" sentinel's "everything"
    ## target nor a member of `probeOnlyList`. A singleton list reduces to
    ## exactly the pre-B7 `p.cName != softlinkProbeOnly` check (byte-
    ## identical behavior — see `parseProbeOnlyList`'s doc comment). RFC
    ## 0011 S0a item 3: keyed on `p.cName`, not `p.nameStr` — this define
    ## names a real C symbol (the harvester's own bisection target), not a
    ## Nim identifier.
    probeOnlyActive and (softlinkProbeOnly == "-" or p.cName notin probeOnlyList)

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
      p.cName == probeOnlyList[0]

  template isProbedTarget(p: SoftlinkProc): bool =
    ## RFC-0003 §5.2(iv): true when this proc is (one of) the probed
    ## symbol(s) THIS compile is targeting — i.e. its verification apparatus
    ## is NOT suppressed. Equivalent to `probeOnlyActive and not
    ## isSuppressed(p)`; factored out because ground truth's verify-sub-mode
    ## prototype-decl suppression needs exactly this predicate (broader than
    ## `isProbedExistence`, which additionally requires existence mode) —
    ## under ground truth, a header+prototype proc's verify TU must check
    ## the header ALONE, so the probed symbol's own vendored decl is
    ## suppressed regardless of whether existence or verify mode is active.
    probeOnlyActive and not isSuppressed(p)

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
    # RFC-0003 §7 A1: unique, tag-scoped start anchor for the NEW
    # byte-identical golden-snapshot check (`tests/tgolden_verify_apparatus.nim`
    # + `runGoldenVerifyApparatusCheck` in `softlink.nimble`) — a pure C
    # comment, zero functional effect, present unconditionally (like every
    # other line `includeCode` accumulates) so the check can extract exactly
    # this block's emitted include-section scaffolding via a plain
    # substring search over `slurpGenSources`'s output, with no dependence
    # on Nim's own codegen layout. Placed as the ABSOLUTE FIRST thing added
    # to `includeCode`, and the END anchor below as the ABSOLUTE LAST —
    # nothing is ever inserted BETWEEN two previously-adjacent pieces of
    # content, so no existing `expectAnchor`/`expectAdjacentPair` check
    # elsewhere in this suite is affected.
    var includeCode = "/* SOFTLINK_VERIFY_APPARATUS_INCLUDES_BEGIN:" & tag & " */\n"
    for p in procs:
      # `procs` now includes prototype-only entries (no {.header.}) per
      # RFC-0001 §3 A.1 slice A2 — the empty-headerFile guard here is load-
      # bearing, not defensive dead code: without it a prototype-only proc
      # would emit `#include ""`, a compile error.
      if p.headerFile != "" and p.headerFile notin headers:
        headers.incl(p.headerFile)
        includeCode.add(toIncludeDirective(p.headerFile))

    # RFC-0002 §5/§6 Z3 extension: `versionMacros(..., header = "...")`'s
    # named header, if any — joins the SAME `headers` set the loop just
    # above builds, so it gets the identical dedup treatment as any proc's
    # `{.header.}` (no double #include if it happens to equal one already
    # in the set; this loop has never invented dedup beyond that, so
    # neither does this). Added here, BEFORE the prototype-decl and
    # macro-visibility-guard emission below, so the macro(s) the guard
    # checks are guaranteed in scope by the time it runs.
    if versionMacrosHeader.len > 0 and versionMacrosHeader notin headers:
      headers.incl(versionMacrosHeader)
      includeCode.add(toIncludeDirective(versionMacrosHeader))

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
    # merely symmetric. RFC-0003 §5.2(iv): under ground truth, the probed
    # symbol's OWN decl is ALSO omitted in the (non-existence) verify
    # sub-mode — a stale-but-benign vendored decl at a corpus version must
    # never kill the TU for scaffolding-freshness reasons when §2's
    # definition demands `fkVerified` from the header alone; opportunistic
    # prototype↔header cross-checking remains a user-compile-only feature
    # (no `softlinkProbeGroundTruth`, no suppression here).
    for p in procs:
      if p.prototype.len > 0 and not isSuppressed(p) and
         not isProbedExistence(p) and
         not (softlinkProbeGroundTruth and isProbedTarget(p)):
        includeCode.add(emitPrototypeDecl(p.prototype, effectiveVerifyWhen(p)))

    # RFC-0002 §4.5/§5/§6, slice E2: the macro-visibility guards for every
    # SYNTHESIZED gate in this block — deduplicated (several procs can
    # reference the same versionMacros identifiers) and emitted ONCE each,
    # after the block's #includes (so a real definition from those headers
    # is visible by the time the guard checks) and before the verify-proc
    # body. Built from `procs` (like the header-include loop above), NOT
    # gated by `isSuppressed`/`isProbedExistence` — same rationale as
    # `#include`s themselves: the guard is a property of THIS compile's
    # header set, independent of which symbol probe mode happens to be
    # targeting this run.
    #
    # RFC-0003 §4.1: skipped ENTIRELY under ground truth — a probe TU
    # evaluates no gate there (`effectiveVerifyWhen` always returns ""), so
    # an undefined macro can't corrupt classification; user compiles (where
    # the gate IS evaluated) keep the guard's full authoring/corpus-
    # integrity role unchanged. A corpus version whose headers predate a
    # `versionMacros(header=...)` include still fails the baseline probe
    # (the #include itself is unconditional) — every symbol `fkUnknown` at
    # that version, the correct pre-existing behavior, unaffected by this
    # skip.
    if not softlinkProbeGroundTruth:
      block:
        var seenMacros: HashSet[string]
        var orderedMacros: seq[string]
        for p in procs:
          for m in p.synthesizedGateMacros:
            if m notin seenMacros:
              seenMacros.incl(m)
              orderedMacros.add(m)
        if orderedMacros.len > 0:
          includeCode.add(emitVersionMacroGuards(orderedMacros))

    # RFC-0003 §7 A1: matching end anchor — see the begin anchor's own doc
    # comment above. Added LAST, after macro-visibility guards, before the
    # type_traits trailer below (which is shared boilerplate, not part of
    # THIS block's own scaffolding, so it's deliberately left outside the
    # anchored span).
    includeCode.add("/* SOFTLINK_VERIFY_APPARATUS_INCLUDES_END:" & tag & " */\n")

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
    # RFC-0003 §7 A1: unique, tag-scoped start anchor for the golden-snapshot
    # check — see the matching includes-section anchor above for the full
    # rationale. Added as the ABSOLUTE FIRST statement of the verify proc's
    # body (before any per-proc content) and the END anchor below as the
    # ABSOLUTE LAST (after the per-proc loop) — this is a proc-BODY emit
    # statement, so it appears in-place in the generated C exactly where
    # written, in statement order (the same guarantee the surrounding code's
    # own "assertions appear after function pointer var declarations"
    # comment already relies on).
    verifyBody.add(newNimNode(nnkPragma).add(newNimNode(nnkExprColonExpr).add(
      ident("emit"),
      newStrLitNode("/* SOFTLINK_VERIFY_APPARATUS_BODY_BEGIN:" & tag & " */\n")
    )))
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
        var existBody = newNimNode(nnkBracket)
        existBody.add(newStrLitNode(
          "\n#if defined(__cplusplus)\n(void)sizeof(decltype(&" &
          p.cName & "));\n" &
          "#elif defined(__GNUC__)\n(void)sizeof(__typeof__(&" &
          p.cName & "));\n" &
          "#elif defined(_MSC_VER) && defined(__STDC_VERSION__) && __STDC_VERSION__ >= 202311L\n" &
          "(void)sizeof(__typeof__(&" & p.cName & "));\n"))
        when defined(softlinkStrictVerify):
          existBody.add(newStrLitNode(
            "#else\n#error \"softlink: existence probe unavailable here " &
            "(need C++, GCC/Clang, or MSVC /std:clatest); remove " &
            "-d:softlinkStrictVerify to skip\"\n#endif\n"))
        else:
          existBody.add(newStrLitNode(
            "#else\n/* softlink: existence probe skipped — unsupported " &
            "compiler/mode */\n#endif\n"))
        # RFC-0003 §4.1: `effectiveVerifyWhen`, not `p.verifyWhen` — ground
        # truth defeats this gate too, so the existence reference becomes
        # unconditional. `wrapGate` collapses the open/close pair into one
        # call (see its own doc comment for why this matters).
        let existArray = wrapGate(effectiveVerifyWhen(p), existBody)
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
      let errMsg = "softlink: " & p.cName & " signature mismatch vs " & declSource

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

      var assertBody = newNimNode(nnkBracket)

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

      # strip_ptr_const removes const from pointed-to types in return values
      assertBody.add(newStrLitNode(
        "\n#if defined(__cplusplus)\nstatic_assert(\n  std::is_same<\n" &
        "    typename softlink_strip_ptr_const<decltype("))
      buildCallArgs(assertBody, p.cName, dummyVars)
      assertBody.add(newStrLitNode(")>::type,\n    "))
      if p.hasReturn:
        addTypeToEmit(assertBody, p.formalParams[0])
      else:
        assertBody.add(newStrLitNode("void"))
      assertBody.add(newStrLitNode(
        ">::value,\n  \"" & errMsg & "\"\n);\n"))

      # --- GCC/Clang path: __builtin_types_compatible_p + __typeof__ ---
      # For pointer returns, dereference both sides so __builtin_types_compatible_p
      # strips top-level const (e.g., const unsigned char* → const unsigned char,
      # then ignoring qualifiers matches unsigned char). No linker dependency —
      # __typeof__ is purely compile-time.
      assertBody.add(newStrLitNode(
        "#elif defined(__GNUC__)\n_Static_assert(\n  __builtin_types_compatible_p(\n    __typeof__("))
      if retIsPointerLike:
        assertBody.add(newStrLitNode("*"))
      buildCallArgs(assertBody, p.cName, dummyVars)
      assertBody.add(newStrLitNode("),\n    "))
      if p.hasReturn:
        if retIsPointerLike:
          assertBody.add(newStrLitNode("__typeof__(*("))
          addTypeToEmit(assertBody, p.formalParams[0])
          assertBody.add(newStrLitNode(")0)"))
        else:
          addTypeToEmit(assertBody, p.formalParams[0])
      else:
        assertBody.add(newStrLitNode("void"))
      assertBody.add(newStrLitNode(
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
      assertBody.add(newStrLitNode(
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
        assertBody.add(newStrLitNode(
          "_Static_assert(\n  _Generic(*(__typeof__("))
        buildCallArgs(assertBody, p.cName, dummyVars)
        assertBody.add(newStrLitNode("))0,\n    __typeof__(*("))
        addTypeToEmit(assertBody, p.formalParams[0])
        assertBody.add(newStrLitNode(
          ")0): 1, default: 0),\n  \"" & errMsg & "\"\n);\n"))
      else:
        # Non-pointer: call + _Generic __typeof__ pointer trick
        buildCallArgs(assertBody, p.cName, dummyVars)
        assertBody.add(newStrLitNode(";\n_Static_assert(\n  _Generic((__typeof__("))
        buildCallArgs(assertBody, p.cName, dummyVars)
        assertBody.add(newStrLitNode(")*)0,\n    "))
        if p.hasReturn:
          addTypeToEmit(assertBody, p.formalParams[0])
        else:
          assertBody.add(newStrLitNode("void"))
        assertBody.add(newStrLitNode(
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
        assertBody.add(newStrLitNode(
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
        assertBody.add(newStrLitNode(fallbackText))

      # RFC-0003 §4.1: `effectiveVerifyWhen`, not `p.verifyWhen` — ground
      # truth defeats this gate too, so the entire assert chain (all three
      # compiler tiers AND the strict-mode fallback) becomes unconditional.
      # `wrapGate` collapses what used to be two separate hand-inlined
      # `if p.verifyWhen.len > 0` open/close checks into one call.
      let emitArray = wrapGate(effectiveVerifyWhen(p), assertBody)

      verifyBody.add(newNimNode(nnkPragma).add(
        newNimNode(nnkExprColonExpr).add(
          ident("emit"),
          emitArray
        )
      ))

    # RFC-0003 §7 A1: matching end anchor for the verify-proc body span —
    # see the begin anchor above.
    verifyBody.add(newNimNode(nnkPragma).add(newNimNode(nnkExprColonExpr).add(
      ident("emit"),
      newStrLitNode("/* SOFTLINK_VERIFY_APPARATUS_BODY_END:" & tag & " */\n")
    )))

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
