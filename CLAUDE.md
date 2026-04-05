# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

softlink is a Nim library that provides a `dynlib` macro for type-safe, runtime-optional dynamic library bindings. It bridges the gap between Nim's `{.importc, dynlib.}` (type-safe but crashes if library missing) and `std/dynlib` (runtime-optional but no type safety).

## Build & Test Commands

```bash
nimble build            # Build the library
nimble test             # Run all tests (compiles and runs tests/test_softlink.nim)
nim c -r tests/test_softlink.nim  # Run tests directly
```

The nimble file requires Nim >= 2.0.0.

## Architecture

The entire library is a single file: `src/softlink.nim`. It exports one macro (`dynlib`), one error type (`SoftlinkError`), and a `LoadResult` object variant for load diagnostics.

### How the `dynlib` macro works

Given input like `dynlib "libfoo.so(.2|)": proc bar(x: cint): cint {.cdecl.}`, the macro generates:

1. **A module-level `LibHandle` var** — stores the loaded library handle
2. **A module-level function pointer var per proc** — typed `proc(...) {.cdecl.}`, initially nil
3. **`loadFoo*(): LoadResult`** — calls `loadLibPattern`, resolves all symbols via `symAddr` + cast. Returns `lrOk` if all symbols resolve, `lrOkPartial` (with `missing: seq[string]`) if only optional symbols are missing, `lrLibNotFound` if the library is missing, or `lrSymbolNotFound` (with `symbol: string`) if a required symbol can't be resolved. Idempotent (returns `lrOk` immediately if already loaded).
4. **`unloadFoo*()`** — unloads library, nils all pointers. No-op if not loaded.
5. **`fooLoaded*(): bool`** — checks if handle is non-nil.
6. **Wrapper procs** — same signature as declared. Check function pointer for nil (raise `SoftlinkError` if so), then dispatch through the pointer.
7. **`xxxAvailable*(): bool`** — generated for each `{.optional.}` proc. Returns whether the function pointer was resolved.

The library name is derived from the pattern string: `"libmbedtls.so(.16|)"` becomes base name `Mbedtls`, producing `loadMbedtls`, `unloadMbedtls`, `mbedtlsLoaded`.

### Key design decisions

- **Required by default, optional per-symbol**: required symbols cause load failure if missing (all-or-nothing for required). Optional symbols (`{.optional.}` pragma) are silently skipped, with `xxxAvailable*(): bool` checks generated.
- **Explicit calling convention required**: the macro requires `{.cdecl.}`, `{.stdcall.}`, etc. — no default. Supports `cdecl`, `stdcall`, `fastcall`, `syscall`, `noconv`.
- **Pragma allowlist**: only calling conventions + `optional` are accepted. Unsupported pragmas (e.g., `varargs`) produce compile-time errors.
- **No thread safety guarantees**: `loadLib` is not thread-safe on all platforms.

## Testing

Tests bind against `libm.so` (always available on POSIX) to validate the macro without external dependencies. Tests cover: successful load, math function dispatch, graceful failure on missing library, `SoftlinkError` on unloaded call, unload/reload cycle, and idempotent double-load.
