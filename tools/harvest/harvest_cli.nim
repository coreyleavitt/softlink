## `softlink_harvest` — RFC-0001 SS4 B.8: the packaged CLI's flag surface.
##
## Same decision/IO split this tool follows everywhere else (see
## `harvester.nim`'s own module doc comment): `parseHarvestCli` is a PURE
## function, `seq[string] -> CliParseResult`, with zero filesystem/process
## access — so the entire flag surface (defaults, every flag, repeatables,
## malformed input, unknown flags) is unit-tested in `tests/tharvest_cli.nim`
## without a single subprocess. `softlink_harvest.nim` (the actual `bin`
## entry point) is the thin I/O layer: it calls `parseHarvestCli`, then
## drives `harvester.nim`'s real `harvest`/`driftAlarm`/`writeManifest`
## accordingly, translating outcomes into this module's exit codes.
import std/[parseopt, strutils]
import softlink/versions

export versions

const
  exitOk* = 0
    ## Manifest written (or `--help` shown), no drift alarm.
  exitDriftAlarm* = 1
    ## RFC-0001 SS4 B.4: at least one `mismatch` inside the (possibly
    ## `--support-range`-narrowed) claimed support range.
  exitCalibrationRefused* = 2
    ## RFC-0001 SS4 B.2 calibration preflight failed — NO manifest written.
  exitUsageError* = 3
    ## Bad flags, missing dump/corpus, malformed manifest inputs — anything
    ## wrong BEFORE a real harvest could even be attempted.

  defaultExtraFlags* = @["--passC:-Werror=implicit-function-declaration"]
    ## Literal copy of `harvester.defaultHarvestOptions()`'s own default
    ## (implicit-function-declaration-as-error — RFC-0001 SS4 B.2's guard
    ## against silently misclassifying `absent` as `verified`). Copied
    ## rather than referenced because `--extra-flag`/`--no-default-flags`
    ## below need to independently APPEND to or REPLACE this exact set;
    ## the two are asserted to match by `tests/tharvest_cli.nim`'s "defaults"
    ## test rather than by a shared symbol, so a future edit to either
    ## default is a visible, deliberate two-line change, not a silent split.

  usageText* = """
softlink_harvest -- RFC-0001 Stage B harvester CLI (compat-manifest generation)

Usage:
  softlink_harvest <dumpFile> <corpusDir> [options]

Positional arguments:
  <dumpFile>   Path to a <Base>.probes.json file produced by compiling a
               binding module with -d:softlinkDumpProbes=<dir>.
  <corpusDir>  Path to the header corpus directory (<corpusDir>/<version>/...).

Options:
  --out:<path>                Manifest output path.
                               (default: <lib>.compat.json next to <dumpFile>)
  --fast-path                  Try a define-free whole-module compile per
                               corpus version first, falling back to
                               bisection for versions that don't settle.
                               Identical facts to the standard path, usually
                               fewer compiles at real-corpus scale.
  --support-range:<lo>..<hi>    Narrow the drift alarm to this half-open
                               version range (either side omissible, e.g.
                               "..2.0.0" or "1.0.0.."). Default: the entire
                               harvested corpus.
  --nim-path:<p>                Extra --path: entry for probe compiles.
                               Repeatable. Default: none (a packaged binding
                               resolves its own deps via its own nimble
                               project; add this only for extras).
  --extra-flag:<f>              Extra raw "nim c" flag for every probe
                               compile. Repeatable; APPENDED to the default
                               (-Werror=implicit-function-declaration)
                               unless --no-default-flags is also given.
  --no-default-flags            Do not apply the built-in default extra
                               flag; only --extra-flag values (if any) are
                               used.
  --include-prefix:<p>          Include-dir flag spelling for the target C
                               toolchain ("-I" for gcc/clang, "/I" for
                               MSVC). Default: -I
  --help                        Show this usage text and exit 0.

Exit codes:
  0   ok -- manifest written, no drift alarm.
  1   drift alarm tripped -- a mismatch inside the support range.
  2   calibration refused -- the toolchain failed the built-in preflight
      trio; NO manifest was written.
  3   usage/input error -- bad flags, missing dump/corpus, malformed
      manifest inputs.
"""

type
  CliConfig* = object
    dumpFile*, corpusDir*, outPath*: string
    fastPath*: bool
    supportRange*: VersionInterval
    nimPaths*, extraFlags*: seq[string]
    includeFlagPrefix*: string
    showHelp*: bool

  CliParseResult* = object
    config*: CliConfig
    error*: string
      ## "" iff parsing succeeded. `config.showHelp` may be set with an
      ## empty error (help short-circuits before positional validation).

func defaultCliConfig*(): CliConfig =
  ## The packaged CLI's own defaults. Note `nimPaths` defaults to EMPTY,
  ## not `harvester.defaultHarvestOptions()`'s dev-only `@["src"]` — that
  ## default exists so THIS REPO's own dump/corpus fixtures (which `import
  ## softlink` from a checkout, not an installed package) resolve without
  ## a flag. A real packaged consumer's binding module resolves `import
  ## softlink` (and its own imports) via its OWN nimble project's already-
  ## installed packages, exactly like any other compile of that module --
  ## no extra `--path:` needed. `--nim-path` exists for the genuine edge
  ## case (a vendored/unusual layout), not as a required default.
  CliConfig(
    nimPaths: @[],
    extraFlags: defaultExtraFlags,
    includeFlagPrefix: "-I",
  )

func parseSupportRange*(s: string): tuple[iv: VersionInterval, ok: bool] =
  ## `<lo>..<hi>`, either side omissible ("..2.0.0", "1.0.0..", or both
  ## bounds present). Splitting on the literal substring ".." is
  ## unambiguous for ordinary version strings (which use single dots) --
  ## `ok == false` (a usage error, per RFC-0001 SS4 B.8) whenever the
  ## input does not split into EXACTLY two parts: zero "..", or more than
  ## one "..pair" (e.g. "1.0..2.0..3.0"), are both rejected rather than
  ## guessed at.
  let parts = s.split("..")
  if parts.len != 2:
    return (VersionInterval(), false)
  (VersionInterval(lo: parts[0], hi: parts[1]), true)

proc parseHarvestCli*(args: seq[string]): CliParseResult =
  ## Pure argv -> `CliParseResult`. No filesystem/process access -- does
  ## NOT check that `dumpFile`/`corpusDir` exist (that is `softlink_harvest.nim`'s
  ## I/O-layer job, mapped to `exitUsageError` there too, per the slice's
  ## "missing dump/corpus...are usage errors" instruction) -- this function
  ## only validates the SHAPE of the argv itself.
  var cfg = defaultCliConfig()
  var positional: seq[string] = @[]
  var extraFlagsGiven: seq[string] = @[]
  var noDefaultFlags = false

  var p = initOptParser(args,
    longNoVal = @["fast-path", "no-default-flags", "help"])
  for kind, key, val in p.getopt():
    case kind
    of cmdArgument:
      positional.add key
    of cmdLongOption, cmdShortOption:
      case key
      of "help":
        cfg.showHelp = true
        return CliParseResult(config: cfg)
      of "fast-path":
        cfg.fastPath = true
      of "no-default-flags":
        noDefaultFlags = true
      of "out":
        cfg.outPath = val
      of "support-range":
        let (iv, ok) = parseSupportRange(val)
        if not ok:
          return CliParseResult(error:
            "softlink_harvest: malformed --support-range (expected " &
            "<lo>..<hi>, either side omissible): '" & val & "'")
        cfg.supportRange = iv
      of "nim-path":
        cfg.nimPaths.add val
      of "extra-flag":
        extraFlagsGiven.add val
      of "include-prefix":
        cfg.includeFlagPrefix = val
      else:
        return CliParseResult(error:
          "softlink_harvest: unknown flag: --" & key)
    of cmdEnd:
      discard

  cfg.extraFlags = (if noDefaultFlags: newSeq[string]() else: defaultExtraFlags) &
    extraFlagsGiven

  if positional.len < 2:
    return CliParseResult(error:
      "softlink_harvest: expected <dumpFile> <corpusDir>, got " &
      $positional.len & " positional argument(s)")
  if positional.len > 2:
    return CliParseResult(error:
      "softlink_harvest: too many positional arguments (expected exactly " &
      "<dumpFile> <corpusDir>): " & positional.join(" "))

  cfg.dumpFile = positional[0]
  cfg.corpusDir = positional[1]
  CliParseResult(config: cfg)
