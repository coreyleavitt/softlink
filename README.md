# softlink

[![CI](https://github.com/coreyleavitt/softlink/actions/workflows/ci.yaml/badge.svg)](https://github.com/coreyleavitt/softlink/actions/workflows/ci.yaml)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Nim](https://img.shields.io/badge/Nim-%E2%89%A5%202.0.0-yellow.svg)](https://nim-lang.org)

Type-safe optional dynamic library bindings for Nim.

Requires **Nim >= 2.0.0**.

## Installation

```
nimble install softlink
```

Or add to your `.nimble` file:

```nim
requires "softlink >= 0.2.0"
```

## The Problem

Nim gives you two ways to bind to C libraries, and both have tradeoffs:

| Approach | Type-safe | Runtime optional | Graceful failure |
|----------|-----------|-----------------|-----------------|
| `{.importc, dynlib.}` | Yes | No | No (fatal quit) |
| `std/dynlib` + `cast` | No | Yes | Yes |

- `{.importc, dynlib: "libfoo.so".}` gives you compile-time type safety but **crashes at startup** if the library is missing — `rawQuit(1)` before `main()` runs.
- `std/dynlib` with `loadLib`/`symAddr` gives you runtime detection but **loses all type safety** — every function is a `cast[proc(...)](pointer)` that the compiler can't verify.

There is no built-in way to get both.

## The Solution

softlink provides a macro that defines function signatures once and generates the `loadLib`/`symAddr` boilerplate automatically:

```nim
import softlink

# Define bindings — verified against C headers at compile time
dynlib "libmbedtls.so(.16|.14|)":
  proc mbedtls_ssl_init(ssl: ptr SslContext) {.cdecl, header: "mbedtls/ssl.h".}
  proc mbedtls_ssl_setup(ssl: ptr SslContext, conf: ptr SslConfig): cint {.cdecl, header: "mbedtls/ssl.h".}
  proc mbedtls_ssl_handshake(ssl: ptr SslContext): cint {.cdecl, header: "mbedtls/ssl.h".}
  proc mbedtls_ssl_free(ssl: ptr SslContext) {.cdecl, header: "mbedtls/ssl.h".}
```

This generates:
- `loadMbedtls(): LoadResult` — loads the library and resolves all symbols
- `unloadMbedtls()` — unloads the library and nils all pointers
- `mbedtlsLoaded(): bool` — checks if the library is currently loaded
- Wrapper procs with the exact signatures you defined (dispatch through function pointers)
- If the library isn't loaded, calls raise `SoftlinkError` (not `rawQuit`)

### Usage

```nim
import softlink

# Check availability at runtime
let r = loadMbedtls()
case r.kind
of lrOk:
  # Use normally — type-safe, same signatures as {.importc.}
  var ctx: SslContext
  mbedtls_ssl_init(addr ctx)
  let rc = mbedtls_ssl_setup(addr ctx, addr conf)
of lrOkPartial:
  echo "mbedTLS loaded; missing optional symbols: ", r.missing
of lrLibNotFound:
  echo "mbedTLS not installed — HTTPS probes disabled"
of lrSymbolNotFound:
  echo "mbedTLS too old — missing required symbol: ", r.symbol
```

### Error handling

`SoftlinkError` carries context about which library and symbol failed:

```nim
try:
  mbedtls_ssl_init(addr ctx)
except SoftlinkError as e:
  echo e.library  # "libmbedtls.so(.16|.14|)" — the raw pattern string
  echo e.symbol   # "mbedtls_ssl_init"
  echo e.msg      # "libmbedtls.so(.16|.14|): library not loaded, cannot call: mbedtls_ssl_init"
```

### Optional symbols

Mark individual functions as optional for version-tier bindings:

```nim
dynlib "libfoo.so(.2|.1|)":
  proc core_init(): cint {.cdecl, header: "foo.h".}                   # required
  proc core_free(): cint {.cdecl, header: "foo.h".}                   # required
  proc v2_feature(x: cint): cint {.cdecl, optional, header: "foo.h".} # optional

case loadFoo().kind
of lrOk:
  echo "libfoo fully loaded"
of lrOkPartial:
  echo "libfoo loaded (some optional features unavailable)"
of lrLibNotFound:
  echo "Install libfoo"
of lrSymbolNotFound:
  echo "libfoo broken or too old"

# Check individual optional symbols
if v2_featureAvailable():
  discard v2_feature(42)
```

Required symbols (default) cause load failure if missing. Optional symbols are silently skipped — their wrapper raises `SoftlinkError` if called, and a generated `xxxAvailable*(): bool` proc lets you check before calling.

### Unload and reload

```nim
if mbedtlsLoaded():
  unloadMbedtls()  # nils all pointers, resets state

# Reload later (idempotent — safe to call multiple times)
let r = loadMbedtls()
```

### Multiple backends

```nim
# In your TLS abstraction:
if loadMbedtls().kind == lrOk:
  initMbedtlsBackend()
elif loadWolfssl().kind == lrOk:
  initWolfsslBackend()
else:
  disableHttps()
```

## How It Works

The `dynlib` macro:

1. **Parses** the proc signatures you provide (names, params, return types, pragmas)
2. **Generates** module-level `var` slots for function pointers (initialized to `nil`)
3. **Generates** a `loadXxx(): LoadResult` proc that:
   - Calls `std/dynlib.loadLibPattern(pattern)` for version-pattern resolution
   - Resolves all symbols via `symAddr` and casts to typed function pointers
   - Returns `lrOk` if all symbols resolve, `lrOkPartial` (with `missing: seq[string]`) if only optional symbols are missing, `lrLibNotFound` if the library is missing, or `lrSymbolNotFound` (with the symbol name) if a required symbol can't be resolved
4. **Generates** wrapper procs that check the function pointer for nil, raise `SoftlinkError` if unloaded, or dispatch through the pointer

The library name is derived from the pattern string by stripping the `lib` prefix, truncating at the first dot, and removing non-alphanumeric characters. For example, `"libmbedtls.so(.16|)"` becomes `Mbedtls`, producing `loadMbedtls`, `unloadMbedtls`, `mbedtlsLoaded`. Note that underscores and hyphens are stripped: `"libfoo_bar.so"` becomes `Foobar`.

The casts from `pointer` to typed proc are generated by the macro from your type annotations — you define the signature once, the macro ensures the cast matches.

## Thread Safety

`loadXxx`, `unloadXxx`, and the generated wrapper procs are **not thread-safe**. The loaded state and function pointer dispatch are not atomic. If you load/unload from multiple threads, or call wrapper procs concurrently with `unloadXxx`, you must synchronize externally.

## Type Safety Guarantees

| What | Verified by |
|------|------------|
| Proc signatures (params, return types) | C compiler — `_Static_assert` checks against header at compile time |
| Cast correctness (pointer → proc) | Macro — generates from your definition, no manual casts |
| Symbol name spelling | C compiler — `_Static_assert` verifies symbol exists in header |
| Struct layout (sizeof) | C compiler — `dyntype` emits `_Static_assert(sizeof)` checks |
| ABI compatibility | C compiler (signature + struct size) + test suite (runtime behavior) |

Every proc requires a `header` pragma pointing to the C header that declares it. At compile time, the macro emits `_Static_assert` checks that verify each symbol's type in the header matches the Nim declaration. This catches signature mismatches, misspelled symbol names, and missing declarations — all at compile time, without requiring the `.so` to be present. Only the C header files are needed (e.g., install the `-dev` package).

### How header verification works

The macro generates a verification function containing compile-time assertions for each declared symbol. It calls the C function with dummy arguments matching your Nim types, then verifies the return type — catching wrong parameter types, wrong parameter count, wrong return types, and misspelled symbols. The comparison is **const-tolerant**: Nim's `ptr T` (which generates `T*` in C) is accepted where the header declares `const T*`, since `const` differences are ABI-safe.

Three-tier fallback for compiler compatibility:

1. **C++ backend** (`--backend:cpp`): `static_assert` with `std::is_same<decltype(symbol(args...)), return_type>`
2. **GCC/Clang** (default): `_Static_assert` with `__builtin_types_compatible_p(__typeof__(symbol(args...)), return_type)`
3. **MSVC C mode**: Call expression + `_Static_assert` with `_Generic` + `__typeof__` pointer trick

**Compiler requirements:** GCC, Clang, MSVC 2022+, or any C++ compiler with C++11 `decltype`. If your compiler supports none of these, compilation will fail with an explicit error message.

## Struct Layout Verification (`dyntype`)

The `dyntype` macro verifies that Nim struct definitions match C header struct layouts at compile time:

```nim
import softlink

dyntype "mylib/types.h":
  type MyPoint {.ctype: "mylib_point_t".} = object
    x: cint
    y: cint

  type MyRect {.ctype: "mylib_rect_t".} = object
    origin: MyPoint
    width: cint
    height: cint
```

This generates `_Static_assert(sizeof(NimType) == sizeof(CType))` checks — if your Nim struct has the wrong size (missing fields, wrong types, padding differences), compilation fails with a clear error message:

```
error: static assertion failed: "softlink dyntype: MyPoint size mismatch vs mylib/types.h (mylib_point_t)"
```

Misspelled C type names are also caught:

```
error: 'mylib_ponit_t' undeclared; did you mean 'mylib_point_t'?
```

Each type requires a `ctype` pragma mapping to the C struct name in the header. The types are defined as regular Nim objects (no `{.importc.}`) — this is what allows the size comparison to work, since the Nim and C structs are separate definitions that can be independently measured.

## Comparison

| Feature | `{.importc, dynlib.}` | `std/dynlib` manual | **softlink** |
|---------|----------------------|--------------------|-----------| 
| Define signatures once | Yes | No (duplicated in casts) | Yes |
| Compile-time type safety | Full (headers) | None | Full (headers via `_Static_assert`) |
| Runtime optional | No | Yes | Yes |
| Graceful failure | No (rawQuit) | Yes (nil) | Yes (exception) |
| Manual cast errors | N/A | Likely | Impossible (macro) |
| Version pattern support | Yes | Yes (loadLibPattern) | Yes |

## License

Apache-2.0
