# Changelog

All notable changes to softlink are documented here.

## [Unreleased]

### Added
- `dyntype` macro for compile-time struct layout verification against C headers via `_Static_assert(sizeof)`
- `ctype` pragma for mapping Nim types to C struct names in `dyntype` blocks
- `lrLibNotFound` test coverage

### Fixed
- Header verification (`dynlib`) was silently not emitted due to Nim dead code elimination — switched from `{.used.}` to `{.exportc, codegenDecl: "static ...".}` to force emission while keeping symbols file-local
- Preprocessor directives in verify proc needed `\n` prefix to start at line boundaries in generated C

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
