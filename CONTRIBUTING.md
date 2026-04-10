# Contributing to softlink

## Development setup

softlink requires **Nim >= 2.0.0**. Tests run in Docker for reproducibility:

```bash
docker run --rm -v $(pwd):/app -w /app nimlang/nim:2.2.0 \
  bash -c "gcc -shared -fPIC -o tests/libtestlib.so tests/testlib.c && \
  LD_LIBRARY_PATH=./tests nim c -r --path:src --passC:-I. tests/test_softlink.nim"
```

Or use `nimble test` if you have the test library built locally.

## Architecture

The entire library is `src/softlink.nim` — a single file exporting two macros (`dynlib` and `dyntype`). See `CLAUDE.md` for detailed design decisions and how the macros work.

## Testing

Tests are in `tests/test_softlink.nim`. The test library (`tests/testlib.h` + `tests/testlib.c`) provides controlled symbols for cross-platform testing. Struct layout tests use `tests/testlib_types.h`.

We use test-driven development (TDD). New features should include tests that fail before the implementation and pass after.

## CI

Pull requests run on Linux (GCC), macOS (Clang), Windows (MinGW), and Windows (MSVC). A separate job verifies the JS backend is rejected with a clear error.

## License

By contributing, you agree that your contributions will be licensed under the Apache-2.0 license.
