## Finding #24(d) (code-review round 2 coverage gap): `tests/tharvest_cli.nim`
## tests `--help` and an unknown flag each in isolation ("--help sets
## showHelp and short-circuits", "unknown flag is a usage error") but never
## their RELATIVE ORDER on one command line. `parseHarvestCli` (see
## `tools/harvest/harvest_cli.nim`) walks `std/parseopt`'s `getopt()` once,
## left to right, and `--help` returns IMMEDIATELY the moment it's seen
## (`cfg.showHelp = true; return CliParseResult(config: cfg)`) — so ordering
## genuinely changes the outcome:
##  - `--help` before an unknown flag: the loop returns at `--help` and
##    never reaches the unknown flag at all -> success, `showHelp = true`,
##    no error.
##  - an unknown flag before `--help`: the loop returns its usage error at
##    the FIRST unrecognized flag, before ever reaching `--help` -> error,
##    `showHelp` stays false.
## This is read-only against the existing, already-correct
## `tools/harvest/harvest_cli.nim` (not modified here) — a pure `unittest`
## fixture pinning the documented left-to-right, first-match-wins behavior
## so a future refactor (e.g. hoisting `--help` to a pre-scan) can't
## silently change this without a test noticing.
import std/[unittest, strutils]
import ../tools/harvest/harvest_cli

suite "parseHarvestCli -- --help / unknown-flag ordering (finding #24d)":
  test "--help before an unknown flag: short-circuits, no error, showHelp true":
    let r = parseHarvestCli(@["--help", "--totally-bogus-flag"])
    check r.error.len == 0
    check r.config.showHelp

  test "unknown flag before --help: usage error fires first, showHelp stays false":
    let r = parseHarvestCli(@["--totally-bogus-flag", "--help"])
    check r.error.len > 0
    check "unknown flag" in r.error
    check not r.config.showHelp

  test "--help before a malformed --support-range: short-circuits before the malformed value is even parsed":
    let r = parseHarvestCli(@["--help", "--support-range", "not-a-range-at-all"])
    check r.error.len == 0
    check r.config.showHelp

  test "--help together with the two required positionals: still short-circuits, positionals not required":
    let r = parseHarvestCli(@["dump.json", "--help", "corpus"])
    check r.error.len == 0
    check r.config.showHelp

  test "control: --help alone (no ordering question) still behaves as tharvest_cli.nim already pins":
    let r = parseHarvestCli(@["--help"])
    check r.error.len == 0
    check r.config.showHelp
