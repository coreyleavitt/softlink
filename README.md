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

### Loader-error detail on `lrLibNotFound`

`lrLibNotFound` doesn't just mean "not installed" — it also covers a
present-but-broken library (wrong architecture, a missing transitive
dependency in a partial bundle). `LoadResult.attempts` names every concrete
candidate the pattern expanded to and carries the OS loader's own
diagnostic for each, so the two cases are distinguishable instead of
collapsing into one opaque result:

```nim
let r = loadMbedtls()
if r.kind == lrLibNotFound:
  for a in r.attempts:
    echo a.candidate, ": ", a.osError   # dlerror()/FormatMessage(GetLastError()) text
  # Or, for a one-line rendering:
  echo r.osLoaderDetail
  # "libmbedtls.so.16: cannot open shared object file: No such file or directory; ..."
```

On Linux/macOS, `dlerror()` already tells the two cases apart on its own —
a truly-absent library says so, but a *present* library with a missing
transitive dependency names the missing dependency by its own filename,
not the library you asked for. On Windows, plain `LoadLibrary` collapses
both into the identical `ERROR_MOD_NOT_FOUND`; softlink runs a
`LoadLibraryEx(..., DONT_RESOLVE_DLL_REFERENCES)` preflight (which skips
import resolution) automatically on that specific error and annotates
`osError` when it reveals the target file itself does exist. `attempts` is
empty on every other `LoadResultKind`, including a success where an
earlier candidate in the pattern failed before a later one loaded — once
the load succeeds, an earlier failure carries no information worth
keeping.

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
4. **Validity interval** — `{.since: "x.y.z".}`, `{.until: "x.y.z".}`, both, or neither, declaring the half-open version window `[since, until)` over which the symbol's declared signature is correct. Cross-checked against a harvested compat manifest (a contradicted claim is a compile-time error) and, at runtime, drives absence classification and drift refusal. The one place this axis isn't fully free-standing: `{.until.}` requires a compile-time gate on axis 2 — hand-written, or synthesized from a block-level `versionMacros(...)` directive, which is what keeps the two axes independently *declarable* even though `until` alone can't verify itself. See [Drifted signatures](#drifted-signatures-since-until-and-versionmacros) below.
5. **C symbol identity** — `{.symbol: "c_name".}` or nothing (the Nim proc name is also the C symbol, the common case), orthogonal to all of the above. See [`{.symbol: "c_name"}`](#symbol-c_name--bind-under-a-different-c-name) below.

The rest of this section covers `verifyWhen`, `prototype`, `symbol`, and `noverify` in turn — the ways to shape *how* (or against what name) a symbol gets compile-time checked.

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

#### `{.symbol: "c_name"}` — bind under a different C name

The Nim proc name is usually also the C symbol name; `{.symbol: "c_name".}` overrides that for the cases where it can't or shouldn't be:

- **A fixed-arity Nim view of a variadic C function.** GLib's `g_object_set`/`g_object_get`/`g_object_new` are `NULL`-terminated variadic property setters/getters; softlink, like plain Nim FFI, has no variadic parameter list to declare. A binding instead declares one or more fixed-arity Nim procs — one per property-count shape it actually needs — that all dispatch through the *same* variadic C symbol.
- **An alias for a C name that reads badly as Nim**, or a deliberately shorter Nim-side name for an unwieldy C one (GTK's `gtk_editable_set_text`/`gtk_editable_get_text` are a real example).

```nim
dynlib "libgobject-2.0.so(.0|)":
  # Fixed-arity Nim view of a NULL-terminated variadic setter — dispatches
  # through the real g_object_set, one property at a time. The vendored
  # prototype names the C symbol (g_object_set), not the Nim proc
  # (gObjectSet1) — see the name-match rule below.
  proc gObjectSet1(obj: pointer, propName: cstring, value: pointer)
    {.cdecl, header: "gobject/gobject.h",
      prototype: "void g_object_set(void *object, const char *first_property_name, ...)",
      symbol: "g_object_set".}
```

Rules:
- The value must be a non-empty string literal that is a syntactically valid C identifier (`[A-Za-z_][A-Za-z0-9_]*`) — softlink splices it as literal C text into both the `dlsym`/`GetProcAddress` lookup and the `_Static_assert` verification chain.
- **Two Nim procs may legally bind the same C symbol** — each still gets its own function-pointer slot and its own symbol lookup, but both resolve to the identical address. This is *not* the duplicate-proc error: that check is on the Nim proc name, never the C symbol, so two differently-named Nim procs sharing one `symbol:` value are unaffected by it.
- Every runtime-facing report keys on the C symbol, never the Nim alias: `LoadResult.missing`, `LoadResult.symbol` (`lrSymbolNotFound`), drift-refusal stories (`SoftlinkError.msg`), and `compatManifest`/`{.since.}`/`{.until.}` lookups all name `g_object_set`, not `gObjectSet1`, above.
- `{.prototype.}`'s name-match rule (above) checks against the *effective* C name too, in whichever order the two pragmas are written: a vendored prototype naming the Nim alias instead of the real C symbol is rejected exactly like one naming any other wrong symbol.
- Accessor names (`xxxAvailable*()`, `xxxPtr*()`) still derive from the **Nim** name, unaffected by `symbol:` — only the underlying symbol lookup and verification target change.
- Supported identically in `verifyProcs` — same parsing path as `dynlib`, so a statically-linked binding gets the same rename axis for its own signature cross-checks.
- Deliberately not spelled `importc` (bare or valued): that's a real Nim compiler pragma for an unrelated axis (the FFI import mechanism itself), and reusing its name here — while making the bare form every Nim FFI author reflexively types a hard error — would be a false friend. `importc`, in either spelling, is simply an unrecognized pragma in a `dynlib`/`verifyProcs` body, same as any other typo.

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

#### Block-level `noverify` default

A binding for a library with dozens or hundreds of undocumented symbols repeating the identical `{.noverify: "..."}` justification on every proc is copy-paste noise that invites drift — the string starts diverging as procs are added or edited independently. A standalone `noverify: "<justification>"` statement, written directly in the `dynlib` block body (not as a proc pragma), sets a **block-level default**: every bodyless proc that carries none of `header`/`prototype`/`noverify` inherits it, while a proc that specifies its own source — its own `header`, its own `prototype`, or its own `{.noverify.}` (with or without a reason) — is left exactly as written; the block default only fills the gap.

```nim
dynlib "libfoo.so(.2|.1|)":
  noverify: "internal API, no public header ships for any of these"

  proc internal_dbg_hook(): cint {.cdecl, optional.}
  proc internal_reset_state(): void {.cdecl.}
  proc public_api_call(x: cint): cint {.cdecl, header: "foo_public.h".}  # unaffected: has its own header
```

Like every other body directive (`compatManifest`, `versionProbe`, `versionMacros`, `identBase`), `noverify: "..."` is position-independent — it may appear before or after the procs it covers — and at most one per block; a second one is a compile-time error naming both justifications and asking you to merge them. Its justification is **required and must be non-empty**: unlike the per-proc pragma's optional reason, a bare or empty block-level default would silently waive verification for every gapped proc in the block at once, which is a large enough blast radius to deserve a real reason on its face.

The compile-time audit hint collapses accordingly — every block-defaulted proc folds into one summary entry instead of one line each, while a proc's own explicit `{.noverify.}` keeps its individual line:

```
softlink: dynlib "libfoo.so(.2|.1|)": 2 symbols not header-verified ({.noverify.}):
  2 symbols, block-level reason: "internal API, no public header ships for any of these"
```

A proc that carries `{.verifyWhen.}` or `{.until.}` but no `header`/`prototype` does **not** inherit the block default, even though it otherwise has no verification source: those two pragmas already contradict `{.noverify.}` on a proc that writes it explicitly, and silently inheriting the default onto such a proc would trip that same contradiction error for a `{.noverify.}` the proc's author never wrote. Such a proc simply keeps the ordinary "must specify a header pragma..." error instead — a block-level default fills gaps, it never manufactures a contradiction. The directive is rejected outright in `verifyProcs` blocks (falling into the same "body must contain only proc declarations" error `identBase` gets there) — `verifyProcs` already rejects the per-proc pragma as meaningless, and a whole-block version of the same opt-out is the identical mistake at a larger scale.

One `dynlib` block per library per module: a second block whose pattern derives the same identifier base (e.g. `dynlib "m"` twice, or `"libfoo.so"` plus `"foo"`) is rejected at compile time with an error telling you to merge the blocks. Use `{.optional.}`/`{.verifyWhen.}`/`{.prototype.}`/`{.noverify.}` within the single block instead of gating extra symbols behind a separate block — or, if you genuinely need more than one block over the same library (see [`identBase`](#identbase-overriding-the-derived-identifier-base) below), give each block a distinct override.

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

The library name is derived from the pattern string by stripping the `lib` prefix, truncating at the first dot, and removing non-alphanumeric characters. For example, `"libmbedtls.so(.16|)"` becomes `Mbedtls`, producing `loadMbedtls`, `unloadMbedtls`, `mbedtlsLoaded`. Note that underscores and hyphens are stripped: `"libfoo_bar.so"` becomes `Foobar`. A leading optional-`lib` alternation is normalized the same way a literal `lib` prefix is: `"(lib|)glib-2.0-0.dll"` and `"(libz3|z3).dll"` derive `Glib2` and `Z3` — identical to `"libglib-2.0.so(|.0)"` and `"z3"` respectively — because both spellings of "the `lib` prefix is optional here" are the same alternation, just with an empty or non-empty second candidate.

The casts from `pointer` to typed proc are generated by the macro from your type annotations — you define the signature once, the macro ensures the cast matches.

### `identBase`: overriding the derived identifier base

Sometimes the derived base isn't what you want, or two different patterns for the *same* library derive irreducibly different bases across platforms. The canonical case is a library whose Windows DLL name doesn't parallel its Unix soname closely enough for any string-level normalization to unify them:

```nim
when defined(windows):
  dynlib "(lib|)gtk-4-1.dll":   # derives "Gtk41" — the "-1" DLL suffix has no Unix analog
    identBase "Gtk4"
    proc gtk_init(argc: ptr cint, argv: ptr ptr cstring) {.cdecl, header: "gtk/gtk.h".}
else:
  dynlib "libgtk-4.so(|.1)":    # derives "Gtk4" already — no override needed
    proc gtk_init(argc: ptr cint, argv: ptr ptr cstring) {.cdecl, header: "gtk/gtk.h".}
```

Without `identBase` here, the Windows branch would generate `loadGtk41`/`unloadGtk41`/`gtk41Loaded` while every other platform generates `loadGtk4`/`unloadGtk4`/`gtk4Loaded` — a cross-platform binding whose public proc names differ by target. `identBase "Gtk4"` pins the Windows branch to the same names the other branches derive naturally.

The other motivating case: multiple `dynlib` blocks over *one* library (e.g. splitting a large binding into a "core" block and an "extensions" block) need distinct load-proc names even though they share a pattern — `identBase` on each block resolves the collision that the [one-block-per-library guard](#verification-axes) above would otherwise reject.

Rules: the argument is a single non-empty string literal, and must itself be a valid Nim identifier (it's spliced by concatenation into every generated name — `load<Base>`, `unload<Base>`, `<lowerBase>Loaded`, and so on). At most one `identBase` per block, in any position — a second one is a compile-time error telling you to merge them. `identBase` has no meaning in `verifyProcs` (there's no `loadX`/wrapper surface for it to rename) and is rejected there like any other non-proc statement.

### Statement pass-through: types, consts, and helpers alongside declarations

Real binding modules aren't a flat list of proc declarations — they interleave a `type` for a bitflag or handle, a `const` for a default, and small helper procs (`==`, `hash`, `$`) with the declarations that use them, organized by narrative rather than by kind. `dynlib` supports this directly: a **bodyless proc is a binding declaration** (the only thing that means "resolve this symbol at runtime"); **everything else passes through verbatim** — a `type` or `const` section, a proc *with* a body, a `var`/`let`/`template`/`when`, or a doc comment.

```nim
dynlib "libwidget.so":
  type
    WidgetHandle = distinct pointer   ## opaque handle returned by widget_create

  const WidgetDefaultFlags = 0x1.cint

  proc widget_create(flags: cint): WidgetHandle {.cdecl, header: "widget.h".}
  proc widget_destroy(h: WidgetHandle) {.cdecl, header: "widget.h".}

  ## WidgetHandle has no natural ordering, only identity — borrow equality
  ## from the underlying pointer so callers can compare handles directly.
  proc `==`(a, b: WidgetHandle): bool = pointer(a) == pointer(b)
```

`widget_create`/`widget_destroy` bind exactly as before; `WidgetHandle`, `WidgetDefaultFlags`, and the `==` helper are ordinary Nim code that happens to live inside the block — no `{.header.}`, no calling convention, no verification, because they declare nothing to load. This keeps a migration from `{.importc, dynlib.}` to `dynlib` a per-proc pragma swap, never a whole-file restructuring pass that hoists every type and helper out to a separate section first.

One asymmetry to know about: a `type`/`const` section is visible to every binding in the block regardless of which side of it they're declared on (softlink hoists these ahead of the pointer-var declarations they might be used in), but a passed-through helper proc follows ordinary Nim rules for top-level procs — it may call any binding declared *above* it, not one declared below, exactly as if you'd hand-written two top-level procs in that order. `verifyProcs` (below) doesn't get this feature at all: it exists solely to verify signatures, so every statement in its body still must be a proc declaration.

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

`verifyProcs` shares its pragma parser with `dynlib`, so `header`, `prototype`, and `verifyWhen` all work exactly as described above — with two differences: `{.optional.}` and `{.noverify.}` are rejected. Both are meaningless here: the block exists solely to verify, so a proc that's "optional" or "unverified" has nothing for `verifyProcs` to do with it — just omit it from the block instead. `{.since.}`/`{.until.}` and `versionMacros(...)` (see [Drifted signatures](#drifted-signatures-since-until-and-versionmacros)) are accepted with their compile-time meaning only — gate + manifest cross-check; there is no loader here, so no runtime refusal.

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
contradicted `{.since.}` or `{.until.}` claim is a hard error; a recorded
`mismatch` with no declared bound explaining it warns, while a mismatch
fully covered by a declared `{.until.}` bound only hints — expected drift,
the mechanism working as designed; a bound symbol missing from the
manifest hints).

The one-screen happy path:

```sh
# 1. Dump probe facts for your binding module. -d:softlinkDumpProbes
#    requires an ABSOLUTE directory (it shells out to write the dump; a
#    relative path resolves against the wrong working directory) — use
#    $PWD/probes, not probes.
nim c --compileOnly -d:softlinkDumpProbes=$PWD/probes src/mylib_bindings.nim

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
    atNoProbe      ## PERMANENT: this block declares no versionProbe at all
    atProbeNotRun  ## TRANSIENT: a versionProbe IS declared, but hasn't run
                   ## yet — before the first load, after unloadX(), or
                   ## after a load that failed before symbols resolved
    atProbeFailed  ## probe ran and raised, or returned an unparseable string
    atNoManifest   ## probe succeeded, but no compatManifest is attached
    atOutOfCorpus  ## probed version outside the manifest's harvested corpus
    atAttested     ## probed version inside the manifest's harvested corpus

  CompatReport* = object
    runtimeVersion*: string   ## "" unless the probe succeeded
    attestation*: Attestation
    missingReasons*: seq[tuple[symbol: string, reason: MissingReason,
                                interval: VersionInterval]]
    probeNotComparable*: bool ## probe string exactly tied a declared bound
                              ## with a pre-release suffix, or didn't parse —
                              ## declared-bound refusal declined to decide
```

`atNoProbe` and `atProbeNotRun` are easy to conflate but mean different
things: `atNoProbe` is a permanent, structural fact about the block (it
never declared a probe, so it can never report anything else); `atProbeNotRun`
is a transient fact about a block that *does* declare a probe, valid only
until the next load attempt gives the probe a chance to actually run.

`missingReasons` partitions *why* each symbol in `LoadResult.missing` didn't
resolve, against the manifest's header facts:

| `MissingReason` | Meaning |
|---|---|
| `mrExpected` | this runtime is outside the symbol's known lifetime — it predates the symbol (manifest facts or `{.since.}`) or is at/above a declared `{.until.}` |
| `mrAnomalous` | this version's headers declare it, yet it did not resolve |
| `mrDriftRefused` | it resolved, but was refused for signature drift (manifest facts, or a declared `{.since.}`/`{.until.}` bound) |

Each entry also carries the *evidence* `interval` behind the reason — the
manifest's recorded interval where facts drove the entry, the declared
`[since, until)` where a pragma did (rendered like `>=4.0.0, <4.16.0`).

`unloadX()` resets the report to this block's own "probe hasn't run" state
(`atProbeNotRun` if a `versionProbe` is declared, `atNoProbe` if not; `""`
runtime version, no `missingReasons` entries either way) alongside its
other resets — `fooCompat()` after `unloadFoo()` never serves a previous
load's trust signals.

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

Manifest-fact refusal only fires on a **known** mismatch: for a symbol
without declared bounds, a probed version outside the manifest's corpus
(`atOutOfCorpus`) loads normally, because refusing on a guess would be
worse than not checking at all — a distro-patched version string could
easily land inside a recorded interval it doesn't actually share the bug
with. A symbol carrying a declared `{.since.}`/`{.until.}` bound is the
one exception: there the *author* has stated where the signature is
invalid, and refusal follows the declaration even off-corpus — see
[Drifted signatures](#drifted-signatures-since-until-and-versionmacros).

#### Escape hatches, scoped to who holds them

- **Binding author** (knows a specific build is locally patched):
  `compatManifest("mylib.compat.json", refuse = false)` — per block.
  Nothing gets refused: drifted-on-paper symbols stay resolved and
  callable, and `fooCompat()` reports them as present (there's no
  "resolved but drifted" entry to serve). Drift visibility stays at
  compile time, where the manifest's recorded `mismatch` already warns
  (or, for a mismatch fully covered by a declared `{.until.}` bound,
  hints).
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
| Yes | No | `atNoManifest`; `runtimeVersion` populated, no facts to check it against — but declared `{.since.}`/`{.until.}` bounds still refuse ([Drifted signatures](#drifted-signatures-since-until-and-versionmacros)) |
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
  for (symbol, reason, interval) in c.missingReasons:
    echo symbol, ": ", reason, " (", interval, ")"
```

## Drifted signatures: `since`, `until`, and `versionMacros`

Everything so far handles a symbol that's *added* (`prototype`, `verifyWhen`)
or *removed* (`optional`) across library versions. A third kind of drift is
nastier: a symbol that exists at **every** version under the same name, but
whose **signature changed** somewhere along the way — Z3's
`Z3_fpa_get_numeral_sign` took `int *sgn` through 4.15 and `bool *sgn` from
4.16. A binding declaring the old shape resolves fine at 4.16 via `dlsym`,
then dispatches the wrong ABI: silent memory corruption, the exact bug class
softlink exists to prevent. This section is the first-class path for it.

### The validity interval

Declare the window over which your Nim signature is correct:

- `{.since: "x.y.z".}` — inclusive lower bound (already covered above).
- `{.until: "x.y.z".}` — **exclusive** upper bound: the first version at
  which the declared signature is *no longer* correct.

Together they form the half-open interval `[since, until)`, matching the
compat manifest's own interval convention. `until: "4.16.0"` means 4.15.x is
in range and 4.16.0 itself is out. Either bound may appear alone —
`until`-only ("valid since forever, drifts later") is the common real-world
shape. Every diagnostic renders the interval in one-sided-comparison form
(`>=4.0.0, <4.16.0`), so the half-open reading is reinforced at each point
of use.

Shape rules, all compile-time errors when violated: the bound must parse as
a version; `since >= until` is an empty interval; and `until` requires the
proc to be corpus-trackable — a `header`, not `noverify`, not a header-less
`prototype` (`prototype` + `header` cross-check mode is fine). An `until` on
a symbol the harvester can't observe would be an unfalsifiable claim.

### The worked example: `versionMacros` + `until`

Declare the library's version-macro spelling once per block, then just state
the bound — softlink synthesizes the compile-time verify gate from it:

```nim
import softlink

dynlib "z3":
  versionMacros("Z3_MAJOR_VERSION", "Z3_MINOR_VERSION", "Z3_PATCH_VERSION",
                header = "z3_version.h")

  # int* out-param through 4.15; bool* from 4.16 — declare the historical
  # shape, bounded. No hand-written gate anywhere.
  proc Z3_fpa_get_numeral_sign(c: Z3_context, t: Z3_ast, sgn: ptr cint): cint
    {.cdecl, optional, header: "z3.h", until: "4.16.0".}
```

This compiles against **whatever header is installed**: on a 4.15 header the
declared `int*` signature is verified in full; on a 4.16+ header the check
is skipped (verifying the old shape there would be asserting a falsehood).
With a `versionProbe` on the block, the symbol is refused at runtime
wherever the loaded version is at or above `4.16.0` — see
[runtime behavior](#runtime-behavior-declared-bound-refusal) below.

`versionMacros` takes the library's version macros as separate string
arguments, **most significant first**. The macros must be *in scope* by the
time the synthesized gate evaluates — defined by a header some proc in the
block already includes, or by the header named in `versionMacros`'s own
optional `header = "..."` argument (same quoted/angle-bracket convention as
`{.header.}`: `header = "z3_version.h"` emits `#include "z3_version.h"`,
`header = "<z3_version.h>"` emits `#include <z3_version.h>`). If neither
holds, the verify translation unit fails loudly with a softlink `#error`
naming the macro, instead of silently misverifying (in C, an undefined
identifier inside `#if` evaluates to `0` with no warning; softlink emits a
per-macro `#ifndef`/`#error` guard so a synthesized gate can never fall into
that hole). At most one `versionMacros` per block, any position; accepted in
both `dynlib` and `verifyProcs`.

**When you need `header = ...`.** Some libraries split their version macros
into a header their main header doesn't itself include — Z3 is exactly this
case: `z3.h` never includes `z3_version.h`, so `Z3_MAJOR_VERSION` et al. are
never in scope by the time the synthesized gate runs, and the
`#ifndef`/`#error` guard above fires with no fix available from inside the
`{.until.}`-carrying proc's own `{.header.}`. `header = "z3_version.h"` adds
that header to the block's own `#include` list — no hand-rolled bridge
header, no extra `-I` flag. You do *not* need it for an umbrella header that
pulls its own version macro in transitively — mbedtls's
`MBEDTLS_VERSION_NUMBER`, for instance, is defined by `mbedtls/version.h`,
which `mbedtls/ssl.h` already includes, so any proc's ordinary `{.header:
"mbedtls/ssl.h".}` already puts the macro in scope. When in doubt, omit
`header = ...` first: if the macro really is already in scope, the
`#ifndef`/`#error` guard above stays silent and nothing else needs to
change; if it isn't, the guard's own error message names exactly which
macro is missing, and that name is what to point `header = ...` at.

### What synthesis emits

From `until: "4.16.0"` and the macro list above, softlink generates the
`{.verifyWhen.}` predicate

```c
(Z3_MAJOR_VERSION < 4) || (Z3_MAJOR_VERSION == 4 && Z3_MINOR_VERSION < 16)
```

— the full nested lexicographic comparison, with trailing zero components
stripped (which is why `Z3_PATCH_VERSION` doesn't appear here; a
non-trailing zero is never dropped — `since: "4.0.5"` keeps all three
components, because eliding the middle `0` would compare the wrong macros).
A `since` bound synthesizes the mirrored `>=` form; both bounds AND-combine.
Trailing zero components are stripped from the bound before synthesis
(`"4.16.0"` ≡ `"4.16"`; `"2.0.0"` against a single macro strips to `"2"`
and is accepted) — bounds shorter than the macro list need no padding,
since the predicate only ever compares a macro-list prefix. A bound with
*more* EFFECTIVE components (after that stripping) than the macro list, or
with an alphabetic run (`"4.16.0rc1"`), is a compile-time error — there is
no C macro for the extra precision to compare against, and silent
truncation would be wrong at exactly the boundary that matters.

The result is assigned to the proc's `verifyWhen` before verification runs,
so the rest of the machinery — the `#if` wrapping, `prototype`-declaration
gating, all three compiler tiers — behaves exactly as if you had written the
gate by hand. Only procs carrying `until` and no explicit `verifyWhen` are
synthesized: `since`-only procs keep their (ungated) shipped behavior, and
an explicit `{.verifyWhen.}` on the proc always overrides synthesis verbatim.

### The hand-written escape hatch

An explicit `{.verifyWhen.}` next to `until` is the override, appropriate in
exactly two situations:

**Feature macros.** When the drift tracks a feature flag rather than the
version number (`#ifdef FOO_NEW_API`-style), no version arithmetic applies —
write the predicate yourself.

**Packed single-macro libraries** — mbedtls, sqlite. These encode the whole
version in one integer macro, which is *monotonic across major versions by
construction*, so the correct hand gate is a single comparison with no
rollover failure mode:

```nim
dynlib "libmbedtls.so(.16|.14|)":
  # Old-shape API, drifted at mbedtls 3.6.0. One packed macro, one
  # comparison — rollover-safe without synthesis.
  proc mbedtls_ssl_old_api(ssl: ptr SslContext): cint
    {.cdecl, optional, header: "mbedtls/ssl.h", until: "3.6.0",
      verifyWhen: "MBEDTLS_VERSION_NUMBER < 0x03060000".}
```

(sqlite is the same pattern: `SQLITE_VERSION_NUMBER < 3045000`.) These
libraries stay on hand gates *by design* — the entire bug class synthesis
exists to eliminate cannot occur for a packed macro.

That bug class is real for **split** macros, though. The naive hand gate for
the Z3 example is `Z3_MINOR_VERSION < 16` — which flips true again when Z3
5.0 resets the minor version, silently re-enabling verification against a
header whose ABI moved for unrelated reasons. The correct hand gate is the
compound predicate shown in [What synthesis emits](#what-synthesis-emits),
and softlink can require a gate to *exist* but cannot check a hand-written
gate's *value* against `until` (the only compile-time version signal lives
inside the emitted C, out of the macro's reach). For split-macro libraries,
prefer `versionMacros` — the gate is correct by construction.

Two hand-gate caveats synthesis would otherwise cover for you: an undefined
macro inside `#if` silently evaluates to `0` (no `#ifndef` guards are
emitted for hand gates — softlink can't parse identifiers out of an opaque C
expression), and no threshold consistency with `until` is ever checked.

### Runtime behavior: declared-bound refusal

At runtime (probe required; manifest optional), a bounded symbol whose
probed version falls **outside** `[since, until)` is refused — the same
treatment as manifest-driven [drift refusal](#drift-refusal) above:

- **Optional symbol:** re-nilled, `xxxAvailable()` false, reported as
  `mrDriftRefused`; its wrapper raises the drift story
  (`"Z3_fpa_get_numeral_sign: signature drift, declared valid only at
  <4.16.0; refusing unsafe dispatch"`), not a generic "not loaded".
- **Required symbol:** the whole load unwinds (`lrSymbolNotFound`), same as
  attested drift — `lrOk` still means every required wrapper is safe.

Where each mechanism applies:

| probed version is... | what refuses |
|---|---|
| inside the manifest's corpus (`atAttested`), symbol present in the manifest | manifest `mismatch` facts — decisive for parameter-only drift too now that harvest facts are ground truth (RFC-0003: a drift like `Z3_fpa_get_numeral_sign`'s classifies `mismatch`, not the `unknown` an older harvester would have recorded) — declared bounds add nothing on top |
| inside the manifest's corpus (`atAttested`), symbol **absent** from the manifest | the **declared bound** itself — `checkUntil` never validated this symbol (nothing in the manifest to check it against), so the row above's redundancy argument doesn't hold for it (code-review finding CR1-1) |
| outside the corpus (`atOutOfCorpus`) | the **declared bound** itself |
| probe ok, no manifest at all (`atNoManifest`) | the **declared bound** itself |

The last three rows narrow the earlier "refusal only fires on a known
mismatch" policy, deliberately: without them, `until: "4.16.0"` would
protect you at 4.16.0 exactly (if harvested) and dispatch the wrong ABI at
4.16.3 (a patch release the corpus never saw) — the failure asymmetry
(visible, recoverable false refusal vs. silent memory corruption on false
accept) decides it. The narrowing is scoped to symbols whose **author
explicitly declared** a bound — and when a manifest is attached *and
records that symbol*, the declaration has survived the harvester
cross-check, decisively: since RFC-0003's ground-truth harvest fix, a
parameter-only drift like this section's own `Z3_fpa_get_numeral_sign`
example classifies `mismatch` at the bound rather than the pre-fix
`unknown` that would have forced dropping the bound outright. A bounded
symbol a manifest-carrying block forgot to
re-harvest gets no such pass, at any attestation — softlink surfaces the
gap itself: the not-in-manifest hint (a warning under
`-d:softlinkStrictVerify`) names it. Unbounded symbols keep
the report-don't-block policy everywhere. The same escape hatches apply:
`compatManifest(..., refuse = false)` per block (when a manifest is
attached), `-d:softlinkNoDriftRefusal` build-wide. A manifest-less block has
no per-block hatch — the block author *is* the declarer there; the
author-side escape is not declaring a bound.

Reporting: `missingReasons` entries carry a typed
`interval: VersionInterval` — the *evidence* interval for the refusal (the
manifest's recorded mismatch interval on the attested path, which is more
precise than your claim; the declared `[since, until)` everywhere else).
One edge case declines to decide: a probed version that exactly ties a bound
with a pre-release-style suffix (`"4.16.0-rc1"` vs `until: "4.16.0"`) or
doesn't parse at all is not comparable under softlink's
no-pre-release-semantics version order — the symbol loads normally and
`CompatReport.probeNotComparable` is set `true` (report-don't-block for that
one ambiguous case). A decisive numeric prefix still decides regardless of
suffix: `"4.16.3-ubuntu3"` is ≥ `4.16.0` and refuses.

With a manifest attached, `checkUntil` cross-checks the declared bound
against the harvested facts at compile time (over-claims, drift-then-revert,
and evidence-free bounds are hard errors — see
[`tools/harvest/README.md`](tools/harvest/README.md#checkuntil-validating-a-declared-until-against-the-corpus)).
Without a probe, bounds have no runtime effect at all — they are compile-time
declaration plus cross-check only.

### Caveats

- **Prefer `{.optional.}` on bounded symbols.** A *required* drifted symbol
  takes down the entire load above `until` — usually not what you want
  unless the binding is meaningless without it. softlink emits a
  compile-time hint for `until` on a required proc (a warning under
  `-d:softlinkStrictVerify`).
- **`verifyProcs` reduced meaning.** `until` and `versionMacros` are
  accepted in `verifyProcs` blocks, where they mean compile-time gate +
  manifest cross-check only — `verifyProcs` generates no loader, so there is
  no runtime refusal to drive.
- **Per-ABI drift points.** Bounds are declared once on the Nim proc but
  manifests are per-ABI; a library whose drift point differs by platform
  (distro-patched builds) will pass `checkUntil` on one platform and fail on
  another — by design, the declaration is genuinely wrong somewhere. Use
  conditional compilation / per-platform binding modules.
- **No version signal, no `until`.** A library exposing no compile-time
  version macro (and no feature macro) has nothing to gate on — and
  `noverify` is deliberately not accepted as an alternative (`until` +
  `noverify` is an error: untrackable claims can't be kept honest). Such
  symbols stay on the status-quo paths.

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
