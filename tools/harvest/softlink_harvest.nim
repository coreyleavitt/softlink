## `softlink_harvest` -- RFC-0001 SS4 B.8: the packaged CLI's `bin` entry
## point. Thin I/O layer: parses argv via `harvest_cli.parseHarvestCli`
## (pure, unit-tested in `tests/tharvest_cli.nim`), validates the
## dump/corpus paths actually exist (the ONE filesystem check this module
## performs before handing off), builds a real `harvester.HarvestOptions`
## from the parsed `CliConfig`, and drives `harvester.harvest` /
## `driftAlarm` / `writeManifest`, translating outcomes into this module's
## four documented exit codes (`harvest_cli.exitOk` / `exitDriftAlarm` /
## `exitCalibrationRefused` / `exitUsageError`).
##
## `tools/harvest/harvester.nim`'s own `when isMainModule` shim (positional-
## only, no flags) remains as-is for quick dev-loop use directly against
## this repo's checkout (see its own doc comment); this module is the real
## packaged interface (`bin = @["softlink_harvest"]` in
## `softlink_harvest.nimble`) a binding author actually installs and runs.
import std/[os, strutils]
import harvest_cli
import harvester

proc fail(msg: string): int =
  stderr.writeLine("softlink_harvest: " & msg)
  exitUsageError

proc run(args: seq[string]): int =
  let parsed = parseHarvestCli(args)
  if parsed.config.showHelp:
    echo usageText
    return exitOk
  if parsed.error.len > 0:
    stderr.writeLine(parsed.error)
    stderr.writeLine("")
    stderr.writeLine(usageText)
    return exitUsageError

  let cfg = parsed.config
  if not fileExists(cfg.dumpFile):
    return fail("dump file not found: " & cfg.dumpFile)
  if not dirExists(cfg.corpusDir):
    return fail("corpus directory not found: " & cfg.corpusDir)

  var opts = defaultHarvestOptions()
  opts.nimPaths = cfg.nimPaths
  opts.extraFlags = cfg.extraFlags
  opts.includeFlagPrefix = cfg.includeFlagPrefix
  opts.fastPath = cfg.fastPath

  try:
    let r = harvest(cfg.dumpFile, cfg.corpusDir, opts)
    echo r.report

    let corpus = loadCorpusProvenance(cfg.corpusDir)
    let manifest = buildManifest(r, corpus, defaultHarvestMeta())
    let manifestPath =
      if cfg.outPath.len > 0: cfg.outPath
      else: cfg.dumpFile.parentDir / (r.baseName.toLowerAscii() & ".compat.json")
    writeManifest(manifestPath, manifest)
    echo "softlink_harvest: wrote " & manifestPath

    let (tripped, diagnosis) = driftAlarm(r, cfg.supportRange)
    if tripped:
      stderr.writeLine(diagnosis)
      return exitDriftAlarm
    exitOk
  except CalibrationRefusedError as e:
    stderr.writeLine("softlink_harvest: REFUSED -- calibration preflight failed:\n" & e.msg)
    exitCalibrationRefused
  except HarvestError as e:
    stderr.writeLine("softlink_harvest: " & e.msg)
    exitUsageError

when isMainModule:
  quit(run(commandLineParams()))
