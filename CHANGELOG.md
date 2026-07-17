# Changelog

All notable changes to softlink are documented here.

## [Unreleased]

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
