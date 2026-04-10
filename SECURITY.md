# Security Policy

## Reporting a vulnerability

If you discover a security vulnerability in softlink, please report it through [GitHub Security Advisories](https://github.com/coreyleavitt/softlink/security/advisories/new).

Do not open a public issue for security vulnerabilities.

## Scope

softlink is a compile-time macro library that generates dynamic library loading code. Security-relevant areas include:

- **Type safety guarantees** — the `_Static_assert` verification mechanism must not have bypass paths
- **Generated code correctness** — function pointer casts and symbol resolution must be type-safe
- **C code injection** — user-provided strings (library names, header paths, symbol names) are emitted into C code via `{.emit.}` and must not allow injection
