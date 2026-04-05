# softlink — Implementation Plan

## Problem Statement

Nim has no standard way to bind to a C library that may or may not be present
at runtime while preserving type safety. `{.importc, dynlib.}` is type-safe but
fatally crashes if the library is missing. `std/dynlib` is runtime-optional but
requires manual `cast[proc(...)](pointer)` with zero compiler verification.

## Solution

A `dynlib` macro that:
1. Accepts proc declarations with full type annotations
2. Generates `std/dynlib`-based loading code automatically
3. Produces wrapper procs with the original signatures
4. Dispatches through function pointers resolved at load time
5. Raises `SoftlinkError` (not `rawQuit`) if called before loading

## Architecture

```
User writes:                    Macro generates:
                                
dynlib "libfoo.so":             var handle: LibHandle
  proc foo(x: cint): cint      var fp_foo: proc(x: cint): cint {.cdecl.}
                                
                                proc loadFoo(): bool =
                                  handle = loadLibPattern(...)
                                  fp_foo = cast[...](symAddr(handle, "foo"))
                                  
                                proc foo*(x: cint): cint =
                                  if fp_foo.isNil: raise SoftlinkError
                                  fp_foo(x)
```

## Macro Details

### Input parsing
- `libPattern`: static string, e.g., `"libmbedtls.so(.16|.14|)"`
- `body`: `nnkStmtList` containing `nnkProcDef` nodes
- Each proc: extract name, params (nnkFormalParams), return type, pragmas

### Name generation
- `"libmbedtls.so(.16|)"` → base name `"Mbedtls"`
- `loadMbedtls()`, `unloadMbedtls()`, `mbedtlsLoaded()`
- Internal vars: `softlink_handle_mbedtls`, `softlink_fp_mbedtls_ssl_init`

### Generated artifacts per library
1. `var softlink_handle_xxx {.global.}: LibHandle`
2. `var softlink_fp_procname {.global.}: proc(...) {.cdecl.}` — one per declared proc
3. `proc loadXxx*(): bool` — loads library, resolves all symbols, returns false on failure
4. `proc unloadXxx*()` — unloads library, nils all pointers
5. `proc xxxLoaded*(): bool` — returns true if library is loaded
6. Wrapper procs — one per declared proc, same signature

### Load behavior
- `loadXxx()` calls `loadLibPattern(pattern)` (supports version fallback)
- For each symbol: `symAddr(handle, "procname")` → cast to typed proc ptr
- If ANY symbol is missing: unload library, nil all pointers, return false
- All-or-nothing: either all symbols resolve or none do
- Idempotent: calling `loadXxx()` when already loaded returns true immediately

### Unload behavior
- `unloadXxx()` calls `unloadLib(handle)`, nils handle and all function pointers
- Safe to call when not loaded (no-op)

### Wrapper behavior
- Check function pointer for nil → raise `SoftlinkError` with symbol name
- Otherwise: tail-call through function pointer
- Same signature as user's declaration — type-safe at call site

### Error handling
- Library missing: `loadXxx()` returns `false` — caller decides what to do
- Symbol missing: `loadXxx()` returns `false` — all-or-nothing
- Calling before load: raises `SoftlinkError` with symbol name
- No `rawQuit`, no fatal crashes

## Edge Cases to Handle

### Proc with no return type (void)
```nim
proc mbedtls_ssl_init(ssl: ptr SslContext) {.cdecl.}
```
Wrapper calls through pointer without `return`.

### Proc with multiple params
```nim
proc mbedtls_ssl_conf_ca_chain(conf: ptr SslConfig, ca: ptr X509Crt, crl: ptr X509Crl) {.cdecl.}
```
All params forwarded in order.

### Variadic functions
Not supported — `{.cdecl, varargs.}` can't be represented as a proc type.
Document as limitation.

### Opaque struct types
User defines types separately:
```nim
type SslContext {.incompleteStruct.} = object
```
softlink doesn't handle types — only proc declarations.

### Multiple libraries in same module
```nim
dynlib "libmbedtls.so":
  proc mbedtls_ssl_init(...) {.cdecl.}

dynlib "libwolfssl.so":
  proc wolfSSL_Init(): cint {.cdecl.}
```
Each gets independent handle, load/unload, function pointers.

### Library version patterns
Pattern syntax matches Nim's `{.dynlib.}`:
- `"libfoo.so"` — exact name
- `"libfoo.so(.2|.1|)"` — try .so.2, then .so.1, then .so

## Testing Strategy

### Unit tests (tests/test_softlink.nim)
- Bind to `libm.so` (always available) — verify math functions work
- Bind to nonexistent library — verify graceful failure
- Verify SoftlinkError on unloaded call
- Verify unload + reload cycle
- Verify idempotent double-load

### Integration tests
- Bind to mbedTLS (if available) — verify TLS functions callable
- Bind to wolfSSL (if available) — same
- Neither available — verify graceful degradation

### Macro output inspection
- Use `macros.repr` to dump generated AST in tests
- Verify generated proc signatures match input

## File Structure

```
softlink/
  softlink.nimble
  README.md
  PLAN.md
  src/
    softlink.nim          # The macro + SoftlinkError type
  tests/
    test_softlink.nim     # Unit tests against libm
  examples/
    tls_backend.nim      # Example: mbedTLS/wolfSSL runtime selection
```

## Integration with nim-mbedtls

Once softlink is stable:

1. nim-mbedtls adds softlink as a dependency
2. Low-level bindings (`src/mbedtls/ssl.nim`, etc.) switch from:
   ```nim
   {.passL: "-lmbedtls".}
   proc mbedtls_ssl_init*(ssl: ptr SslContext) {.importc, header: "mbedtls/ssl.h".}
   ```
   To:
   ```nim
   import softlink
   dynlib "libmbedtls.so(.21|.16|.14|)":
     proc mbedtls_ssl_init*(ssl: ptr SslContext) {.cdecl.}
   ```
3. High-level API (`TlsContext`, etc.) unchanged — calls same function names
4. Consumers add `if not loadMbedtls(): disableHttps()` at startup

## Integration with nopal

1. nopal's `src/health/https.nim` calls `loadMbedtls()` at probe init
2. If neither TLS backend loads: HTTPS probes disabled with warning
3. One binary, one package, works with any TLS library present
4. OpenWrt package: `Depends: libmbedtls | libwolfssl` (optional)

## Risks

1. **ABI mismatch**: softlink can't verify proc signatures against C headers.
   Mitigation: test suite exercises real function calls.

2. **Thread safety**: `loadLib` is not thread-safe on all platforms.
   Mitigation: nopal is single-threaded. Document limitation.

3. **Macro complexity**: AST manipulation is fragile.
   Mitigation: comprehensive tests, macro output inspection.

4. **Performance**: one indirect call per function (function pointer).
   Mitigation: negligible for TLS probe use case (one handshake per N seconds).
