# Contributing to softlink

## Development setup

The `softlink` library itself requires **Nim >= 2.0.0**. The dev/test
toolchain — and the `softlink_harvest` tool in particular — uses the
project's maintained image `ghcr.io/coreyleavitt/nim:latest` (Nim 2.2.10).
Do NOT use vanilla `nimlang/nim:2.2.0`: the harvester's bounded-subprocess
machinery hits a Nim 2.2.0 ORC cyclic-collector crash (`runProcess` SIGSEGVs
during its `Channel`/`Thread` cleanup); it is fixed in Nim 2.2.8+, which the
project image provides. Tests run in Docker for reproducibility:

```bash
docker pull ghcr.io/coreyleavitt/nim:latest
docker run --rm -v $(pwd):/app -w /app ghcr.io/coreyleavitt/nim:latest \
  bash -c "gcc -shared -fPIC -o tests/libtestlib.so tests/testlib.c && \
  LD_LIBRARY_PATH=./tests nim c -r --path:src --passC:-I. tests/test_softlink.nim"
```

Or use `nimble test` if you have the test library built locally — the same
Nim >= 2.2.8 requirement applies, since `nimble test` runs the crash-prone
`tests/tharvest.nim` harvester suite.

## Architecture

The entire library is `src/softlink.nim` — a single file exporting two macros (`dynlib` and `dyntype`). See `CLAUDE.md` for detailed design decisions and how the macros work.

## Testing

Tests are in `tests/test_softlink.nim`. The test library (`tests/testlib.h` + `tests/testlib.c`) provides controlled symbols for cross-platform testing. Struct layout tests use `tests/testlib_types.h`.

We use test-driven development (TDD). New features should include tests that fail before the implementation and pass after.

## CI

Pull requests run on Linux (GCC), macOS (Clang), Windows (MinGW), and Windows (MSVC). A separate job verifies the JS backend is rejected with a clear error.

## License

By contributing, you agree that your contributions will be licensed under the Apache-2.0 license.
