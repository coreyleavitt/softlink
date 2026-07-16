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
import std/[os, osproc, json, oids, strutils, tables, algorithm, streams, times,
            sequtils, monotimes]
import softlink/versions

export FactKind, abiTag

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
    compileCount*: int
      ## RFC-0001 SS4 B.2, optional fast-path (slice B7): incremented once
      ## per real `compileProbe` invocation made while producing THIS
      ## `HarvestResult` — the headline "fewer compiles" property the fast
      ## path exists to deliver is measured by comparing this field across
      ## two `harvest()` calls (`opts.fastPath = false` vs `true`) against
      ## the SAME dump/corpus (see `tests/tharvest.nim`). The calibration
      ## preflight's own compiles (`runCalibration`, called once at the top
      ## of `harvest`) are DELIBERATELY EXCLUDED — calibration is a fixed,
      ## mode-independent cost paid identically regardless of `fastPath`,
      ## so folding it in would only dilute the comparison this field
      ## exists to enable. Every compile the CORPUS harvest itself performs
      ## — baseline, define-free, bisection group, and standard-pipeline
      ## existence/verify — is counted, in both the standard and fast-path
      ## loops (see `harvest`'s doc comment for the full accounting).

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
    fastPath*: bool
      ## RFC-0001 SS4 B.2, optional (slice B7): when true, `harvest` tries
      ## a plain, define-free compile of the module per corpus version
      ## FIRST, falling back to the standard baseline/bisection/per-symbol
      ## pipeline only where that shortcut doesn't immediately settle the
      ## question. Pure optimization — `harvest`'s `facts` are IDENTICAL
      ## whether this is `false` (default) or `true`; see `harvest`'s own
      ## doc comment for the full algorithm and soundness argument. Default
      ## `false`: this is opt-in, never a silent behavior change for an
      ## existing caller.
    compileTimeoutMs*: int
      ## Code-review finding F6: the wall-clock budget (milliseconds) given
      ## to ONE `runProcess` subprocess invocation (one probe compile).
      ## `defaultHarvestOptions` sets this to a generous 300_000 (5 minutes)
      ## — real probe compiles take seconds; this only exists to turn a
      ## genuinely-hung compiler process into a clear `HarvestError` instead
      ## of a harvest that never returns. A caller building a custom
      ## `HarvestOptions` literal (rather than starting from
      ## `defaultHarvestOptions()`) must set this explicitly — see
      ## `tests/tharvest_msvc_calibration_refusal.nim`'s `msvcDefaultOpts`
      ## for the pattern.
    maxOutputBytes*: int
      ## Code-review finding F6: the accumulated-output cap (bytes) for ONE
      ## `runProcess` invocation — a runaway/misbehaving compiler process
      ## dumping unbounded diagnostics must not be read into memory without
      ## limit. `defaultHarvestOptions` sets this to 16 MiB, comfortably
      ## above any real compiler diagnostic output this harvester expects to
      ## see.

  HarvestMeta* = object
    ## The `<lib>.compat.json` manifest's `"harvest"` object (RFC-0001 SS4
    ## B.3, round-2 additions) — explicit and caller-injectable (design
    ## guidance point 3) rather than computed inline in `buildManifest`, so
    ## a golden-fixture test can PIN it and get a byte-for-byte-stable
    ## comparison regardless of which machine or day a harvest runs on.
    ## `defaultHarvestMeta` supplies best-effort real-use values; nothing
    ## here is auto-detected when a caller supplies its own `HarvestMeta`.
    toolchain*: string  ## e.g. first line of `gcc --version` (best-effort).
    tier*: string        ## Verification tier, e.g. "builtin-compat" (the
                          ## `__builtin_types_compatible_p` tier — the RFC's
                          ## own example value for the gcc/`nim c` pipeline).
    abi*: string          ## Normalized OS + data-model tag, see `abiTag`.
    date*: string         ## `yyyy-MM-dd`, best-effort "today".

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
    compileTimeoutMs: 300_000,
    maxOutputBytes: 16_777_216,
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

type
  BisectPlan* = object
    ## The result of `bisectPlan`'s recursive divide-and-conquer over a
    ## symbol list, using nothing but an opaque pass/fail oracle. Every
    ## input symbol lands in EXACTLY ONE of these two seqs — see
    ## `bisectPlan`'s own doc comment for why that's structural, not merely
    ## tested.
    verified*: seq[string]
      ## Symbols a passing group compile already proved `fkVerified` at —
      ## no further compile is ever needed for them.
    needsStandard*: seq[string]
      ## Symbols whose bisection bottomed out at a failing SINGLETON — the
      ## only case that needs the standard three-probe pipeline
      ## (`probeOutcomes`/`classify`) to actually tell `fkAbsent` from
      ## `fkMismatch` from `fkUnknown`.

proc bisectPlan*(symbols: seq[string],
                  groupPasses: proc(group: seq[string]): bool {.closure.}
                  ): BisectPlan =
  ## (`proc`, not `func`: `groupPasses` is a caller-supplied closure that,
  ## in real use, performs I/O — a `func`'s effect system would need it
  ## marked `{.noSideEffect.}`, which would be a lie. `bisectPlan` itself
  ## still performs no I/O of its own; see the architectural note in the
  ## module doc comment.)
  ## RFC-0001 SS4 B.2's optional fast-path (slice B7), the bisection step in
  ## pure isolation: given a symbol list and an opaque "does a compile of
  ## THIS group pass?" callback, partitions the list into `verified` (a
  ## compile naming exactly this group's symbols succeeded) and
  ## `needsStandard` (bisection bottomed out at a failing singleton — the
  ## ONLY place the standard pipeline is ever needed). No I/O of its own —
  ## `harvest` supplies the real callback, a `compileProbe` call with
  ## `softlinkProbeOnly=<comma-joined group>` in verify mode; this function
  ## is unit-tested (`tests/tharvest.nim`) entirely with synthetic
  ## callbacks (all-pass, one-fail, all-fail, two-fail-in-different-halves,
  ## odd-sized groups, singleton input) precisely because it has no I/O.
  ##
  ## Soundness (the RFC's own argument): per-symbol `_Static_assert`s are
  ## independent statements in the verify TU, so a passing group compile
  ## really does mean EVERY symbol in that group individually verifies —
  ## there is no way for one symbol's assert to pass only in the "wrong"
  ## company of others. A failing group means AT LEAST ONE symbol in it
  ## doesn't verify, but — per RFC-0001 SS4 B.2's "no textual attribution
  ## ever" — WHICH one is never read off the compiler's output; recursing
  ## into halves is the only way this module ever learns that, and a
  ## failing singleton is the base case where "at least one" becomes
  ## "this one".
  ##
  ## Structurally exhaustive/disjoint by construction: `symbols.len == 0`
  ## returns immediately (empty plan, oracle never invoked — there is
  ## nothing to bisect). Otherwise, exactly one of two things happens to
  ## the WHOLE input list at each call: it is fully claimed by `verified`
  ## (the passing branch) or split into two non-overlapping, jointly-
  ## exhaustive halves that are each recursed into independently (the
  ## failing, non-singleton branch) — so every symbol given to the
  ## top-level call ends up in exactly one leaf, and every leaf is either
  ## a passing group (-> `verified`) or a failing singleton
  ## (-> `needsStandard`). A failing singleton with `symbols.len == 1` is
  ## the unconditional base case: it never recurses further (there is no
  ## smaller half to split into), it lands in `needsStandard` directly.
  if symbols.len == 0:
    return
  if groupPasses(symbols):
    result.verified = symbols
    return
  if symbols.len == 1:
    result.needsStandard = symbols
    return
  let mid = symbols.len div 2
  let left = bisectPlan(symbols[0 ..< mid], groupPasses)
  let right = bisectPlan(symbols[mid .. ^1], groupPasses)
  result.verified = left.verified & right.verified
  result.needsStandard = left.needsStandard & right.needsStandard

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
  # Code-review finding F1(a): `cmpVersion`'s digit-run parsing does not
  # preserve leading zeros ("1.09" and "1.9" both parse to the run-sequence
  # @[1, 9]), so two DIFFERENT on-disk directory names can compare EQUAL
  # under the B0 total order. `compressFacts` (this module, below) assumes
  # the corpus' version sequence is STRICTLY increasing when it builds run
  # boundaries — an aliasing pair would silently let one string's facts get
  # attributed to the other. Checking every ADJACENT pair after the sort
  # above catches this in O(n), naming BOTH strings so the fix (rename one
  # on disk, and in corpus.json if present) is unambiguous.
  for i in 1 ..< disk.len:
    if cmpVersion(disk[i - 1], disk[i]) == 0:
      raise newException(HarvestError, "softlink harvest: corpus directory " &
        "names '" & disk[i - 1] & "' and '" & disk[i] & "' compare EQUAL " &
        "under softlink/versions.cmpVersion even though they are different " &
        "strings -- this corpus cannot be harvested safely: interval " &
        "compression (compressFacts) assumes a strictly-increasing version " &
        "sequence and would silently misclassify one of these two " &
        "directories' facts onto the other. Rename one of the two on disk " &
        "(and in corpus.json, if present) to a non-aliasing version string.")
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

type
  ReaderMsgKind = enum rmkChunk, rmkDone, rmkExceeded
  ReaderMsg = object
    case kind: ReaderMsgKind
    of rmkChunk: data: string
    of rmkDone, rmkExceeded: discard

  ReaderArgs = tuple[process: Process, maxOutputBytes: int, chan: ptr Channel[ReaderMsg]]

proc readOutputThread(args: ReaderArgs) {.thread.} =
  ## Code-review finding F6: runs on its own `Thread` so `runProcess`'s main
  ## loop can enforce a wall-clock deadline independently of how long any
  ## single blocking read takes (a read on the child's stdout pipe can
  ## block indefinitely if the child goes silent without exiting — exactly
  ## the hang this finding is about). Reads in bounded 64KiB chunks,
  ## forwarding each over `chan` to the main thread; if the running total
  ## exceeds `maxOutputBytes` this thread itself kills the process (so a
  ## runaway writer stops producing more output) and reports `rmkExceeded`
  ## instead of continuing to read. `Channel` (not a raw shared `ptr
  ## string`) is used deliberately — it is the stdlib's own thread-safe
  ## transfer mechanism for exactly this "send value data from a worker
  ## thread to its owner" shape, avoiding any GC/ownership hazard from
  ## sharing a Nim `string` across threads by hand.
  var buf = newString(65536)
  let outp = args.process.outputStream
  var total = 0
  while true:
    let n = outp.readData(addr buf[0], buf.len)
    if n <= 0:
      break
    total += n
    args.chan[].send(ReaderMsg(kind: rmkChunk, data: buf[0 ..< n]))
    if total > args.maxOutputBytes:
      try:
        if running(args.process): kill(args.process)
      except OSError:
        discard
      args.chan[].send(ReaderMsg(kind: rmkExceeded))
      return
  args.chan[].send(ReaderMsg(kind: rmkDone))

proc runProcess*(exe: string, args: seq[string], timeoutMs, maxOutputBytes: int):
    tuple[output: string, exitCode: int] =
  ## `startProcess` with explicit `args` (never a shell command string) —
  ## no quoting hazards for paths/defines containing spaces or shell
  ## metacharacters. stderr is merged into stdout so the assert-message
  ## confirmation (`assertMismatchNeedle`) can see compiler diagnostics
  ## regardless of which stream the toolchain wrote them to.
  ##
  ## Code-review finding F6: this is the ONE place the harvester shells out
  ## to a real compiler, and it previously had no bound on either wall time
  ## (a hung/slow-to-terminate compile would hang the whole harvest forever)
  ## or accumulated output (`Stream.readAll()` has no size limit — a
  ## misbehaving toolchain dumping unbounded diagnostics could exhaust
  ## memory). Both are now bounded: a background thread
  ## (`readOutputThread`) does the actual (necessarily blocking, per-chunk)
  ## reads and enforces `maxOutputBytes` itself (killing the process and
  ## stopping early if exceeded); this proc's own loop polls for that
  ## thread's progress against a `timeoutMs` deadline and kills the process
  ## if the deadline passes first. Either bound trips -> `HarvestError`,
  ## never a silent truncation and never an indefinite hang. Exported
  ## (`*`) so its bounded-time/bounded-output CONTRACT can be tested
  ## directly (`tests/tharvest.nim`) against real subprocesses (`sleep`,
  ## `yes`), not only observed indirectly through a full `harvest()` run.
  var p = startProcess(exe, args = args, options = {poStdErrToStdOut, poUsePath})
  var chan: Channel[ReaderMsg]
  chan.open()
  var thr: Thread[ReaderArgs]
  createThread(thr, readOutputThread, (p, maxOutputBytes, addr chan))

  var output = ""
  var exceeded = false
  var finished = false
  var timedOut = false
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while not finished:
    let tried = chan.tryRecv()
    if tried.dataAvailable:
      case tried.msg.kind
      of rmkChunk: output.add tried.msg.data
      of rmkDone: finished = true
      of rmkExceeded:
        exceeded = true
        finished = true
    else:
      if not timedOut and getMonoTime() >= deadline:
        timedOut = true
        try:
          if running(p): kill(p)
        except OSError:
          discard
        # Fall through and keep polling: killing the process closes its
        # stdout pipe, so `readOutputThread`'s blocked read returns EOF
        # promptly and it sends `rmkDone` — the loop above still exits via
        # the normal `finished = true` path, just with `timedOut` recorded.
      sleep(5)

  joinThread(thr)
  chan.close()
  let exitCode = waitForExit(p)
  p.close()

  if timedOut:
    raise newException(HarvestError, "softlink harvest: probe compile did " &
      "not finish within " & $timeoutMs & "ms (HarvestOptions." &
      "compileTimeoutMs) and was killed: " & exe & " " & args.join(" "))
  if exceeded:
    raise newException(HarvestError, "softlink harvest: probe compile " &
      "output exceeded " & $maxOutputBytes & " bytes (HarvestOptions." &
      "maxOutputBytes) and was killed: " & exe & " " & args.join(" "))
  (output, exitCode)

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
  let (output, code) = runProcess(nimExe, args, opts.compileTimeoutMs, opts.maxOutputBytes)
  CompileOutcome(exitCode: code, output: output)

proc probeOutcomes(nimExe, modulePath, versionDir, cName, nimcacheRoot: string,
                    opts: HarvestOptions, compileCounter: ptr int = nil): ProbeOutcomes =
  ## Runs the existence + (conditionally) verify compiles for one already-
  ## baseline-ok `(version, symbol)` pair — the two of the "up to three"
  ## compiles that are genuinely per-symbol (baseline is cached once per
  ## version by the caller, `harvest`, per RFC-0001 SS4 B.2 design guidance:
  ## it is symbol-independent by construction). This is THE ONE place
  ## `fkAbsent`/`fkMismatch`/`fkUnknown` are ever distinguished from
  ## `fkVerified` — both the standard per-version loop AND the fast path's
  ## failing-singleton fallback (RFC-0001 SS4 B.2, slice B7) route through
  ## this identical proc, which is what makes their `facts` provably
  ## identical (see `harvest`'s doc comment).
  ##
  ## `compileCounter`, when non-nil, is incremented once per real compile
  ## this call performs (one for the existence probe, a second if it
  ## passed and the verify probe also runs) — `nil` (the default) leaves
  ## compiles uncounted, which is what `runCalibration`'s own calls rely on
  ## (calibration compiles are deliberately excluded from
  ## `HarvestResult.compileCount`, see that field's doc comment).
  result.baselineOk = true
  let existence = compileProbe(nimExe, modulePath, nimcacheRoot, opts, @[versionDir],
    @["softlinkProbeOnly=" & cName, "softlinkProbeExistence"])
  if compileCounter != nil: inc compileCounter[]
  result.existenceOk = existence.exitCode == 0
  if not result.existenceOk:
    return
  let verify = compileProbe(nimExe, modulePath, nimcacheRoot, opts, @[versionDir],
    @["softlinkProbeOnly=" & cName])
  if compileCounter != nil: inc compileCounter[]
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
  ## The calibration preflight's own compiles are NEVER counted toward
  ## `result.compileCount` (see that field's doc comment) — deliberately
  ## NOT fast-pathed either: calibration's whole point is exercising the
  ## standard existence/verify probes' teeth against a known-answer trio
  ## (RFC-0001 SS4 B.2), and `opts.fastPath` only changes how the CORPUS
  ## loop below reaches its per-version conclusions, never this preflight.
  ##
  ## `opts.fastPath` (RFC-0001 SS4 B.2, optional slice B7): per corpus
  ## version, tries a single plain, define-free compile of the module
  ## FIRST. Success is, by construction, the shipped verification
  ## succeeding for every probed symbol at that version — record
  ## `fkVerified` for all of them and move to the next version, no further
  ## compiles needed. On failure, this loop cannot yet tell "headers
  ## broken this version" from "one or more symbols individually drifted"
  ## — that's what the baseline probe (`softlinkProbeOnly=-`) is for,
  ## exactly as the standard loop already runs it. A failing baseline means
  ## every symbol is `fkUnknown`, same as the standard path, no bisection
  ## attempted (nothing sound to bisect: the compile that's failing doesn't
  ## even reach the `#include`s cleanly). A PASSING baseline with a failed
  ## define-free compile means the headers are fine but the plain
  ## verification of at least one symbol failed — `bisectPlan` (pure,
  ## unit-tested above) partitions `probeTargets` into symbols a group
  ## compile already proved `fkVerified` and symbols that bottomed out at a
  ## failing singleton, each of which THEN runs through the IDENTICAL
  ## `probeOutcomes`/`classify` pipeline the standard loop below uses. That
  ## shared final step is what makes `facts` provably identical between the
  ## two paths regardless of which one produced them — the fast path only
  ## ever shortcuts the `fkVerified` case, and only when a real compile
  ## structurally proves it; every other classification still goes through
  ## the exact same two-probe pipeline as the non-fast-path loop.
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

    if opts.fastPath:
      # RFC-0001 SS4 B.2, optional fast-path (slice B7). See `harvest`'s own
      # doc comment for the full algorithm; this block is its I/O.
      let fast = compileProbe(nimExe, dump.modulePath, scratchRoot, opts,
        @[versionDir], @[])
      inc result.compileCount
      if fast.exitCode == 0:
        result.baselineOk[v] = true
        for p in probeTargets:
          var facts = result.facts.getOrDefault(p.cName)
          facts[v] = fkVerified
          result.facts[p.cName] = facts
        continue

      let baseline = compileProbe(nimExe, dump.modulePath, scratchRoot, opts,
        @[versionDir], @["softlinkProbeOnly=-"])
      inc result.compileCount
      let baselineOk = baseline.exitCode == 0
      result.baselineOk[v] = baselineOk
      if not baselineOk:
        for p in probeTargets:
          var facts = result.facts.getOrDefault(p.cName)
          facts[v] = fkUnknown
          result.facts[p.cName] = facts
        continue

      # Baseline ok, define-free compile failed: some probed symbol(s)
      # drifted at THIS version. Bisect via `softlinkProbeOnly=<comma
      # list>` (verify mode — no `softlinkProbeExistence`; a multi-symbol
      # existence probe is a macro error, see src/softlink.nim) rather than
      # ever parsing which symbol's assert text appears in a group
      # compile's output ("no textual attribution ever" — RFC-0001 SS4
      # B.2). `groupVerifies` is the ONLY thing that talks to the compiler
      # in this branch; `bisectPlan` itself (unit-tested in isolation
      # above) never does.
      let compileCountPtr = addr result.compileCount
        ## Captured by address BEFORE `groupVerifies` is defined: that
        ## proc's own return type (`bool`) gives IT an implicit `result`
        ## variable, which would shadow `harvest`'s own `result` if
        ## referenced as `result.compileCount` from inside the closure —
        ## this named alias sidesteps the shadowing entirely.
      proc groupVerifies(group: seq[string]): bool =
        let outcome = compileProbe(nimExe, dump.modulePath, scratchRoot, opts,
          @[versionDir], @["softlinkProbeOnly=" & group.join(",")])
        inc compileCountPtr[]
        outcome.exitCode == 0

      let plan = bisectPlan(probeTargets.mapIt(it.cName), groupVerifies)
      for cname in plan.verified:
        var facts = result.facts.getOrDefault(cname)
        facts[v] = fkVerified
        result.facts[cname] = facts
      for cname in plan.needsStandard:
        # The ONLY place absent/mismatch/unknown are ever assigned, in
        # EITHER path — see `harvest`'s doc comment for why that's what
        # makes the two paths' `facts` provably identical.
        let o = probeOutcomes(nimExe, dump.modulePath, versionDir, cname,
          scratchRoot, opts, addr result.compileCount)
        var facts = result.facts.getOrDefault(cname)
        facts[v] = classify(o)
        result.facts[cname] = facts
      continue

    # Standard path (`opts.fastPath == false`, the default) — byte-
    # identical to pre-slice-B7 behavior; no existing caller (none of which
    # ever sets `fastPath`) observes any change here beyond the new
    # `compileCount` bookkeeping, which was `0`/absent before this field
    # existed and is now populated identically regardless of which path ran.
    let baseline = compileProbe(nimExe, dump.modulePath, scratchRoot, opts,
      @[versionDir], @["softlinkProbeOnly=-"])
    inc result.compileCount
    let baselineOk = baseline.exitCode == 0
    result.baselineOk[v] = baselineOk
    for p in probeTargets:
      var facts = result.facts.getOrDefault(p.cName)
      if not baselineOk:
        facts[v] = fkUnknown
      else:
        let o = probeOutcomes(nimExe, dump.modulePath, versionDir, p.cName,
          scratchRoot, opts, addr result.compileCount)
        facts[v] = classify(o)
      result.facts[p.cName] = facts

  result.report = renderReport(result)

# ---------------------------------------------------------------------------
# Manifest emission (RFC-0001 SS4 B.3, slice B4)
#
# Two pure functions plus a thin I/O wrapper, mirroring this module's own
# decision/IO split (see the module doc comment): `compressFacts` (ordered
# versions + per-version FactKind -> the four VersionInterval seqs) and
# `buildManifest` (HarvestResult + explicit provenance/meta -> JsonNode) do
# no I/O at all and are unit-tested directly; `writeManifest` is the one
# place this section touches a filesystem.
# ---------------------------------------------------------------------------

func factKindKey(k: FactKind): string =
  ## The manifest's JSON key for one `FactKind` (RFC-0001 SS4 B.3: `header`
  ## facts are namespaced by these four names, dropping the `fk` prefix
  ## `FactKind`'s Nim identifiers carry).
  case k
  of fkVerified: "verified"
  of fkAbsent: "absent"
  of fkMismatch: "mismatch"
  of fkUnknown: "unknown"

func compressFacts*(versions: seq[string],
                     perVersion: Table[string, FactKind]
                     ): array[FactKind, seq[VersionInterval]] =
  ## RFC-0001 SS4 B.3 interval compression. `versions` arrives already
  ## `cmpVersion`-ordered (as `HarvestResult.versions` is — `harvest`'s own
  ## loop never reorders it) and `perVersion` carries EXACTLY one `FactKind`
  ## per version (`harvest`'s classification loop always assigns one,
  ## `fkUnknown` when the baseline itself failed — see `HarvestResult.facts`'
  ## doc comment) — so `perVersion` is TOTAL over `versions`, and walking it
  ## once, grouping maximal runs of consecutive equal `FactKind`s, partitions
  ## the corpus EXHAUSTIVELY by construction: every version lands in exactly
  ## one run, and every run becomes exactly one interval of exactly one fact
  ## key. That is the whole disjoint/exhaustive invariant (RFC-0001 SS4 B.3's
  ## round-2 addition) — it is not a separate property to prove, it falls
  ## out of "every version has one classification, runs partition a
  ## sequence."
  ##
  ## Each run becomes one half-open `VersionInterval` (`lo` inclusive, `hi`
  ## exclusive, either omissible as `""` == unbounded, per B0): `lo` is the
  ## run's own first version, `hi` is the FIRST VERSION OF THE NEXT RUN —
  ## so one interval's exclusive `hi` and the next run's inclusive `lo` are
  ## the identical string, the boundary version is claimed by both sides of
  ## the split exactly once, and the two intervals are disjoint (never an
  ## off-by-one on which side "owns" the shared version). The FIRST run
  ## omits `lo` (unbounded start — matches the RFC's own example, whose
  ## first-seen fact omits `lo`); the LAST run omits `hi` (unbounded end,
  ## matches the example's last-seen fact). A single run spanning the WHOLE
  ## corpus omits both bounds, i.e. the empty interval `{}` — the half-open,
  ## fully-unbounded reading of "verified from before the corpus began
  ## through after it ended," which is exactly what "every harvested version
  ## agrees" means when nothing outside the corpus is ever extrapolated.
  if versions.len == 0:
    return
  type Run = tuple[kind: FactKind, firstVersion: string]
  var runs: seq[Run] = @[]
  for v in versions:
    let k = perVersion[v]
    if runs.len == 0 or runs[^1].kind != k:
      runs.add (k, v)
  for i in 0 ..< runs.len:
    var iv: VersionInterval
    if i > 0: iv.lo = runs[i].firstVersion
    if i < runs.len - 1: iv.hi = runs[i + 1].firstVersion
    result[runs[i].kind].add iv

proc loadCorpusProvenance*(corpusDir: string): seq[tuple[version, source: string]] =
  ## Reads `<corpusDir>/corpus.json`'s `"corpus"` array for the manifest's
  ## own `"corpus"` provenance field (RFC-0001 SS4 B.3: `{version, source}`
  ## pairs only — `prepare`/`_comment` are fetch-time concerns the manifest
  ## never records). Ordered via `cmpVersion` to match
  ## `HarvestResult.versions`' own order; `enumerateCorpusVersions` already
  ## cross-validates that the manifest and the on-disk corpus agree on the
  ## SET of versions, so this reorders for presentation only, it does not
  ## re-validate.
  let j = parseJson(readFile(corpusDir / "corpus.json"))
  for entry in j["corpus"]:
    result.add (entry["version"].getStr, entry["source"].getStr)
  result.sort(proc(a, b: tuple[version, source: string]): int =
    cmpVersion(a.version, b.version))

proc buildManifest*(r: HarvestResult,
                     corpus: seq[tuple[version, source: string]],
                     meta: HarvestMeta): JsonNode =
  ## RFC-0001 SS4 B.3 manifest, pure: `HarvestResult` (already-classified
  ## facts) + explicit `corpus` provenance + explicit `meta` -> the
  ## `<lib>.compat.json` `JsonNode` tree. Pure so a golden-fixture test can
  ## PIN `meta`/`corpus` and compare structurally (`tests/tharvest.nim`),
  ## independent of the machine or day a real harvest runs on.
  ##
  ## `lib` is `toLowerAscii(r.baseName)` (design guidance point 4) — the
  ## SAME derivation a `dynlib` block's `libNameToIdent` (src/softlink.nim)
  ## already produces, so both a bare logical name (`dynlib "z3"` -> baseName
  ## "Z3") and an explicit pattern (`"libcorpuslib.so"` -> baseName
  ## "Corpuslib") round-trip to their expected lowercase manifest stem ("z3",
  ## "corpuslib"). The RFC's `lib`-identity CHECK is consumption-side (B6a);
  ## this is only the derivation, reused verbatim there.
  ##
  ## One `symbols` entry per `r.probedSymbols` (skipped procs — `noverify`,
  ## `prototype`-only — are corpus-INVARIANT, never given an entry: nothing
  ## version-shaped was ever recorded for them, see `harvest`'s own doc
  ## comment). Under `"header"`, only NON-EMPTY fact keys are emitted (the
  ## RFC's own example omits empty ones) and interval objects omit unbounded
  ## ends (no `"lo": ""`) — both directly reflect `compressFacts`' output:
  ## an unobserved `FactKind` is an empty seq, an unbounded bound is `""`.
  var corpusArr = newJArray()
  for entry in corpus:
    corpusArr.add %*{"version": entry.version, "source": entry.source}

  var symbols = newJObject()
  for cname in r.probedSymbols:
    let compressed = compressFacts(r.versions, r.facts[cname])
    var header = newJObject()
    for kind in FactKind:
      if compressed[kind].len > 0:
        var arr = newJArray()
        for iv in compressed[kind]:
          var obj = newJObject()
          if iv.lo.len > 0: obj["lo"] = %iv.lo
          if iv.hi.len > 0: obj["hi"] = %iv.hi
          arr.add obj
        header[factKindKey(kind)] = arr
    symbols[cname] = %*{"header": header}

  %*{
    "schema": 1,
    "lib": r.baseName.toLowerAscii(),
    "harvest": {"toolchain": meta.toolchain, "tier": meta.tier,
                "abi": meta.abi, "date": meta.date},
    "corpus": corpusArr,
    "symbols": symbols,
  }

proc writeManifest*(path: string, manifest: JsonNode) =
  ## The one place this section writes the committed `<lib>.compat.json`
  ## artifact — kept separate from `buildManifest` so tests exercise the
  ## pure `JsonNode` tree directly (structural comparison, no filesystem, no
  ## whitespace brittleness).
  writeFile(path, manifest.pretty)

# ---------------------------------------------------------------------------
# Drift alarm (RFC-0001 SS4 B.4, slice B5)
#
# The manifest (above) is Stage B's honest artifact: it records mismatch
# intervals right alongside verified/absent/unknown ones, no editorializing.
# This section is the CI TRIPWIRE layered on top of it — a pure decision
# (`driftAlarm`) over an already-produced `HarvestResult`, wired into the
# `when isMainModule` shim below to turn "a mismatch exists in the support
# range" into a nonzero process exit, which is what actually stops a CI
# pipeline (the RFC's own framing: "before any process loaded anything").
# ---------------------------------------------------------------------------

const f3Sentence* =
  "one Nim signature cannot be sound across this range — narrow the " &
  "range or split the binding."
  ## RFC-0001 SS4 B.4's diagnosis sentence, verbatim — the ONE piece of
  ## prose `driftAlarm`'s diagnosis is required to contain, and what the
  ## CLI exit-code integration test (`tests/tharvest.nim`) greps stdout/
  ## stderr for.

func versionInSupportRange(v: string, r: VersionInterval): bool =
  ## Half-open range membership, IDENTICAL semantics to B0's
  ## `VersionInterval`/B4's manifest intervals: `lo` inclusive, `hi`
  ## exclusive, either bound `""` meaning unbounded in that direction.
  ## Thin wrapper over `softlink/versions.contains` (slice B6a pulled the
  ## predicate itself up into that shared module, since the consumer side
  ## needs the identical rule) — kept as a named local proc rather than
  ## inlined at the one call site below, to preserve this doc comment's
  ## explanation at its point of use.
  r.contains(v)

func driftAlarm*(r: HarvestResult,
                  supportRange: VersionInterval = VersionInterval(lo: "", hi: "")
                  ): tuple[tripped: bool, diagnosis: string] =
  ## RFC-0001 SS4 B.4 (slice B5): the CI drift-alarm decision. Scans every
  ## `(symbol, version)` pair `harvest` classified and trips iff at least
  ## one is `fkMismatch` AND inside `supportRange`.
  ##
  ## `supportRange` defaults to the fully-unbounded interval, i.e. "the
  ## binding's claimed support range is the entire harvested corpus" — the
  ## RFC never defines "claimed support range" at Stage B (that's Stage
  ## C3's `{.since.}`, not this slice), and the corpus IS exactly the
  ## version set the maintainer chose to harvest, so any `mismatch`
  ## anywhere in it trips the alarm by default. A caller may narrow this
  ## explicitly (e.g. a corpus deliberately extended with ancient versions
  ## harvested purely for `absent` provenance, outside the real support
  ## window) — NOT exposed as a CLI flag in this slice (B8's UX question).
  ##
  ## `unknown`/`absent`/`verified` never trip this — ONLY `mismatch` (the
  ## F3 signal: a pinned Nim signature provably conflicts with a supported
  ## version's header). `unknown` is inconclusive, not evidence of
  ## anything, and must not fail CI on its own (a 3.0.0-style broken corpus
  ## snapshot is already visible in the manifest, not silently swallowed,
  ## but it does not itself trip THIS alarm).
  ##
  ## `tripped == false` implies `diagnosis == ""`. When tripped, the
  ## diagnosis names EVERY offending symbol together with every in-range
  ## mismatched version (not merely the first one found), followed by the
  ## RFC's own F3 sentence verbatim (`f3Sentence`) — the CI log must be
  ## self-sufficient: "which symbol(s), which version(s), what to do."
  var offenders: seq[tuple[cname: string, versions: seq[string]]] = @[]
  for cname in r.probedSymbols:
    var hits: seq[string] = @[]
    for v in r.versions:
      if r.facts[cname][v] == fkMismatch and versionInSupportRange(v, supportRange):
        hits.add v
    if hits.len > 0:
      offenders.add (cname, hits)

  if offenders.len == 0:
    return (tripped: false, diagnosis: "")

  var lines: seq[string] = @[
    "softlink harvest: DRIFT ALARM (RFC-0001 SS4 B.4) — " & $offenders.len &
    " symbol(s) have a `mismatch` classification inside the claimed " &
    "support range:"]
  for o in offenders:
    lines.add("  " & o.cname & ": mismatch at " & o.versions.join(", "))
  lines.add(f3Sentence)
  (tripped: true, diagnosis: lines.join("\n"))

proc detectToolchain(): string =
  ## Best-effort first line of `gcc --version` for `HarvestMeta.toolchain`
  ## (design guidance point 3: "a plain caller-supplied string is also
  ## fine — don't over-engineer"). `defaultHarvestOptions` already commits
  ## this module to the gcc/clang-tuned pipeline as its required minimum
  ## leg, so this asks for gcc specifically rather than reinventing
  ## compiler-family detection. Never raises: a harvester that can't
  ## identify its own compiler still produces a usable manifest — this
  ## field is provenance, not a machine-checked contract (that's schema/
  ## lib-identity checking, B6a).
  try:
    let (output, code) = execCmdEx("gcc --version")
    if code == 0 and output.len > 0:
      return output.splitLines()[0]
  except OSError, ValueError:
    discard
  "unknown"

proc defaultHarvestMeta*(): HarvestMeta =
  ## Real-use defaults for `HarvestMeta` — best-effort, never auto-detected
  ## when a caller supplies its own (e.g. the golden-fixture test's PINNED
  ## meta, design guidance point 3).
  HarvestMeta(
    toolchain: detectToolchain(),
    tier: "builtin-compat",
    abi: abiTag(),
    date: now().format("yyyy-MM-dd"),
  )

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
    # RFC-0001 SS4 B.3 (slice B4): write the compat manifest next to the
    # dump — trivial extension of this already-thin shim, NOT the B8 CLI
    # (no flags/subcommand parsing, just "harvest, then emit the artifact
    # the harvest exists to produce"). Real-use `defaultHarvestMeta`/corpus
    # provenance read fresh off disk — the golden-fixture TEST pins its own
    # `HarvestMeta` instead, see tests/tharvest.nim.
    let corpus = loadCorpusProvenance(args[1])
    let manifest = buildManifest(r, corpus, defaultHarvestMeta())
    let manifestPath = args[0].parentDir / (r.baseName.toLowerAscii() & ".compat.json")
    writeManifest(manifestPath, manifest)
    echo "softlink harvest: wrote " & manifestPath
    # RFC-0001 SS4 B.4 (slice B5): the drift alarm runs AFTER the manifest
    # is written, never gating it — the manifest is Stage B's honest
    # artifact (mismatch intervals included, nothing hidden); the alarm is
    # the CI exit-code tripwire layered on top of it. This ordering is
    # what makes the RFC's "before any process loaded anything" claim true
    # in a CI pipeline: the artifact still gets produced/committed-review-
    # able, but the CI *step* that ran this shim fails loudly. Default
    # (whole-corpus) support range — narrowing is not a CLI flag in this
    # slice, see `driftAlarm`'s own doc comment.
    let (tripped, diagnosis) = driftAlarm(r)
    if tripped:
      stderr.writeLine(diagnosis)
      quit(1)
  except CalibrationRefusedError as e:
    stderr.writeLine("softlink harvest: REFUSED — calibration preflight failed:\n" & e.msg)
    quit(1)
  except HarvestError as e:
    stderr.writeLine("softlink harvest: " & e.msg)
    quit(1)
