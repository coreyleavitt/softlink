# softlink

Type-safe optional dynamic library bindings for Nim.

Requires **Nim >= 2.0.0**.

## Installation

```
nimble install softlink
```

Or add to your `.nimble` file:

```nim
requires "softlink >= 0.1.0"
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
case loadMbedtls().kind
of lrOk:
  # Use normally — type-safe, same signatures as {.importc.}
  var ctx: SslContext
  mbedtls_ssl_init(addr ctx)
  let rc = mbedtls_ssl_setup(addr ctx, addr conf)
of lrOkPartial:
  echo "mbedTLS loaded (some optional features unavailable)"
of lrLibNotFound:
  echo "mbedTLS not installed — HTTPS probes disabled"
of lrSymbolNotFound:
  echo "mbedTLS too old — please upgrade"
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
| ABI compatibility | C compiler (signature) + test suite (runtime behavior) |

Every proc requires a `header` pragma pointing to the C header that declares it. At compile time, the macro emits `_Static_assert` checks that verify each symbol's type in the header matches the Nim declaration. This catches signature mismatches, misspelled symbol names, and missing declarations — all at compile time, without requiring the `.so` to be present. Only the C header files are needed (e.g., install the `-dev` package).

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
