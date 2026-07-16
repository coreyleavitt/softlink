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

#### Verification axes

Every proc in a `dynlib` (or `verifyProcs`, see below) block picks a value on independent axes, mix-and-match:

1. **Declaration source** — `header` (verify against an installed header), `prototype` (verify against a vendored C declaration), or `noverify` (skip verification). At least one is required; `header` and `prototype` may coexist for cross-checking. `prototype` + `noverify` is rejected — both pick a source, and they contradict.
2. **Verification gating** — `{.verifyWhen: "EXPR".}` or nothing, orthogonal to the source axis.
3. **Runtime requirement** — `{.optional.}` or required (the default), orthogonal to both of the above.

The rest of this section covers `verifyWhen`, `prototype`, and `noverify` in turn — the three ways to shape *how* (or whether) a symbol gets compile-time checked.

Note that `{.optional.}` is **runtime**-optional only: the symbol must still be declared in the compile-time header, because header verification runs for optional procs too. For a symbol that may also be absent from the installed headers (e.g. an API added in a newer library version), gate its verification on the library's version macro with `{.verifyWhen.}`:

```nim
dynlib "libfoo.so(.2|.1|)":
  proc core_init(): cint {.cdecl, header: "foo.h".}
  # Added in libfoo 2.5 — may be missing from installed headers AND at runtime.
  # verifyWhen wraps the compile-time check in #if (EXPR): systems with 2.5+
  # headers verify the signature in full; older systems skip it and rely on
  # the runtime-optional machinery.
  proc v25_feature(x: cint): cint
    {.cdecl, optional, verifyWhen: "FOO_VERSION_NUMBER >= 0x0205", header: "foo.h".}
```

The condition is any C preprocessor expression, evaluated after the proc's header is included — version macros like `MBEDTLS_VERSION_NUMBER` or `ZLIB_VERNUM` are the usual choice. This is "verify whenever possible": you lose checking only where checking is genuinely impossible.

#### `{.prototype: "<C prototype>".}` — vendor a declaration instead of a header

For a symbol you can't verify against any installed header — too new for what's on your system, or a header you don't have at all — copy the prototype straight from upstream's own header (any version, including ones newer than what's installed). Strip export/calling-convention macros (`FOO_API`, `WINAPI`, ...); those are storage/link attributes, not part of the type the check compares:

```nim
dynlib "libfoo.so(.2|.1|)":
  proc core_init(): cint {.cdecl, header: "foo.h".}
  # Not in any header installed on this system yet — vendored from upstream's
  # latest foo.h. header stays too, so systems that DO have it get cross-checked.
  proc v3_feature(x: cint, y: cint): cint
    {.cdecl, optional,
      prototype: "int v3_feature(int x, int y)",
      header: "foo.h".}
```

softlink emits the prototype as a file-scope `extern` declaration in the verification translation unit (wrapped in `extern "C" { ... }` under `--backend:cpp`), after the block's `#include`s and before the generated `_Static_assert` checks — then runs the exact same signature verification against it that it runs against a header declaration. This buys three things, in order of importance:

1. **The Nim signature is checked on every system, every build** — the trust hole of "this symbol isn't in any header I can compile against" closes to "did I copy the prototype correctly," a transcription task you can check by eye against upstream.
2. **Opportunistic conflict checking:** on a system whose installed header *does* declare the symbol (as in the example above, with both `header` and `prototype` present), C's same-scope redeclaration rules force the two to agree — an incompatible pair is a hard compile error.
3. **A drift tripwire at recompile:** if upstream changes the signature later, compiling against the newer header conflicts with your vendored prototype and fails loudly instead of silently passing.

Rules:
- The value must be a non-empty string literal containing exactly one, non-variadic C prototype (no trailing `;` needed — the macro appends it). Triple-quoted strings are accepted so you can paste upstream's own multi-line formatting verbatim.
- The declared name must match the proc's C name — a copy-pasted prototype for the wrong symbol is a macro error, not a silently inert declaration.
- A function-pointer *return type* (`(*` immediately after the parameter list's opening paren, e.g. `void (*signal(int, void (*)(int)))(int)`) can't have its name extracted and is rejected — route through a `typedef`'d return type instead. Function-pointer *parameters* are unaffected.
- `header` becomes optional when `prototype` is present, but only if the prototype uses nothing but builtin C types (`int`, `unsigned long`, `const char *`, ...). If it references anything else (`size_t`, a library typedef, a struct tag) and no `header` is given, softlink emits a hint — "this prototype may need `header:` to resolve `<name>`" (a warning under `-d:softlinkStrictVerify`) — since that identifier won't otherwise resolve. The hint never blocks the build; it's a nudge, not a requirement.
- `prototype` + `noverify` is a compile-time error: both pragmas select a declaration source, and they contradict.
- `prototype` + `verifyWhen` composes: both the emitted declaration and its `_Static_assert` are gated by the same `#if`, for prototypes that reference types absent from old headers.
- The prototype is never used for dispatch — calls always go through the `dlsym`'d function pointer, exactly as with `header`-verified procs.

Why not just derive the prototype from your Nim signature automatically? Because C prototype compatibility is `const`-*intolerant* and constness can't be inferred from the Nim side — a derived prototype would turn ABI-safe `const` differences (common across header versions) into build breaks. A prototype transcribed from upstream carries the real constness.

#### `{.noverify: "reason".}` — skip verification, with an optional reason

For a symbol that **no** header declares at any version and no prototype exists for either (undocumented APIs, headers you don't ship), `{.noverify.}` skips verification entirely and lifts the `header` requirement. The declared signature is trusted as-is — with `{.prototype.}` available, reserve `noverify` for symbols with no authoritative prototype anywhere.

Give it a justification string and softlink folds it into the compile-time hint that enumerates every `{.noverify.}` symbol (upgraded to a warning under `-d:softlinkStrictVerify`), so these trust points stay visible in audits:

```nim
dynlib "libfoo.so(.2|.1|)":
  proc internal_dbg_hook(): cint
    {.cdecl, optional, noverify: "private symbol, no public header at any version".}
```

```
softlink: dynlib "libfoo.so(.2|.1|)": 1 symbol not header-verified ({.noverify.}):
  internal_dbg_hook — "private symbol, no public header at any version"
```

The reason is optional — bare `{.noverify.}` still works and renders as `internal_dbg_hook — (no justification)` in the same hint. `{.verifyWhen.}` and `{.noverify.}` on the same proc is a compile-time error (contradictory: one asks for conditional verification, the other for none); so is `{.prototype.}` and `{.noverify.}` together (above).

One `dynlib` block per library per module: a second block whose pattern derives the same identifier base (e.g. `dynlib "m"` twice, or `"libfoo.so"` plus `"foo"`) is rejected at compile time with an error telling you to merge the blocks. Use `{.optional.}`/`{.verifyWhen.}`/`{.prototype.}`/`{.noverify.}` within the single block instead of gating extra symbols behind a separate block.

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

Every proc needs a declaration to verify against: a `header` pragma pointing to the C header that declares it, a vendored `{.prototype: "...".}` (see below — usable with or without `header`, for cross-checking or standalone), or `{.noverify.}` to skip verification for that proc entirely (`{.verifyWhen: "EXPR".}` instead gates the check on a C preprocessor condition, and composes with either source). At compile time, the macro emits `_Static_assert` checks that verify each symbol's declared type matches the Nim declaration. This catches signature mismatches, misspelled symbol names, and missing declarations — all at compile time, without requiring the `.so` to be present. Header-backed procs need only the C header files (e.g., install the `-dev` package); `prototype`-backed procs need nothing installed at all.

### How header verification works

The macro generates a verification function containing compile-time assertions for each declared symbol. It calls the C function with dummy arguments matching your Nim types, then verifies the return type — catching wrong parameter types, wrong parameter count, wrong return types, and misspelled symbols. The comparison is **const-tolerant**: Nim's `ptr T` (which generates `T*` in C) is accepted where the header declares `const T*`, since `const` differences are ABI-safe.

Three-tier fallback for compiler compatibility:

1. **C++ backend** (`--backend:cpp`): `static_assert` with `std::is_same<decltype(symbol(args...)), return_type>`
2. **GCC/Clang** (default): `_Static_assert` with `__builtin_types_compatible_p(__typeof__(symbol(args...)), return_type)`
3. **MSVC C mode**: Call expression + `_Static_assert` with `_Generic` + `__typeof__` pointer trick

**Compiler requirements:** GCC, Clang, MSVC 2022+, or any C++ compiler with C++11 `decltype`. If your compiler supports none of these, compilation will fail with an explicit error message.

## Standalone Verification (`verifyProcs`)

If you're statically linking against a library — plain `{.importc.}` plus a linker flag, or `{.importc, dynlib: "libfoo.so".}` — but still want softlink's `_Static_assert`-grade signature checking, `verifyProcs` emits *only* the compile-time verification: no loading, no wrappers, no runtime footprint.

```nim
import softlink

verifyProcs:
  proc core_init(): cint {.cdecl, header: "foo.h".}
  proc core_free(): cint {.cdecl, header: "foo.h".}
```

This expands to nothing but the header-verification machinery described above — no `loadFoo`, no function-pointer vars, no wrapper procs, no `SoftlinkError`. Use it alongside ordinary `{.importc.}` declarations to get the same signature checking `dynlib` gives you, without opting into runtime-optional loading.

`verifyProcs` shares its pragma parser with `dynlib`, so `header`, `prototype`, and `verifyWhen` all work exactly as described above — with two differences: `{.optional.}` and `{.noverify.}` are rejected. Both are meaningless here: the block exists solely to verify, so a proc that's "optional" or "unverified" has nothing for `verifyProcs` to do with it — just omit it from the block instead.

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

## Verified version compat

Header verification (above) proves your Nim signature matches *today's*
header. It says nothing about last year's release, or next year's — that's
what this section covers, in two halves: a **compile-time** check against
a harvested header corpus, and a **runtime** check against the version of
the library your program actually loads.

### Compile-time: harvest + `compatManifest`

`tools/harvest/` adds a `softlink harvest` CLI that recompiles your
binding against a versioned corpus of upstream headers and records, per
symbol per version, whether it was verified, absent, mismatched, or
unclassifiable — then a `compatManifest` directive attaches the result to
your `dynlib`/`verifyProcs` block for compile-time drift checks (a
contradicted `{.since.}` claim is a hard error; a recorded `mismatch`
warns; a bound symbol missing from the manifest hints).

The one-screen happy path:

```sh
# 1. Dump probe facts for your binding module.
nim c --compileOnly -d:softlinkDumpProbes=probes src/mylib_bindings.nim

# 2. Harvest against your header corpus.
softlink_harvest probes/Mylib.probes.json corpus/ --out:mylib.compat.json

# 3. Commit the manifest, then attach it:
```
```nim
dynlib "mylib":
  compatManifest "mylib.compat.json"
  proc mylib_init(): cint {.cdecl, header: "mylib.h".}
```

See **[`tools/harvest/README.md`](tools/harvest/README.md)** for the full
classification table, the calibration preflight, the fast path, exit
codes, the manifest schema, and a copy-paste CI template
(`tools/harvest/ci-template.yaml`) for keeping a committed manifest from
rotting.

### Runtime: `versionProbe`, `fooCompat()`, and drift refusal

A manifest only helps if the loader knows *which* version it actually
loaded. `versionProbe` supplies that: a body directive that runs after a
block's own symbols resolve and returns the runtime library's version as
a string. It's a body, not a pragma, because real probes are
heterogeneous — Z3 uses out-params, mbedtls returns a string, some
libraries need arithmetic on an int — so softlink asks for a string and
stays out of the parsing business:

```nim
dynlib "z3":
  compatManifest "z3.compat.json"
  proc Z3_get_full_version(): cstring {.cdecl, header: "z3.h".}
  versionProbe:
    parseZ3Version($Z3_get_full_version())   # may call the block's own wrappers
```

Any exception out of the probe body (a parse failure, a wrapper raising on
an unresolved optional symbol) degrades to `attestation = atProbeFailed` —
`loadZ3()` itself never raises. Calling `loadZ3()`/`unloadZ3()` from
*inside* the probe (directly or transitively, e.g. through a helper) is a
reentrancy bug caught at runtime: it raises into the probe's own
`try/except`, which converts it to `atProbeFailed` instead of returning a
fabricated `lrOk`. And at compile time, the probe body is scanned for
direct calls to symbols the attached manifest already records a
`mismatch` interval for — "the probe must not be the drift" — which is a
macro error, not a runtime surprise (indirect calls can't be seen
statically; that residual risk is documented, not defended against).

Every block generates a query proc unconditionally, whether or not it
declares a probe or a manifest at all:

```nim
proc z3Compat*(): CompatReport
```

```nim
type
  Attestation* = enum
    atNoProbe      ## no versionProbe declared, or the probe never ran
                   ## (the load failed before symbols resolved)
    atProbeFailed  ## probe ran and raised, or returned an unparseable string
    atNoManifest   ## probe succeeded, but no compatManifest is attached
    atOutOfCorpus  ## probed version outside the manifest's harvested corpus
    atAttested     ## probed version inside the manifest's harvested corpus

  CompatReport* = object
    runtimeVersion*: string   ## "" unless the probe succeeded
    attestation*: Attestation
    missing*: seq[tuple[symbol: string, reason: MissingReason]]
```

`missing` partitions *why* each symbol in `LoadResult.missing` didn't
resolve, against the manifest's header facts:

| `MissingReason` | Meaning |
|---|---|
| `mrExpected` | this runtime predates the symbol (manifest facts or `{.since.}`) |
| `mrAnomalous` | this version's headers declare it, yet it did not resolve |
| `mrDriftRefused` | it resolved, but was refused for known signature drift |

`unloadX()` resets the report to its zero value (`atNoProbe`, `""`, no
missing entries) alongside its other resets — `fooCompat()` after
`unloadFoo()` never serves a previous load's trust signals.

#### Drift refusal

With a manifest *and* a probe both present: if the runtime version falls
inside a symbol's recorded `mismatch` interval, that symbol is **refused**
— treated as absent, because it's unusable:

- **Optional symbol:** the pointer is re-nilled, `xxxAvailable()` returns
  `false`, the symbol lands in `LoadResult.missing` and in the report as
  `mrDriftRefused`. The wrapper raises `SoftlinkError` with the story
  (`"testlib_gated: signature drift at >=4.0.0 per compat manifest;
  refusing unsafe dispatch"`).
- **Required symbol:** the whole load fails as if the symbol were
  missing — library unloaded, `lrSymbolNotFound` with the symbol name,
  `fooCompat()` carries the drift explanation. This preserves the
  existing invariant **`lrOk` ⟹ every required wrapper is safe to call**.

Refusal only fires on a **known** mismatch: a probed version outside the
manifest's corpus (`atOutOfCorpus`) loads normally, because refusing on a
guess would be worse than not checking at all — a distro-patched version
string could easily land inside a recorded interval it doesn't actually
share the bug with.

#### Escape hatches, scoped to who holds them

- **Binding author** (knows a specific build is locally patched):
  `compatManifest("mylib.compat.json", refuse = false)` — per block.
  Nothing gets refused: drifted-on-paper symbols stay resolved and
  callable, and `fooCompat()` reports them as present (there's no
  "resolved but drifted" entry to serve). Drift visibility stays at
  compile time, where the manifest's recorded `mismatch` already warns.
- **Downstream consumer** (can't edit the binding's source; needs an
  override for a vendor rebuild under an old version string):
  `-d:softlinkNoDriftRefusal` — build-wide, wins over every block's own
  directive.

`xxxPtr()` reads the same pointer variable a wrapper dispatches through,
so it's also nil under refusal — the two knobs above are the override,
not `xxxPtr()`.

#### Degradation

| Probe? | Manifest? | Result |
|---|---|---|
| No | No | Pre-Stage-C behavior, unchanged |
| No | Yes | Manifest is completely inert at runtime — no partition, no refusal |
| Yes | No | `atNoManifest`; `runtimeVersion` populated, nothing to check it against |
| Yes | Yes | Full attestation, absence partition, and drift refusal |

#### Example

```nim
dynlib "mylib":
  compatManifest "mylib.compat.json"
  proc mylib_init(): cint {.cdecl, header: "mylib.h".}
  proc mylib_new_thing(): cint {.cdecl, optional, header: "mylib.h".}
  proc mylib_version(): cstring {.cdecl, header: "mylib.h".}
  versionProbe:
    parseMylibVersion($mylib_version())   # calls the block's own wrapper

let r = loadMylib()
if r.kind in {lrOk, lrOkPartial}:
  let c = mylibCompat()
  echo c.attestation, " @ ", c.runtimeVersion
  for (symbol, reason) in c.missing:
    echo symbol, ": ", reason
```

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
