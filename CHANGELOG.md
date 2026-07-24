# Changelog

All notable changes to softlink are documented here.

## [Unreleased]

### Fixed

**Ground-truth harvest semantics (RFC-0003).** The harvester previously
measured "does the binding compile at version v", not "is the declared C
signature valid against v's headers" — two questions RFC-0002's gates
deliberately decoupled, but only the second is what every manifest consumer
(`checkSince`, `checkUntil`, `classifyAbsence`, runtime drift refusal)
actually needs. Two independent gaps, both fixed:

- **Gap A — gate-masking.** A probe translation unit carried the same
  `#if (verifyWhen)` wraps as a user compile; at a version where the gate
  evaluated false, the verification apparatus vanished under the
  preprocessor, the probe compiled trivially, and the harvester recorded
  `verified` at exactly the version the gate exists to protect against.
  `--fast-path`'s whole-module stamp compounded this (one clean compile
  stamped *every* symbol `verified`), and additionally masked removals
  whose TU-presence a vendored `{.prototype.}` declaration propped up.
  Fixed: harvest probe compiles now unconditionally defeat every
  `since`/`until`/`verifyWhen` gate and every vendored prototype
  declaration, on both the standard and fast paths (including
  bisection-group compiles); a `header`+`prototype` proc is excluded from
  the fast path's free "everyone verified" stamp, since a clean compile
  carries no existence evidence for it.
- **Gap B — parameter-only drift was unclassifiable.** The verify assert is
  call-based and const-tolerant by design (#11), so it audits only the
  return type; a parameter-only drift (e.g. `int*` -> `bool*`, same name
  and return type) surfaced solely as the C compiler's own diagnostic — a
  hard error on GCC 14+ (before softlink's own assert ever ran, so
  classification fell through to `unknown`) or a mere warning on permissive
  toolchains (assert passed, silently `verified`). Fixed: probe compiles
  now pin `-Werror=incompatible-pointer-types`
  (`-Werror=incompatible-function-pointer-types` added on the Clang CI
  leg), and an isolated verify-probe failure with no other explanation now
  classifies decisively as `mismatch` instead of falling through to
  `unknown` — guarded by a retry-once (a transient failure must reproduce
  deterministically before it's recorded) and a loud abort on recognized
  infrastructure-failure output (an OOM-killed compiler or an ICE must
  never become a poisoned fact).

### Added

- Calibration preflight gains a fourth known-answer symbol (parameter-only
  pointer drift, expected `mismatch`) alongside the existing
  verified/absent/mismatch trio, so a toolchain whose diagnostics pin is
  absent, stripped, or ineffective now refuses to harvest at all
  (`CalibrationRefusedError`, exit code 2) instead of silently reverting to
  the pre-fix behavior. MSVC now refuses in every flag configuration this
  project tests (previously only the default mode was known to refuse) —
  `/we4133` is not accepted as a pin spelling, and calibration is what
  catches the resulting gap rather than a manifest silently misclassifying.
- `harvest.harvesterVersion` (manifest schema, optional field, schema
  number unchanged at 1): the softlink package version that performed the
  harvest, sourced from a new version-of-record const in `softlink/versions`
  (not the harvest CLI's own independently-versioned nimble package).
  `checkSince`/`checkUntil` prepend a short re-harvest note to a
  contradiction message when the field is absent — a manifest committed
  before this field existed embodies Gap A's/Gap B's corrupted facts and is
  byte-indistinguishable from a fixed one, so the note is triggered by
  absence of the field alone, never by a value comparison. A manifest
  lacking the field otherwise attaches and behaves exactly as before.
- Harvest README: a new "What a harvested fact means" section documenting
  the ground-truth semantic, why gates/prototypes are defeated, the
  feature-gate corpus-baseline note, the honest non-pointer-scalar-drift
  residual gap, the hand-edit-the-manifest anti-pattern, and the MSVC
  `/we4133` situation.

### Changed

- `checkUntil` rule (b′) — an `unknown` fact at or above a declared `until`
  is itself a hard error — now fires less often: the case it exists to
  catch, a real signature drift landing on `unknown` instead of `mismatch`,
  is largely closed by the Gap B fix above, so that class of drift is now
  caught decisively by rule (a)/(c) instead. `checkSince`'s symmetric
  fkUnknown-decisiveness rule benefits identically.

### Notes

- **Migration — re-harvest before relying on the fix.** Re-run
  `softlink_harvest` for any manifest whose binding has gated
  (`since`/`until`/`verifyWhen`) or `prototype`+`header` symbols. An
  un-re-harvested manifest continues to attach and behave exactly as
  before — nothing breaks by deferring the re-harvest — but nothing gets
  corrected either, and hand-editing the committed JSON instead of
  re-harvesting is an anti-pattern (see the harvest README): it breaks
  reproducibility against the next scheduled harvest.
- **Re-harvesting may surface new drift refusals — this is correction, not
  regression.** A symbol whose true drift was previously masked (`verified`
  under Gap A) or unclassifiable (`unknown` under Gap B) may now record a
  decisive `mismatch`/`absent` at a version your corpus already covers. A
  build that previously compiled clean under `checkUntil`, or a runtime
  load that previously dispatched a stale pointer without complaint, may
  now refuse. That is the ground truth the harvester should have reported
  all along, surfacing now rather than silently corrupting a manifest.

## [0.10.0] - 2026-07-22

### Added

- `versionMacros(...)` now accepts an optional `header = "..."` named
  argument (e.g. `versionMacros("Z3_MAJOR_VERSION", "Z3_MINOR_VERSION",
  header = "z3_version.h")`), same quoted/angle-bracket convention as a
  proc's own `{.header.}`. `versionMacros`'s synthesized gate assumes some
  proc's `{.header.}` transitively `#include`s whatever header actually
  defines the named macros — true for mbedtls-style umbrella headers, but
  false for Z3: `z3.h` does not include `z3_version.h`, so the synthesized
  gate's `#ifndef`/`#error` visibility guard fired with no in-directive fix
  (previously requiring a hand-rolled bridge header + an extra `-I` flag).
  `header = "..."` names the header that actually defines the macros;
  softlink adds it to the block's own verify-TU `#include` list, alongside
  the block's procs' own headers, guaranteeing the macros are in scope
  before the synthesized `#if` (and the `#ifndef`/`#error` guard) evaluate.
  Rejects an unsupported named argument (only `header` is accepted), a
  non-string-literal or empty `header` value, and a duplicate `header = ...`
  within one call. Backward compatible: omitting `header = ...` reproduces
  v0.9.0 behavior byte-for-byte.

## [0.9.0] - 2026-07-22

### Added

**Drifted-signature support (RFC-0002).**
- `{.until: "x.y.z".}` pragma: the mirror of `{.since.}` — declares the
  version **above which** a symbol's bound C signature is no longer correct,
  i.e. a signature valid for the half-open interval `[since, until)`.
  `until`-only ("valid since forever, drifts later") is first-class; `since`
  and `until` together bound a window. `since >= until` is a compile-time
  error (empty interval). `until` requires the proc to be **corpus-trackable**
  (a `header`, not `noverify`, not a header-less `prototype`) — a symbol with
  no compile-time version signal cannot carry a falsifiable `until`, so
  `until` + `noverify` and `until` + header-less `prototype` are compile-time
  errors. `until` **requires** a `{.verifyWhen.}` gate (unconditional
  — a bounded declaration verified against an ungated header would silently
  assert the wrong signature once the header moves past the bound) —
  hand-written on the proc, or synthesized via the `versionMacros(...)`
  directive below; a bounded proc with neither is a clear macro error.
  An `{.until.}` on a **required** (non-
  `optional`) proc emits a compile-time hint — a drifted required symbol
  refuses the *entire* load above `until`, which is usually not intended;
  escalates to a warning under `-d:softlinkStrictVerify`. Supported in both
  `dynlib` and `verifyProcs`.
- `compatManifest` harvester cross-check (`checkUntil`) validates a declared
  `until` against the harvested corpus: rejects a bound that over-claims
  (corpus shows drift inside the declared-valid window, or a re-verified
  signature at or above `until` — softlink cannot express drift-then-revert)
  and rejects a bound with no positive evidence (no `fkVerified` fact below
  it in the corpus). A bound beyond the corpus's max harvested version passes
  vacuously (harmless — declared-bound refusal, below, does not depend on
  corpus confirmation). **Security fix (Finding R2-A, High):** at or above a
  declared `until`, an unclassified (`unknown`) corpus fact now ALSO rejects
  the bound, with its own message — previously the check only looked for a
  re-verified (`fkVerified`) fact there, so a corpus version the harvester
  couldn't classify passed silently even though it gives no evidence the
  declared-invalid window actually holds; the runtime attested-path exemption
  for manifest-present bounded symbols relies on this check having decided
  every in-window corpus version one way or the other. `checkSince` gets the
  symmetric fix below `since`. Manifest schema is **unchanged, stays version
  1** — `checkUntil`/`checkSince` consume the existing verified/absent/
  mismatch/unknown facts, no new field.
- `versionMacros("FOO_MAJOR_VERSION", ...)` block directive (`dynlib` and
  `verifyProcs`; at most one per block, any position): declares the
  library's version-macro spelling once, most significant first. softlink
  then **synthesizes** the required `{.verifyWhen.}` gate for every
  `until`-bounded proc directly from its declared bounds — the full nested
  lexicographic comparison with trailing zero components stripped
  (`until: "4.16.0"` over three macros becomes
  `(A < 4) || (A == 4 && B < 16)`), so the gate's threshold is correct by
  construction; a hand-written split-macro gate can silently go wrong at a
  major-version rollover, and softlink cannot check a hand gate's value
  against `until`. An explicit `{.verifyWhen.}` on the proc overrides
  synthesis verbatim (feature-macro and packed-single-macro gating stay
  hand-written by design). Synthesized gates additionally get per-macro
  `#ifndef`/`#error` visibility guards in the verify TU (in `#if`, an
  undefined macro silently evaluates to `0` — fail loud instead of
  misverifying). Bounds with alphabetic runs, or with more EFFECTIVE
  components (after trailing zeros are stripped) than the declared macro
  list, are compile-time errors; shorter bounds need no padding, since the
  predicate only ever compares a macro-list prefix.
- Probe-dump JSON (`-d:softlinkDumpProbes`) gains a `"until"` key per proc,
  alongside the existing `"since"` — descriptive metadata the harvester
  carries but does not (yet) act on beyond the cross-check above.
- **Declared-bound runtime refusal**: `loadFoo()` now refuses a symbol whose
  probed runtime version falls outside its declared `[since, until)` at the
  sites the manifest's own drift facts can't reach — an out-of-corpus probe
  with a manifest attached, a probe with no manifest attached at all, and
  (code-review finding CR1-1) an **attested, in-corpus probe for a bounded
  symbol the attached manifest doesn't record at all** — `checkUntil`/
  `checkSince` have nothing to cross-check for such a symbol, so it is not
  covered by the "harvester already confirmed it" reasoning that otherwise
  makes an attested-path re-check redundant. A bounded symbol the manifest
  *does* record is unaffected: attested, in-corpus probes for it are keyed
  on the manifest's own drift facts exactly as before. Optional symbols are
  re-nilled with `mrDriftRefused`; required symbols unwind the whole load,
  mirroring existing attested-drift behavior. `CompatReport` carries the
  refusal, and the wrapper's drift-story error message names the declared
  bound. The not-in-manifest hint (RFC-0001 Check 8) now escalates to a
  warning under `-d:softlinkStrictVerify`, matching the codebase's other
  trust-point hints. See **Changed** below for the policy implication.

### Changed

- **Policy narrowing (RFC-0002 §4.4, "F1" — approved by maintainer
  2026-07-18): a load that previously succeeded out-of-corpus for a symbol
  carrying a declared `until`/`since` bound may now be refused.** RFC-0001
  deliberately did not block on harvest facts alone for versions the
  manifest can't decide; this narrows that policy only where the *binding's
  author* has explicitly declared the signature invalid outside a range (and,
  when a manifest is attached, the harvester has confirmed the declaration).
  Symbols without `since`/`until` are completely unaffected. Two escape
  hatches, same as existing drift refusal: build-wide
  `-d:softlinkNoDriftRefusal`, or per-block `compatManifest(..., refuse =
  false)` when a manifest is attached. A manifest-less block has no per-block
  hatch — the author *is* the declarer there, so the author-side escape is
  simply not declaring `until`.
- **`CompatReport` shape changes — additive, but touches every field a
  serializing consumer enumerates:**
  - `missingReasons`'s element type grows a third field:
    `seq[tuple[symbol: string, reason: MissingReason, interval:
    VersionInterval]]` (previously `seq[tuple[symbol, reason: string]]` pre-
    0.8.0, then `seq[tuple[symbol: string, reason: MissingReason]]` in
    0.8.0). Any code pattern-matching or destructuring the tuple by position
    or arity needs updating. This shape is now also available under the name
    `MissingReasonEntry*` (`missingReasons*: seq[MissingReasonEntry]`) — a
    named alias for the same structural tuple, added purely so the library's
    own codegen has one declaration to reference; since Nim tuples are
    structural, existing code written against the anonymous tuple keeps
    compiling unchanged.
  - New field `probeNotComparable*: bool` — `false` in every existing report
    shape; `true` only when a probed version string exactly ties a declared
    bound with a trailing pre-release-style suffix (e.g. `"4.16.0-rc1"` vs.
    `until: "4.16.0"`) or is unparseable, in which case declared-bound
    refusal declines to decide and the symbol loads normally
    (report-don't-block).
- The `versionProbe` drift-call compile error now explains that this check is deliberately **not** lifted by `refuse = false` / `-d:softlinkNoDriftRefusal`: those relax runtime refusal of drifted symbols in your own code, but the probe runs first — to determine the version the drift machinery is keyed on — so a probe resting on a symbol of uncertain signature could misreport that version before any refusal policy applies. Its soundness stays unconditional; the message now says so and points you at reading the version through a drift-free symbol (code review #10).

### Notes

- **Migration**: existing bindings that hand-roll drift detection with a bare
  `header` + `verifyWhen` (no `since`/`until`) keep working unchanged —
  nothing above alters their behavior. Adopting `since`/`until` is optional;
  it is recommended once a `compatManifest` is attached to the block, since
  that's what turns on the harvester cross-check and gets you declared-bound
  refusal essentially for free.

## [0.8.0] - 2026-07-17

RFC-0001 **Verified Version Compat Set** — softlink learns to answer "will
this build work against the library actually installed here?" at both compile
time and run time, across a *set* of supported upstream versions rather than a
single pinned header. Three new capability areas, all opt-in and additive.

### Added

**Prototype-based verification (no header needed).**
- `{.prototype: "<C prototype>".}` pragma: verify a proc against a **vendored C
  declaration** copied from upstream, instead of (or in addition to) a
  `{.header.}`. A single non-variadic prototype whose name matches the proc's C
  name is emitted into the verify translation unit and checked by the same
  three-tier `_Static_assert` chain, so a `prototype`-only proc is fully
  header-verified with nothing left unverified. Lifts the `header` requirement
  (mutually exclusive with `{.noverify.}`); may coexist with `header` so the C
  compiler cross-checks the two declarations agree. `{.verifyWhen.}` gates the
  emitted declaration too. Supported in both `dynlib` and `verifyProcs`.
- Headerless-prototype hint: when a `prototype` has no `header` and uses
  identifiers outside a builtin-C-type allowlist, softlink emits a hint (a
  warning under `-d:softlinkStrictVerify`) that `header:` may be needed — so a
  dropped `{.header.}` surfaces as a softlink diagnostic first, a raw C error
  second.
- `{.noverify: "justification".}`: the justification string is now read and
  surfaced (previously discarded), keeping deliberate trust points auditable.

**Compat manifests + the `softlink_harvest` tool.**
- `softlink_harvest` CLI: harvests a corpus of upstream header versions, probes
  each declared symbol per version, classifies it (verified / absent /
  signature-drift), compresses the results into version intervals, and emits a
  `<lib>.compat.json` manifest. A drift alarm fails CI when a symbol's signature
  changes within the binding's claimed support range. Ships with a B.6
  manifest-lifecycle CI **template** (`tools/harvest/ci-template.yaml`) that
  fails the moment a committed manifest no longer matches a fresh harvest.
- `compatManifest "<lib>.compat.json"` block directive: consumes a harvested
  manifest at **compile time** and embeds its facts as interval constants
  (`softlinkCompatFacts<Base>`), with a whole-module fast path and comma-list
  bisection for large symbol sets.
- Compile-time probe surfaces for the harvester: `-d:softlinkDumpProbes=<abs
  dir>` dumps per-baseName probe facts as JSON; `-d:softlinkProbeOnly=<name>`
  and `-d:softlinkProbeExistence` gate single-symbol probe builds.
- `{.since: "x.y.z".}` pragma: declares a symbol's lower-bound version; the
  fourth verification axis (alongside signature, presence, and layout), checked
  for contradiction against the manifest.
- `softlink/versions` module: a public version comparator and pinned fact types.

**Runtime compatibility surfaces.**
- `versionProbe` block directive: declares how to read the loaded library's
  version at run time.
- Generated `fooCompat(): CompatReport` per `dynlib` block: reports, against the
  probed runtime version, which symbols are verified vs missing (with reasons),
  partitioning absence into *expected* (below `since` / outside a manifest
  interval) vs *anomalous*.
- **Drift refusal**: when the probed runtime version places a symbol outside its
  verified compat interval, `loadFoo()` refuses rather than silently binding a
  signature-drifted symbol — for both optional and required symbols, with
  documented escape hatches (`-d:softlinkNoDriftRefusal`) and a compile-time
  scan that rejects a `versionProbe` body that itself calls a drift-flagged
  symbol.

### Changed

- `CompatReport`'s per-symbol absence field is named `missingReasons`
  (`seq[tuple[symbol, reason: string]]`) to avoid colliding with
  `LoadResult.missing` (`seq[string]`) when a caller holds both. `LoadResult` is
  unchanged.
- The `Attestation` enum distinguishes `atProbeNotRun` (transient — pre-load,
  post-unload, or after a Phase-1 load failure) from `atNoProbe` (permanent — the
  block declares no `versionProbe`), so a `fooCompat()` caller can tell "not
  probed yet" from "unprobeable".

### Fixed

- (RFC-0001 code review, 5 rounds) A batch of correctness, safety, and
  fail-loud hardening across the new manifest/harvest/compat pipeline: version
  strings that aliased under comparison could corrupt compressed manifest facts;
  wrong-typed interval bounds silently defaulted instead of failing loud;
  UFCS/parenthesized/dotted callees bypassed the probe-body drift scan;
  `verifyProcs` now validates `{.optional.}`/`{.noverify.}` rejection; several
  vacuous or non-recursive test-harness checks were made real.

### Notes

- The `softlink_harvest` tool requires **Nim >= 2.2.8** (a Nim 2.2.0 ORC
  cyclic-collector crash in its bounded-subprocess machinery); the `softlink`
  library itself still requires only **Nim >= 2.0.0**. CI and the harvest CI
  template pin the project's maintained `ghcr.io/coreyleavitt/nim` image.

## [0.7.0] - 2026-07-14

### Added
- `{.verifyWhen: "C_PP_EXPR".}` pragma: per-proc **conditional** header verification. The `_Static_assert` chain (all three compiler tiers and the strict-mode fallback) is wrapped in `#if (EXPR) ... #endif`, so systems whose headers are new enough verify in full while older installs compile cleanly — "verify whenever possible". Gate on the library's version macro (e.g. `{.verifyWhen: "MBEDTLS_VERSION_NUMBER >= 0x03060000".}`). Supported in both `dynlib` and `verifyProcs`; requires `header`; combining with `{.noverify.}` is a compile-time error. This supersedes blanket `{.noverify.}` for version-gated symbols — `noverify` remains for symbols no header declares at any version.
- Unverified-symbol visibility: a `dynlib` block containing `{.noverify.}` procs now emits a compile-time hint enumerating them (`softlink: dynlib "x": 2 symbols not header-verified ...`), upgraded to a warning under `-d:softlinkStrictVerify`, keeping trust points auditable.

### Fixed
- `verifyProcs` now validates pragmas like `dynlib` does: unknown pragmas (e.g. `varargs`) and the meaningless `{.noverify.}` are compile-time errors instead of being silently ignored.

## [0.6.0] - 2026-07-14

### Added
- `{.noverify.}` pragma (#14, Defect B): skips compile-time header verification for a single proc and lifts its `header` requirement. `{.optional.}` alone is runtime-optional only — the verify `_Static_assert` still ran, so an optional symbol absent from the installed headers was an implicit-declaration error. `{.optional, noverify.}` now binds symbols newer than the installed headers.

### Fixed
- `#14` (Defect A): two `dynlib` blocks deriving the same identifier base in one scope (e.g. `dynlib "m"` twice, or `"libfoo.so"` + `"foo"`) produced an opaque `redefinition of 'softlinkHandleM'` error pointing into softlink.nim. The macro now emits a `when declared()` guard that rejects the duplicate at the call site with a clear error directing you to merge the blocks (using `{.optional.}`/`{.noverify.}` for version-gated symbols).

## [0.5.0] - 2026-07-09

### Added
- `dynlib` now accepts a **bare logical library name** (e.g. `dynlib "z3":`) and derives the per-OS `loadLibPattern` candidates automatically — Linux `libz3.so(|.7|…)`, macOS `libz3(|.7|…).dylib`, Windows `(libz3|z3).dll`. Explicit patterns (any containing `.`, `(`, `/`, or `\`) still pass through verbatim as the escape hatch. Adds pure, per-OS-testable `deriveLibPattern`, `isLogicalName`, and the `LibOs` enum.
- `verifyProcs` macro: standalone compile-time C header signature verification (no loading, no wrappers, no runtime footprint) for statically-linked `{.importc.}` bindings
- `dyntype` macro for compile-time struct layout verification against C headers via `_Static_assert(sizeof)`
- `ctype` pragma for mapping Nim types to C struct names in `dyntype` blocks
- `lrLibNotFound` test coverage

### Fixed
- `#11`: const-qualified pointer returns (e.g. C `const char *` bound as `cstring`) are no longer rejected as signature mismatches — verification dereferences both sides so top-level qualifiers are ignored
- `#12`: cpp backend rejected `extern "C" static` on the verify proc — it now uses `inline` under `--backend:cpp` (ODR-relaxed, `extern "C"`-compatible)
- Header verification (`dynlib`) was silently not emitted due to Nim dead code elimination — switched from `{.used.}` to `{.exportc, codegenDecl: "static ...".}` to force emission while keeping symbols file-local
- Preprocessor directives in verify proc needed `\n` prefix to start at line boundaries in generated C

### Notes
- Bare-name resolution covers bare and single-component major sonames; multi-component runtime-only sonames (e.g. openSUSE `libz3.so.4.15`) should be pinned with the explicit-pattern escape hatch.

## [0.2.1] - 2026-04-05

### Fixed
- Cross-platform CI fixes for macOS (Clang) and Windows (MinGW + MSVC)
- MSVC `testlib.dll` symbol export via `__declspec(dllexport)`
- Library path resolution on macOS/Windows (bare names + env vars instead of `./tests/` prefix)

## [0.2.0] - 2026-04-05

### Added
- Compile-time header verification via `_Static_assert` + `_Generic` + `__typeof__` (three-tier fallback: C++/C23/C11)
- Required `header` pragma on all procs — verifies function signatures against C headers at compile time
- Custom test library (`testlib.h`/`testlib.c`) for controlled cross-platform testing
- Cross-platform CI: Linux (GCC), macOS (Clang), Windows (MinGW), Windows (MSVC)
- JS backend guard with clear error message
- Release workflow with semantic versioning

### Changed
- `LoadResult` replaces `bool` return from `loadXxx()` — now returns `lrOk`, `lrOkPartial`, `lrLibNotFound`, or `lrSymbolNotFound`
- Three-phase resolve-then-assign architecture eliminates dangling pointer class
- Cached `LoadResult` for idempotent load consistency

## [0.1.0] - 2026-04-04

### Added
- Initial release: `dynlib` macro for type-safe, runtime-optional dynamic library bindings
- `SoftlinkError` with `symbol` and `library` fields
- Optional symbols with `{.optional.}` pragma and `xxxAvailable*()` checks
- Pragma validation (calling convention required, allowlist enforced)
- Duplicate proc name detection
