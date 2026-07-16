## RFC-0001 SS4 B.8: `softlink_harvest` CLI flag-parsing — pure unit tests.
##
## No I/O, no subprocess compiles (unlike tests/tharvest.nim's ~1-minute
## integration suite) — `parseHarvestCli` is a pure function over `seq[string]`
## (see tools/harvest/harvest_cli.nim's own module doc comment for the
## decision/IO split rationale this mirrors), so the full flag surface is
## exercised here in well under a second: defaults, every flag, repeatables,
## malformed `--support-range`, and unknown-flag rejection.
import std/unittest
import ../tools/harvest/harvest_cli
from ../tools/harvest/harvester import defaultHarvestOptions
import softlink/versions

suite "parseHarvestCli — defaults":
  test "defaultExtraFlags stays byte-identical to harvester's own default (deliberate copy, see its doc comment)":
    check defaultExtraFlags == defaultHarvestOptions().extraFlags

  test "two positionals, no flags -> defaults for everything else":
    let r = parseHarvestCli(@["dump.json", "corpus"])
    check r.error.len == 0
    check not r.config.showHelp
    check r.config.dumpFile == "dump.json"
    check r.config.corpusDir == "corpus"
    check r.config.outPath.len == 0
    check not r.config.fastPath
    check r.config.supportRange == VersionInterval(lo: "", hi: "")
    check r.config.nimPaths.len == 0
    check r.config.extraFlags == @["--passC:-Werror=implicit-function-declaration"]
    check r.config.includeFlagPrefix == "-I"

suite "parseHarvestCli — every flag":
  test "--out sets the manifest output path":
    let r = parseHarvestCli(@["dump.json", "corpus", "--out:manifest.json"])
    check r.error.len == 0
    check r.config.outPath == "manifest.json"

  test "--fast-path sets fastPath":
    let r = parseHarvestCli(@["dump.json", "corpus", "--fast-path"])
    check r.error.len == 0
    check r.config.fastPath

  test "--support-range with both bounds":
    let r = parseHarvestCli(@["dump.json", "corpus", "--support-range:1.0.0..2.0.0"])
    check r.error.len == 0
    check r.config.supportRange == VersionInterval(lo: "1.0.0", hi: "2.0.0")

  test "--support-range with only hi (leading '..')":
    let r = parseHarvestCli(@["dump.json", "corpus", "--support-range:..2.0.0"])
    check r.error.len == 0
    check r.config.supportRange == VersionInterval(lo: "", hi: "2.0.0")

  test "--support-range with only lo (trailing '..')":
    let r = parseHarvestCli(@["dump.json", "corpus", "--support-range:1.0.0.."])
    check r.error.len == 0
    check r.config.supportRange == VersionInterval(lo: "1.0.0", hi: "")

  test "--nim-path is repeatable, preserves order":
    let r = parseHarvestCli(@["dump.json", "corpus", "--nim-path:src", "--nim-path:vendor/src"])
    check r.error.len == 0
    check r.config.nimPaths == @["src", "vendor/src"]

  test "--extra-flag is repeatable and APPENDS to the default":
    let r = parseHarvestCli(@["dump.json", "corpus", "--extra-flag:--cc:vcc", "--extra-flag:--foo"])
    check r.error.len == 0
    check r.config.extraFlags == @["--passC:-Werror=implicit-function-declaration", "--cc:vcc", "--foo"]

  test "--no-default-flags drops the built-in default, keeping only --extra-flag values":
    let r = parseHarvestCli(@["dump.json", "corpus", "--no-default-flags", "--extra-flag:--foo"])
    check r.error.len == 0
    check r.config.extraFlags == @["--foo"]

  test "--no-default-flags with no --extra-flag -> empty extraFlags":
    let r = parseHarvestCli(@["dump.json", "corpus", "--no-default-flags"])
    check r.error.len == 0
    check r.config.extraFlags.len == 0

  test "--include-prefix overrides the include-dir flag spelling (MSVC /I)":
    let r = parseHarvestCli(@["dump.json", "corpus", "--include-prefix:/I"])
    check r.error.len == 0
    check r.config.includeFlagPrefix == "/I"

  test "--help sets showHelp and short-circuits (no error, positionals not required)":
    let r = parseHarvestCli(@["--help"])
    check r.error.len == 0
    check r.config.showHelp

suite "parseHarvestCli — usage errors":
  test "malformed --support-range (no '..' separator) is a usage error":
    let r = parseHarvestCli(@["dump.json", "corpus", "--support-range:bogus"])
    check r.error.len > 0

  test "malformed --support-range (more than one '..' pair) is a usage error":
    let r = parseHarvestCli(@["dump.json", "corpus", "--support-range:1.0..2.0..3.0"])
    check r.error.len > 0

  test "unknown flag is a usage error":
    let r = parseHarvestCli(@["dump.json", "corpus", "--bogus-flag"])
    check r.error.len > 0

  test "missing positional arguments is a usage error":
    let r = parseHarvestCli(@["dump.json"])
    check r.error.len > 0

  test "too many positional arguments is a usage error":
    let r = parseHarvestCli(@["dump.json", "corpus", "extra"])
    check r.error.len > 0

  test "no arguments at all is a usage error":
    let r = parseHarvestCli(@[])
    check r.error.len > 0
