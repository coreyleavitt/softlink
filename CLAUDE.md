# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

softlink is a Nim library that provides a `dynlib` macro for type-safe, runtime-optional dynamic library bindings, plus a `dyntype` macro for compile-time struct layout verification against C headers. It bridges the gap between Nim's `{.importc, dynlib.}` (type-safe but crashes if library missing) and `std/dynlib` (runtime-optional but no type safety).

## Build & Test Commands

```bash
nimble test             # Run all tests (compiles and runs tests/test_softlink.nim)
nim c -r --path:src tests/test_softlink.nim  # Run tests directly
```

The nimble file requires Nim >= 2.0.0.

## Architecture

The entire library is a single file: `src/softlink.nim`. It exports two macros (`dynlib` and `dyntype`), one error type (`SoftlinkError`), and a `LoadResult` object variant for load diagnostics.

### How the `dynlib` macro works

Given input like `dynlib "libfoo.so(.2|)": proc bar(x: cint): cint {.cdecl, header: "foo.h".}`, the macro generates:

1. **A module-level `LibHandle` var** — stores the loaded library handle
2. **A module-level function pointer var per proc** — typed `proc(...) {.cdecl.}`, initially nil
3. **`loadFoo*(): LoadResult`** — calls `loadLibPattern`, resolves all symbols via `symAddr` + cast. Returns `lrOk` if all symbols resolve, `lrOkPartial` (with `missing: seq[string]`) if only optional symbols are missing, `lrLibNotFound` if the library is missing, or `lrSymbolNotFound` (with `symbol: string`) if a required symbol can't be resolved. Idempotent (returns the cached `LoadResult` immediately if already loaded).
4. **`unloadFoo*()`** — unloads library, nils all pointers. No-op if not loaded.
5. **`fooLoaded*(): bool`** — checks if handle is non-nil.
6. **Wrapper procs** — same signature as declared. Check function pointer for nil (raise `SoftlinkError` if so), then dispatch through the pointer.
7. **`xxxAvailable*(): bool`** — generated for each `{.optional.}` proc. Returns whether the function pointer was resolved.

The library name is derived from the pattern string: `"libmbedtls.so(.16|)"` becomes base name `Mbedtls`, producing `loadMbedtls`, `unloadMbedtls`, `mbedtlsLoaded`.

### Key design decisions

- **Required by default, optional per-symbol**: required symbols cause load failure if missing (all-or-nothing for required). Optional symbols (`{.optional.}` pragma) are silently skipped, with `xxxAvailable*(): bool` checks generated. `{.optional.}` is runtime-optional only — header verification still runs. `{.verifyWhen: "C_PP_EXPR".}` wraps a proc's verification in `#if (EXPR)` — verify on new-enough headers, skip on old ones ("verify whenever possible"; requires `header`). `{.noverify.}` skips the check entirely and lifts the `header` requirement — for symbols no header declares; each dynlib block emits a compile-time hint enumerating its noverify symbols (warning under `-d:softlinkStrictVerify`). `verifyWhen` + `noverify` together is a macro error. `verifyProcs` supports `verifyWhen` and rejects `noverify`/unknown pragmas.
- **One dynlib block per library per module**: a second block deriving the same ident base is rejected at macro-expansion time via a `when declared(softlinkHandleX)` guard with a clear merge-the-blocks error (#14) — previously it leaked an opaque `redefinition of 'softlinkHandleX'` from softlink.nim. The guard is scope-accurate and doesn't fire across modules (state vars are unexported). Negative compile test: `tests/tfail_duplicate_dynlib.nim`, driven by the nimble test task (greps for the error message).
- **Explicit calling convention required**: the macro requires `{.cdecl.}`, `{.stdcall.}`, etc. — no default. Supports `cdecl`, `stdcall`, `fastcall`, `syscall`, `noconv`.
- **Required `header` pragma**: every proc must specify `{.header: "foo.h".}` (or `{.header: "<foo.h>".}` for angle-bracket includes), unless marked `{.noverify.}` or `{.prototype: "...".}`. The macro emits call-based `_Static_assert` checks that verify each symbol's signature against the C header at compile time — const-tolerant, no `.so` needed, only the header files. Three-tier fallback: C++ `decltype`+`is_same`, GCC/Clang `__builtin_types_compatible_p`+`__typeof__`, MSVC `_Generic`+`__typeof__` pointer trick.
- **`{.prototype: "<C prototype>".}`** (RFC-0001 §3 A.1, slices A1+A2 landed): a vendored C declaration copied from upstream's header — string literal (triple-quoted/multi-line accepted), single non-variadic prototype, name must match the proc's C name. A shared tokenizer (`tokenizePrototype`/`analyzePrototype` in `src/softlink.nim`) extracts the identifier immediately before the first depth-0 `(`; a `(*` there means a function-pointer return type (name nested, unextractable) and is rejected with typedef guidance. Lifts the `header` requirement (like `noverify`, though the two are mutually exclusive — both select a declaration source); may coexist with `header` for cross-checking (both declarations are emitted; the C compiler cross-checks agreement). The prototype is emitted as a file-scope `extern` declaration in the verify TU (`extern "C" { ... }`-wrapped under the C++ backend), after the block's `#include`s, before the verify proc body (`emitPrototypeDecl`) — so a `prototype`-only (no `header`) proc is fully header-verified via the same call-based `_Static_assert` chain, with nothing left unverified. A `{.verifyWhen.}` on the same proc gates the emitted declaration too, not just its assert.
- **Pragma allowlist**: only calling conventions + `optional` + `noverify` + `verifyWhen` + `header` + `prototype` + `since` + `until` are accepted. Unsupported pragmas (e.g., `varargs`) produce compile-time errors. `until` (RFC-0002) declares the exclusive upper bound of a symbol's `[since, until)` signature-validity window: requires corpus-trackability (`header`; rejected with `noverify`/header-less `prototype`) and a `{.verifyWhen.}` gate — hand-written, or synthesized from a block-level `versionMacros("MACRO", ...)` directive (`src/softlink/gates.nim`). Declared bounds also drive runtime drift refusal at out-of-corpus and manifest-less probed versions. `versionMacros` also accepts an optional `header = "..."` named argument (any position, conventionally last; same quoted/angle-bracket convention as a proc's own `{.header.}`) — for libraries like Z3 whose main header does NOT transitively include the header defining its version macros (`z3.h` doesn't include `z3_version.h`), the named header joins the block's own verify-TU `#include` list (`softlink/verify.genVerifyBlock`) so the macros are in scope before the synthesized gate's `#if`/`#ifndef` guard evaluates; unneeded for umbrella-header libraries like mbedtls where the version macro is already pulled in transitively.
- **No thread safety guarantees**: `loadLib` is not thread-safe on all platforms.

### How the `dyntype` macro works

Given a `dyntype "foo.h":` block containing a type like `type Bar {.ctype: "bar_t".} = object` with field declarations, the macro:

1. **Passes through** the type definition (the Nim type is usable in code, no `{.importc.}`)
2. **Emits** `#include "foo.h"` via `/*INCLUDESECTION*/`
3. **Emits** `_Static_assert(sizeof(NimCName) == sizeof(bar_t), "...")` at file scope using emit array syntax to resolve Nim type names to their generated C names
4. Uses a **two-tier compiler fallback**: C++ `static_assert` / C11 `_Static_assert`

Key design decisions for `dyntype`:
- **`ctype` pragma required** per type — maps to the C struct name in the header
- **Header on the `dyntype` call**, not per-type
- **File-scope emit** required — wrapping in a `{.used.}` proc causes Nim's DCE to drop assertions entirely; `{.exportc.}` is used for `dynlib`'s function verification which needs proc scope for variable ordering
- **sizeof-only** — catches the most dangerous bug class (allocation size mismatch). Field-level `offsetof` is a potential future enhancement.

### Ground-truth harvest (RFC-0003)

`tools/harvest/harvester.nim` + `src/softlink/verify.nim` define a
harvested fact (`fkVerified`/`fkAbsent`/`fkMismatch`/`fkUnknown`) as ground
truth about the installed header alone, independent of any
`since`/`until`/`verifyWhen` gate or vendored `{.prototype.}` declaration
the binding carries for its own user-compile/runtime-load purposes: harvest
probe compiles unconditionally defeat all of that scaffolding
(`softlinkProbeGroundTruth` + `softlinkHarvestSession` booldefines in
`verify.nim`, legal only together; `effectiveVerifyWhen` is the single
derivation point every gate-wrap site reads). This is not a flag/mode —
there is no gate-respecting harvest semantic anywhere in the tree.
Parameter-only drift (return type held fixed) now classifies decisively as
`fkMismatch` instead of falling through to `fkUnknown`: probe compiles pin
`-Werror=incompatible-pointer-types`
(`-Werror=incompatible-function-pointer-types` added on the Clang CI leg),
and `classify` treats an isolated verify-probe failure (existence green,
verify red, no strict-unavailable needle) as decisive — guarded by a
retry-once plus infra-marker loud abort so a transient toolchain failure
(OOM, ICE) can never become a poisoned fact. Calibration's known-answer
quad (`calib_verified`/`calib_absent`/`calib_mismatched`/
`calib_param_drifted`) refuses the harvest (`CalibrationRefusedError`, exit
2) if the parameter-drift pin lacks teeth on the caller's toolchain — MSVC
refuses in every flag configuration this project tests; `/we4133` is not a
supported pin spelling. `HarvestMeta.harvesterVersion` (sourced from a
version-of-record const in `softlink/versions`, not the harvest CLI's own
independently-versioned nimble package) stamps every harvest;
`checkSince`/`checkUntil` prepend a re-harvest breadcrumb to a
contradiction message when the field is absent from an older manifest
(trigger = absence of the field alone, never a version comparison — a
manifest lacking it still attaches and behaves identically otherwise).
Non-pointer scalar parameter drift and variadic-ness changes remain an
honest, documented residual gap: a valid implicit C conversion converts
silently and is uncatchable without reversing the call-based assert's
const-tolerance (issue #11), which is not on the table.

## Compact Instructions
When compacting, preserve in the summary: the active RFC and its handoff-doc path, the current stage/round, slices done vs remaining, open forks awaiting me, and the exact resume command. After compacting, re-read the handoff doc and MEMORY.md before continuing.

## Testing

Tests bind against system libraries (libm, libc) and a custom test library (testlib) in Docker. See `tests/test_softlink.nim` for full coverage (37 tests covering load, unload, reload, idempotent caching, optional symbols, dangling pointer regression, compile-time validation, and struct layout verification).
