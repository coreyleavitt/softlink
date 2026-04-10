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

- **Required by default, optional per-symbol**: required symbols cause load failure if missing (all-or-nothing for required). Optional symbols (`{.optional.}` pragma) are silently skipped, with `xxxAvailable*(): bool` checks generated.
- **Explicit calling convention required**: the macro requires `{.cdecl.}`, `{.stdcall.}`, etc. — no default. Supports `cdecl`, `stdcall`, `fastcall`, `syscall`, `noconv`.
- **Required `header` pragma**: every proc must specify `{.header: "foo.h".}` (or `{.header: "<foo.h>".}` for angle-bracket includes). The macro emits call-based `_Static_assert` checks that verify each symbol's signature against the C header at compile time — const-tolerant, no `.so` needed, only the header files. Three-tier fallback: C++ `decltype`+`is_same`, GCC/Clang `__builtin_types_compatible_p`+`__typeof__`, MSVC `_Generic`+`__typeof__` pointer trick.
- **Pragma allowlist**: only calling conventions + `optional` + `header` are accepted. Unsupported pragmas (e.g., `varargs`) produce compile-time errors.
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

## Testing

Tests bind against system libraries (libm, libc) and a custom test library (testlib) in Docker. See `tests/test_softlink.nim` for full coverage (37 tests covering load, unload, reload, idempotent caching, optional symbols, dangling pointer regression, compile-time validation, and struct layout verification).
