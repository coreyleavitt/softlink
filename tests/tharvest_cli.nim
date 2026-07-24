## RFC-0001 SS4 B.8: `softlink_harvest` CLI flag-parsing — pure unit tests.
##
## No I/O, no subprocess compiles (unlike tests/tharvest.nim's ~1-minute
## integration suite) — `parseHarvestCli` is a pure function over `seq[string]`
## (see tools/harvest/harvest_cli.nim's own module doc comment for the
## decision/IO split rationale this mirrors), so the full flag surface is
## exercised here in well under a second: defaults, every flag, repeatables,
## malformed `--support-range`, and unknown-flag rejection.
import std/[unittest, strutils]
import ../tools/harvest/harvest_cli
from ../tools/harvest/harvester import defaultHarvestOptions, harvestReservedDefines
from ../tools/harvest/harvest_defaults import defaultDiagnosticsPinFlags
import softlink/versions

func bareFlag(f: string): string =
  ## Strips a leading "--somePassthroughFlag:" prefix (e.g. "--passC:") so
  ## the underlying compiler diagnostic name (e.g.
  ## "-Werror=implicit-function-declaration") can be searched for inside
  ## `usageText`'s prose, which never repeats the "--passC:" wrapper.
  let idx = f.find(':')
  if idx >= 0: f[idx + 1 .. ^1] else: f

suite "parseHarvestCli — defaults":
  test "defaultExtraFlags IS the shared harvest_defaults const (stage-4 review M7)":
    ## RFC-0003 stage-4 review M7: `harvest_cli.defaultExtraFlags` used to
    ## be a hand-copied literal of `harvester.defaultHarvestOptions()`'s
    ## own defaults, kept in sync only by this test comparing the two at
    ## runtime. Both now derive from the single `harvest_defaults.
    ## defaultDiagnosticsPinFlags` const (see that module's doc comment),
    ## so drift between them is structurally impossible rather than test-
    ## policed — this assertion is now a tautology BETWEEN the two
    ## consumers, kept as a regression guard against a future consumer
    ## reintroducing its own literal.
    check defaultExtraFlags == defaultHarvestOptions().extraFlags
    check defaultExtraFlags == defaultDiagnosticsPinFlags

  test "the shared const's actual contents are pinned (catches a careless edit to harvest_defaults.nim)":
    check defaultDiagnosticsPinFlags == @["--passC:-Werror=implicit-function-declaration",
                                          "--passC:-Werror=incompatible-pointer-types"]

  test "usageText names every flag in defaultExtraFlags (stage-4 review M5)":
    ## RFC-0003 stage-4 review M5: `usageText` used to hand-name only the
    ## FIRST default pin flag, and nothing caught it falling out of sync
    ## when a second default flag was added. This is a generic sync
    ## assertion (not a hardcoded pair of flag names) so it survives
    ## future additions/removals from `defaultExtraFlags` without edits.
    for flag in defaultExtraFlags:
      check bareFlag(flag) in usageText

  test "usageText names every harvest-reserved define (RFC-0003 round-3 review " &
       "R3-2, re-fixed round-4 R4-2)":
    ## The reserved-define refusal (`extraFlagSetsDefine`/
    ## `rejectReservedDefineOverrides` in harvester.nim) is new user-visible
    ## exit-3 behavior for `--extra-flag`; this pins that `usageText`
    ## actually names every define it refuses, so a future addition to
    ## harvester.nim's reserved-define lists doesn't silently fall out of
    ## sync with the doc surface a user actually reads.
    ##
    ## Round-4 review R4-2: the round-3 version of this test hardcoded the
    ## 5 names as a literal, citing the sibling "pinned-literal" test above
    ## (`defaultDiagnosticsPinFlags`'s contents) as precedent — but that
    ## precedent doesn't apply here: THIS test's purpose is a sync check
    ## between two independent surfaces (harvester.nim's reserved-define
    ## list and usageText's prose), which is exactly the shape the M5 test
    ## immediately above already solved by deriving from source instead of
    ## hardcoding. A 6th reserved define would have silently passed this
    ## test 5-of-6 forever; now `harvester.harvestReservedDefines` (exported
    ## for exactly this purpose) is the single source of truth, and adding
    ## a 6th reserved define there without documenting it in `usageText`
    ## fails this test immediately, the same way M5 already covers a 3rd
    ## default extra flag.
    for name in harvestReservedDefines:
      check name in usageText

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
    check r.config.extraFlags == @["--passC:-Werror=implicit-function-declaration",
                                   "--passC:-Werror=incompatible-pointer-types"]
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
    check r.config.extraFlags == @["--passC:-Werror=implicit-function-declaration",
                                   "--passC:-Werror=incompatible-pointer-types",
                                   "--cc:vcc", "--foo"]

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
