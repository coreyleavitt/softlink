## `softlink harvest` — RFC-0001 SS4 B.2/B.3 slice **B3**: the harvester
## classification loop.
##
## Library-style module (the CLI wrapper is B8's separate nimble package —
## see the RFC's packaging note). Two concerns are kept deliberately
## separate, per the PhD-CS testability bar:
##
## - **Decision** (`classify`): a pure function over already-observed
##   compile outcomes → `FactKind`. No I/O, unit-testable for every row of
##   RFC-0001's classification table, including the row a real toolchain
##   can't cheaply reach (a verify-stage failure that is NOT softlink's own
##   assert message).
## - **I/O** (`compileProbe`, `runCalibration`, `harvest`): spawns real
##   `nim c --noLinking` subprocesses (via `std/osproc.startProcess`, never
##   a shell string, so no quoting hazards) against the fixture corpus (or,
##   for calibration, a self-contained runtime-generated fixture) and feeds
##   the structural pass/fail of each compile into `classify`.
##
## Probing = recompiling the user's REAL binding module (located via a B.1
## `-d:softlinkDumpProbes=<dir>` dump) under the harvest-only probe defines
## the macro already understands (`softlinkProbeOnly`/`softlinkProbeExistence`,
## slice B2) — this module never re-derives or re-parses a binding, it only
## drives the compiler against the one that already exists.
import std/[os, osproc, json, oids, strutils, tables, algorithm, streams]
import softlink/versions

export FactKind

type
  HarvestError* = object of CatchableError
    ## Ordinary, expected failure (bad dump/corpus, `findExe("nim")` came up
    ## empty, ...) — not a defect in the harvester itself.
  CalibrationRefusedError* = object of HarvestError
    ## Raised by `harvest` when the calibration preflight does not observe
    ## the expected known-answer trio. Carries a human-readable toolchain
    ## diagnosis as its `msg`. No probing of the real corpus/module happens
    ## when this is raised — "no harvest performed" per RFC-0001 SS4 B.2.

  ProbeFact* = object
    ## One proc's pragma facts, as recorded by a B.1 probe-facts dump.
    ## Field shape mirrors `probeFactsJson` in src/softlink.nim exactly
    ## (both sides of this schema must never drift independently).
    nimName*, cName*: string
    header*, prototype*, verifyWhen*, noverifyReason*, since*: string
    optional*, noverify*: bool

  ProbeDump* = object
    ## One `<Base>.probes.json` file (RFC-0001 SS4 B.1), parsed.
    schemaVersion*: int
    kind*, modulePath*, libPattern*, baseName*: string
    procs*: seq[ProbeFact]

  ProbeOutcomes* = object
    ## The structural pass/fail of up to three real compiles for one
    ## `(version, symbol)` pair. Fields past the first failing stage are
    ## meaningless and never read by `classify` — see its doc comment.
    baselineOk*: bool
    existenceOk*: bool
    verifyOk*: bool
    assertMsgSeen*: bool
      ## Only meaningful when `verifyOk == false`: did softlink's own fixed
      ## assert-failure text appear in the verify compile's output?

  SkipNote* = object
    ## A proc the harvester never probed, and why. RFC-0001 SS4 B.2: a
    ## `{.prototype.}`-only proc (no `{.header.}`) verifies against a
    ## corpus-INVARIANT vendored declaration, so there is nothing
    ## version-shaped to record.
    cname*, reason*: string

  HarvestResult* = object
    baseName*, modulePath*: string
    versions*: seq[string]
      ## Corpus versions, ordered via `softlink/versions.cmpVersion`.
    probedSymbols*: seq[string]
      ## C names actually probed, in the dump's own declaration order —
      ## the stable order `facts`/reports iterate over (Nim `Table`
      ## iteration order is an implementation detail, not a contract).
    baselineOk*: Table[string, bool]
      ## version -> did the baseline (`softlinkProbeOnly=-`) compile succeed.
    facts*: Table[string, Table[string, FactKind]]
      ## cName -> version -> classification.
    skipped*: seq[SkipNote]
    report*: string
      ## Human-readable summary. Tests should assert primarily on the
      ## structured fields above; this is for a human running the CLI.

  HarvestOptions* = object
    nimPaths*: seq[string]
      ## `--path:` entries the probed module (and any calibration fixture)
      ## needs to resolve its own imports (e.g. `@["src"]` for `import
      ## softlink` during development; B8's packaged CLI sets this from the
      ## installed package).
    extraFlags*: seq[string]
      ## Additional raw `nim c` command-line flags applied to EVERY probe
      ## compile, unmodified (e.g. the implicit-declaration-as-error flag,
      ## or `--cc:vcc` to target MSVC). Fully caller-controlled — the
      ## harvester does not reinvent compiler selection (RFC-0001 SS4 B.2).
    includeFlagPrefix*: string
      ## How to spell "add an include directory" for the target C
      ## toolchain: `"-I"` (gcc/clang, the default) or `"/I"` (MSVC).
    scratchDir*: string
      ## Base directory for unique per-invocation nimcaches and any
      ## runtime-generated calibration fixture.

  CalibrationOutcome* = object
    ok*: bool
    diagnosis*: string
      ## Empty when `ok`; otherwise a toolchain diagnosis explaining what
      ## deviated and why that matters (never parsed by callers — for
      ## humans and test assertions on substrings only).
    observed*: Table[string, FactKind]
      ## calibration symbol -> what the pipeline actually classified it as.

const
  assertMismatchNeedle* = "signature mismatch"
    ## The ONLY text softlink's own diagnostics are ever matched against
    ## (RFC-0001 SS4 B.2) — confirmation on an already-structurally-
    ## determined `mismatch`, never a substitute for the structural
    ## baseline/existence/verify decision. Must stay byte-for-byte in sync
    ## with the `errMsg` built in `genVerifyBlock` (src/softlink.nim):
    ## `"softlink: " & p.nameStr & " signature mismatch vs " & declSource`.

  calibVerifiedSym = "calib_verified"
  calibAbsentSym = "calib_absent"
  calibMismatchedSym = "calib_mismatched"

func defaultHarvestOptions*(): HarvestOptions =
  ## gcc/clang-tuned defaults — the slice's required minimum leg. Callers
  ## targeting another toolchain (MSVC) override `extraFlags`/
  ## `includeFlagPrefix` explicitly; nothing here is auto-detected.
  HarvestOptions(
    nimPaths: @["src"],
    extraFlags: @["--passC:-Werror=implicit-function-declaration"],
    includeFlagPrefix: "-I",
    scratchDir: getTempDir(),
  )

# ---------------------------------------------------------------------------
# Pure decision logic
# ---------------------------------------------------------------------------

func classify*(o: ProbeOutcomes): FactKind =
  ## RFC-0001 SS4 B.2's classification table, verbatim:
  ##
  ## | baseline | existence | verify | classification |
  ## |---|---|---|---|
  ## | fail | -  | -  | `fkUnknown` (this version's headers broken/missing) |
  ## | ok   | fail | - | `fkAbsent` |
  ## | ok   | ok | ok  | `fkVerified` |
  ## | ok   | ok | fail, assert msg seen | `fkMismatch` |
  ## | ok   | ok | fail, NO assert msg   | `fkUnknown` (round-2 fix: a verify
  ##   failure for some other reason is not a signature mismatch) |
  ##
  ## Fields of `o` past the first failing stage are never read — this
  ## function does not require its caller to have run later stages at all
  ## (the I/O layer indeed skips them, `harvest`'s "up to three compiles" is
  ## an upper bound).
  if not o.baselineOk: return fkUnknown
  if not o.existenceOk: return fkAbsent
  if o.verifyOk: return fkVerified
  if o.assertMsgSeen: return fkMismatch
  fkUnknown

# ---------------------------------------------------------------------------
# B.1 dump parsing
# ---------------------------------------------------------------------------

proc loadDump*(dumpFile: string): ProbeDump =
  ## Parse one `<Base>.probes.json` file (RFC-0001 SS4 B.1 schema; see
  ## `validateProbeJson` in softlink.nimble for the schema this mirrors).
  if not fileExists(dumpFile):
    raise newException(HarvestError,
      "softlink harvest: probe-facts dump not found: " & dumpFile)
  let j = parseJson(readFile(dumpFile))
  result.schemaVersion = j["schemaVersion"].getInt
  result.kind = j["kind"].getStr
  result.modulePath = j["modulePath"].getStr
  result.libPattern = j["libPattern"].getStr
  result.baseName = j["baseName"].getStr
  for p in j["procs"]:
    result.procs.add ProbeFact(
      nimName: p["nimName"].getStr,
      cName: p["cName"].getStr,
      header: p["header"].getStr,
      prototype: p["prototype"].getStr,
      verifyWhen: p["verifyWhen"].getStr,
      optional: p["optional"].getBool,
      noverify: p["noverify"].getBool,
      noverifyReason: p["noverifyReason"].getStr,
      since: p["since"].getStr,
    )

# ---------------------------------------------------------------------------
# Corpus enumeration
# ---------------------------------------------------------------------------

proc enumerateCorpusVersions*(corpusDir: string): seq[string] =
  ## Version directories on disk, ordered via `softlink/versions.cmpVersion`
  ## (never lexical/mtime order — see B0's "4.9.0" < "4.10.0" property).
  ## Cross-validates against a sibling `corpus.json`'s `"corpus"` array when
  ## one exists (same symmetric disk<->manifest check `runCorpusChecks` in
  ## softlink.nimble already proves for the fixture corpus) — a manifest
  ## naming a version absent from disk, or a disk version the manifest
  ## never heard of, is a corpus authoring bug, not silently ignored.
  var disk: seq[string] = @[]
  for kind, path in walkDir(corpusDir):
    if kind == pcDir:
      disk.add(extractFilename(path))

  let manifestPath = corpusDir / "corpus.json"
  if fileExists(manifestPath):
    let j = parseJson(readFile(manifestPath))
    if j.hasKey("corpus"):
      var manifestVersions: seq[string] = @[]
      for entry in j["corpus"]:
        manifestVersions.add(entry["version"].getStr)
      for v in manifestVersions:
        if v notin disk:
          raise newException(HarvestError,
            "softlink harvest: " & manifestPath & " names version '" & v &
            "' but " & (corpusDir / v) & " does not exist on disk")
      for v in disk:
        if v notin manifestVersions:
          raise newException(HarvestError,
            "softlink harvest: " & (corpusDir / v) &
            "/ exists on disk but " & manifestPath & " has no entry for it")

  disk.sort(cmpVersion)
  disk

# ---------------------------------------------------------------------------
# I/O: real `nim c` probe compiles
# ---------------------------------------------------------------------------

type
  CompileOutcome = object
    exitCode: int
    output: string

proc findNimExe(): string =
  result = findExe("nim")
  if result.len == 0:
    raise newException(HarvestError,
      "softlink harvest: 'nim' not found on PATH (findExe) — cannot probe. " &
      "The harvester locates the toolchain the same way the rest of this " &
      "project does (Docker dev image / choosenim CI both provide it), " &
      "never a hardcoded path.")

proc freshDir(base: string): string =
  ## A unique-per-invocation directory under `base`, created on demand.
  ## Uses `std/oids.genOid` (a globally-unique 12-byte id), not a counter —
  ## parallel-safe by construction even though this slice's loop runs
  ## serially (RFC-0001 SS4 B.2: "the unique nimcache is what makes
  ## per-symbol probing genuinely embarrassingly parallel").
  result = base / ("sl_harvest_" & $genOid())
  createDir(result)

proc runProcess(exe: string, args: seq[string]): tuple[output: string, exitCode: int] =
  ## `startProcess` with explicit `args` (never a shell command string) —
  ## no quoting hazards for paths/defines containing spaces or shell
  ## metacharacters. stderr is merged into stdout so the assert-message
  ## confirmation (`assertMismatchNeedle`) can see compiler diagnostics
  ## regardless of which stream the toolchain wrote them to.
  var p = startProcess(exe, args = args, options = {poStdErrToStdOut, poUsePath})
  try:
    let output = p.outputStream.readAll()
    let code = p.waitForExit()
    (output, code)
  finally:
    p.close()

proc compileProbe(nimExe, modulePath, nimcacheRoot: string, opts: HarvestOptions,
                   includeDirs, defines: seq[string]): CompileOutcome =
  ## One `nim c --noLinking --nimcache:<unique> <modulePath>` invocation,
  ## with `includeDirs` prepended via the toolchain's include-dir flag and
  ## `defines` passed as `-d:...` (Nim-level, so this is toolchain-
  ## independent). This is the ONE place that shells out to the real
  ## compiler; `classify` never sees a subprocess. `nimcacheRoot` is the
  ## CALLER's single per-harvest/per-calibration scratch root (see
  ## `harvest`/`runCalibration`) — every nimcache this proc creates nests
  ## under it, so one `removeDir` at the end of the top-level call cleans
  ## up every probe compile's build products, not just the caller's own
  ## fixture files.
  var args = @["c", "--noLinking", "--nimcache:" & freshDir(nimcacheRoot)]
  for p in opts.nimPaths:
    args.add("--path:" & p)
  for d in includeDirs:
    args.add("--passC:" & opts.includeFlagPrefix & d)
  for d in defines:
    args.add("-d:" & d)
  args.add(opts.extraFlags)
  args.add(modulePath)
  let (output, code) = runProcess(nimExe, args)
  CompileOutcome(exitCode: code, output: output)

proc probeOutcomes(nimExe, modulePath, versionDir, cName, nimcacheRoot: string,
                    opts: HarvestOptions): ProbeOutcomes =
  ## Runs the existence + (conditionally) verify compiles for one already-
  ## baseline-ok `(version, symbol)` pair — the two of the "up to three"
  ## compiles that are genuinely per-symbol (baseline is cached once per
  ## version by the caller, `harvest`, per RFC-0001 SS4 B.2 design guidance:
  ## it is symbol-independent by construction).
  result.baselineOk = true
  let existence = compileProbe(nimExe, modulePath, nimcacheRoot, opts, @[versionDir],
    @["softlinkProbeOnly=" & cName, "softlinkProbeExistence"])
  result.existenceOk = existence.exitCode == 0
  if not result.existenceOk:
    return
  let verify = compileProbe(nimExe, modulePath, nimcacheRoot, opts, @[versionDir],
    @["softlinkProbeOnly=" & cName])
  result.verifyOk = verify.exitCode == 0
  if not result.verifyOk:
    result.assertMsgSeen = assertMismatchNeedle in verify.output

# ---------------------------------------------------------------------------
# Calibration preflight
# ---------------------------------------------------------------------------

proc writeCalibrationFixture(dir: string) =
  ## A tiny, self-contained known-answer trio, generated at runtime (not
  ## checked in) so the harvester works standalone after B8's packaging —
  ## see RFC-0001 SS4 B.2 design guidance point 3. One header pins two real
  ## declarations; the binding module pins THREE procs against it:
  ## - `calib_verified` — signature matches exactly -> expect `fkVerified`.
  ## - `calib_absent`   — the header never declares it at all -> `fkAbsent`.
  ## - `calib_mismatched` — declared `int(int,int)`, bound as `cdouble` ->
  ##   `fkMismatch`.
  writeFile(dir / "calib.h", """
#ifndef SOFTLINK_HARVEST_CALIB_H
#define SOFTLINK_HARVEST_CALIB_H
int calib_verified(int a, int b);
int calib_mismatched(int a, int b);
#endif
""")
  writeFile(dir / "calib_binding.nim", """
import softlink

dynlib "libsoftlinkharvestcalib.so":
  proc calib_verified(a: cint, b: cint): cint {.cdecl, header: "calib.h".}
  proc calib_absent(a: cint): cint {.cdecl, header: "calib.h".}
  proc calib_mismatched(a: cint, b: cint): cdouble {.cdecl, header: "calib.h".}
""")

proc runCalibration*(opts: HarvestOptions = defaultHarvestOptions()): CalibrationOutcome =
  ## RFC-0001 SS4 B.2 calibration preflight: runs the known-verified/known-
  ## absent/known-mismatched trio through the IDENTICAL pipeline `harvest`
  ## uses and requires exactly the expected three classifications. This is
  ## the structural guard against a degraded verification tier (default-
  ## mode MSVC's graceful no-op fallback silently makes EVERY probe
  ## trivially succeed, poisoning results with false `verified`) or a
  ## warning-only implicit-declaration configuration.
  let nimExe = findNimExe()
  # One scratch root for BOTH the fixture files and every nimcache this
  # preflight's compiles create — a single `defer: removeDir` at the end
  # cleans up everything this call touched, not merely the fixture files
  # (see `compileProbe`'s `nimcacheRoot` doc comment).
  let scratch = freshDir(opts.scratchDir)
  defer: removeDir(scratch)
  writeCalibrationFixture(scratch)
  let modulePath = scratch / "calib_binding.nim"

  let baseline = compileProbe(nimExe, modulePath, scratch, opts, @[scratch], @["softlinkProbeOnly=-"])
  if baseline.exitCode != 0:
    return CalibrationOutcome(ok: false, diagnosis:
      "softlink harvest calibration: the BASELINE compile of the built-in " &
      "calibration fixture failed — this toolchain cannot even compile a " &
      "trivial header-including module (no verification defines active " &
      "yet). Something is wrong with the toolchain/PATH itself, not with " &
      "verification. Compiler output:\n" & baseline.output)

  let expected = {
    calibVerifiedSym: fkVerified,
    calibAbsentSym: fkAbsent,
    calibMismatchedSym: fkMismatch,
  }.toTable

  var observed = initTable[string, FactKind]()
  for sym in [calibVerifiedSym, calibAbsentSym, calibMismatchedSym]:
    let o = probeOutcomes(nimExe, modulePath, scratch, sym, scratch, opts)
    observed[sym] = classify(o)

  var deviations: seq[string] = @[]
  for sym, want in expected:
    if observed[sym] != want:
      deviations.add(sym & ": expected " & $want & ", observed " & $observed[sym])

  if deviations.len > 0:
    return CalibrationOutcome(ok: false, observed: observed, diagnosis:
      "softlink harvest calibration FAILED — this toolchain's verification " &
      "tier does not classify the built-in known-answer fixture correctly, " &
      "so NO HARVEST was performed (RFC-0001 SS4 B.2 calibration preflight). " &
      "This is the guard against a degraded compile mode silently poisoning " &
      "a harvest with false facts: MSVC without /std:clatest (the C23 gate) " &
      "no-ops BOTH the existence reference and the verify assert — every " &
      "probe compiles unconditionally regardless of the actual header " &
      "content, which turns a genuinely-mismatched or genuinely-absent " &
      "symbol into a false `verified` — or a compiler/flag combination that " &
      "treats an undeclared-symbol reference as a warning instead of a hard " &
      "error. Deviations from the expected calibration answer: " &
      deviations.join("; "))

  CalibrationOutcome(ok: true, observed: observed)

# ---------------------------------------------------------------------------
# Harvest orchestration
# ---------------------------------------------------------------------------

proc renderReport(r: HarvestResult): string =
  var lines: seq[string] = @[
    "softlink harvest: " & r.baseName & " (" & r.modulePath & ")"]
  for v in r.versions:
    let tag = if r.baselineOk.getOrDefault(v, false): "baseline OK"
              else: "baseline FAILED — headers broken/missing for this " &
                    "version (every symbol classifies unknown)"
    lines.add("  " & v & ": " & tag)
  for cname in r.probedSymbols:
    var perVersion: seq[string] = @[]
    for v in r.versions:
      perVersion.add(v & "=" & $r.facts[cname][v])
    lines.add("  " & cname & ": " & perVersion.join(", "))
  for s in r.skipped:
    lines.add("  SKIPPED " & s.cname & ": " & s.reason)
  lines.join("\n")

proc harvest*(dumpFile, corpusDir: string,
              opts: HarvestOptions = defaultHarvestOptions()): HarvestResult =
  ## RFC-0001 SS4 B.2/B.3 top-level entry point. Runs the calibration
  ## preflight FIRST — a toothless toolchain raises `CalibrationRefusedError`
  ## before a single real-corpus compile happens, per the RFC's "no harvest
  ## is performed" contract. `prototype`-only procs (no `header`) are
  ## corpus-invariant and are skipped (noted in `result.skipped`), never
  ## probed — see `writeCalibrationFixture`'s sibling doc comment on
  ## `genVerifyBlock` in src/softlink.nim for why a `{.noverify.}` proc is
  ## skipped for the identical structural reason: `genVerifyBlock` excludes
  ## both from its own `procs` filter, so no verification apparatus is EVER
  ## emitted for them regardless of which probe mode is active — probing
  ## either would just observe "nothing emitted, so it trivially compiles"
  ## at every version, a false `verified` by construction, not a real fact.
  let calibration = runCalibration(opts)
  if not calibration.ok:
    raise newException(CalibrationRefusedError, calibration.diagnosis)

  let nimExe = findNimExe()
  let dump = loadDump(dumpFile)
  result.baseName = dump.baseName
  result.modulePath = dump.modulePath
  result.versions = enumerateCorpusVersions(corpusDir)

  # One scratch root for every nimcache this harvest's compiles create,
  # cleaned up in one shot when the call returns (see `compileProbe`'s
  # `nimcacheRoot` doc comment) — mirrors `runCalibration`'s own scratch
  # root, just without fixture files (the module being probed is the
  # caller's real one, already on disk).
  let scratchRoot = freshDir(opts.scratchDir)
  defer: removeDir(scratchRoot)

  var probeTargets: seq[ProbeFact] = @[]
  for p in dump.procs:
    if p.noverify:
      result.skipped.add SkipNote(cname: p.cName,
        reason: "noverify — excluded from header verification entirely, " &
                "nothing to probe")
    elif p.header.len == 0 and p.prototype.len > 0:
      result.skipped.add SkipNote(cname: p.cName,
        reason: "prototype-only (no header) — corpus-invariant, skipped")
    elif p.header.len == 0:
      result.skipped.add SkipNote(cname: p.cName,
        reason: "no header or prototype recorded — nothing to probe")
    else:
      probeTargets.add(p)
      result.probedSymbols.add(p.cName)

  for v in result.versions:
    let versionDir = corpusDir / v
    let baseline = compileProbe(nimExe, dump.modulePath, scratchRoot, opts,
      @[versionDir], @["softlinkProbeOnly=-"])
    let baselineOk = baseline.exitCode == 0
    result.baselineOk[v] = baselineOk
    for p in probeTargets:
      var facts = result.facts.getOrDefault(p.cName)
      if not baselineOk:
        facts[v] = fkUnknown
      else:
        let o = probeOutcomes(nimExe, dump.modulePath, versionDir, p.cName,
          scratchRoot, opts)
        facts[v] = classify(o)
      result.facts[p.cName] = facts

  result.report = renderReport(result)

when isMainModule:
  ## Thin entry point for the tests (full CLI UX is B8's). Usage:
  ##   harvester <dumpFile> <corpusDir> [nimPath ...]
  let args = commandLineParams()
  if args.len < 2:
    stderr.writeLine("usage: harvester <dumpFile> <corpusDir> [nimPath ...]")
    quit(1)
  var opts = defaultHarvestOptions()
  if args.len > 2:
    opts.nimPaths = args[2 .. ^1]
  try:
    let r = harvest(args[0], args[1], opts)
    echo r.report
  except CalibrationRefusedError as e:
    stderr.writeLine("softlink harvest: REFUSED — calibration preflight failed:\n" & e.msg)
    quit(1)
  except HarvestError as e:
    stderr.writeLine("softlink harvest: " & e.msg)
    quit(1)
