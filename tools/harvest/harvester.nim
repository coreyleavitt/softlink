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
import std/[os, osproc, json, tempfiles, strutils, tables, algorithm, streams,
            times, sequtils, monotimes]
import harvest_defaults
import softlink/versions
when defined(posix):
  import std/posix

export FactKind, abiTag

type
  HarvestError* = object of CatchableError
    ## Ordinary, expected failure (bad dump/corpus, `findExe("nim")` came up
    ## empty, ...) — not a defect in the harvester itself.
  CalibrationRefusedError* = object of HarvestError
    ## Raised by `harvest` when the calibration preflight does not observe
    ## the expected known-answer quad (RFC-0003 §5.3/§7 slice B3 extended
    ## the original trio with `calib_param_drifted`). Carries a
    ## human-readable toolchain diagnosis as its `msg`. No probing of the
    ## real corpus/module happens
    ## when this is raised — "no harvest performed" per RFC-0001 SS4 B.2.

  ProbeFact* = object
    ## One proc's pragma facts, as recorded by a B.1 probe-facts dump.
    ## Field shape mirrors `probeFactsJson` in src/softlink.nim exactly
    ## (both sides of this schema must never drift independently).
    nimName*, cName*: string
    header*, prototype*, verifyWhen*, noverifyReason*, since*, until*: string
    optional*, noverify*: bool

  ProbeDump* = object
    ## One `<Base>.probes.json` file (RFC-0001 SS4 B.1), parsed.
    schemaVersion*: int
    kind*, modulePath*, libPattern*, baseName*: string
    procs*: seq[ProbeFact]

  ProbeStage* = enum
    ## RFC-0003 §5.2(ii): which of the (up to three) real compiles for one
    ## `(version, symbol)` pair is the one `classify` bottoms out at. Replaces
    ## the original boolean bag (`baselineOk`/`existenceOk`/`verifyOk`) —
    ## there, "fields past the first failing stage are meaningless" was a
    ## doc-comment-only invariant a caller could still violate by
    ## construction (e.g. `verifyOk: true, assertMsgSeen: true` was
    ## representable nonsense); an enum can only ever name ONE stage.
    psBaselineFailed  ## The baseline (`softlinkProbeOnly=-`) compile failed
                       ## — this version's headers are broken/missing for
                       ## the whole module. `probeOutcomes` never produces
                       ## this itself (its caller, `harvest`, already knows
                       ## the baseline succeeded before calling it — see
                       ## that proc's own loop); it exists so `classify`'s
                       ## table is total and directly unit-testable for
                       ## every row, matching the original design.
    psAbsent           ## Existence probe failed: the header never declares
                       ## the symbol at this version.
    psVerifyFailed     ## Existence passed but the verify probe (the
                       ## assert chain + dummy call + dummy parameter
                       ## declarations, RFC-0003 §3.1) failed — decisive or
                       ## not is what `evidence` (below) distinguishes.
    psVerified         ## Both existence and verify passed.

  VerifyEvidence* = enum
    ## Confirming facts about a `psVerifyFailed` outcome — never the
    ## verdict itself (`classify` alone decides that from `stage` +
    ## `evidence`; see its rewritten doc comment, RFC-0003 §5.2 ii).
    veAssertMsg
      ## Softlink's own fixed signature-mismatch text (`assertMismatchNeedle`)
      ## appeared in the verify compile's output. Confirming evidence a real
      ## mismatch WAS detected by the C compiler's own diagnostics — no
      ## longer the sole path to `fkMismatch` (RFC-0001's original
      ## fall-through-to-`fkUnknown` design, narrowed by RFC-0003 §3.1's
      ## isolation argument: many genuine drifts, e.g. a hard
      ## incompatible-pointer-argument error, kill the verify TU before
      ## softlink's own assert ever runs and so never emit this text at
      ## all, yet are just as decisively a signature problem).
    veUnavailable
      ## The verify failure carries NO decisive signature information,
      ## for one of two reasons `classify` treats identically
      ## (`fkUnknown`, never `fkMismatch`): (a) the strict-mode `#error`
      ## needle (`strictVerifyUnavailableNeedle`, verify.nim:647) appeared
      ## — this compile's verification tier structurally could not run at
      ## all (RFC-0003 §5.2 iii); or (b) probe orchestration's retry-once
      ## guard (`resolveVerifyRetry`, below) found the failure did NOT
      ## reproduce on a second, identical compile — a flaky result, not a
      ## real one (RFC-0003 §5.2 ii, "decisive requires deterministic").
      ## Both are "no trustworthy evidence of a signature problem exists",
      ## just discovered by different means, which is why one bit covers
      ## both — `classify` has no reason to tell them apart.

  ProbeOutcomes* = object
    ## RFC-0003 §5.2(ii) stage-enum + evidence-set shape. `evidence` only
    ## EXISTS on the `psVerifyFailed` branch — a variant object, not a
    ## doc-comment promise, is what makes "verified AND assertMsgSeen"
    ## (the original design's representable-but-nonsensical state)
    ## impossible to construct at all.
    case stage*: ProbeStage
    of psVerifyFailed:
      evidence*: set[VerifyEvidence]
    else:
      discard

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
    harvesterVersion*: string
      ## RFC-0003 §2/§7 slice C1: the softlink package version (`softlink/
      ## versions.softlinkVersion`) that performed this harvest — pure
      ## provenance metadata, gates no consumer logic (§2: "ground truth is
      ## not a mode. There is no flag."). "" (the zero value, matching
      ## every sibling field's own "nothing here is auto-detected"
      ## convention) means the caller didn't ask for a stamp;
      ## `buildManifest` below OMITS the JSON key entirely in that case
      ## rather than emitting an empty string, so a caller-built
      ## `HarvestMeta` literal that predates this field (every pre-C1
      ## pinned-meta test in tests/tharvest.nim) reproduces its manifest
      ## byte-for-byte unchanged — no existing golden fixture needed to
      ## change for this field to land. `defaultHarvestMeta()` below always
      ## sets it for a real harvest.

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
    ## Confirming text for a real signature mismatch (RFC-0001 SS4 B.2) —
    ## confirmation on an already-structurally-determined `mismatch`, never
    ## a substitute for the structural baseline/existence/verify decision.
    ## Must stay byte-for-byte in sync with the `errMsg` built in
    ## `genVerifyBlock` (src/softlink.nim):
    ## `"softlink: " & p.nameStr & " signature mismatch vs " & declSource`.
    ## NOT the only text ever matched (RFC-0003 §5.2 iii/B1 corrects this
    ## historical claim, also fixed in `tools/harvest/README.md`) —
    ## `strictVerifyUnavailableNeedle` and `infraFailureMarkers` (below) are
    ## matched too, for two DIFFERENT purposes: confirming a decisive
    ## mismatch (this constant) vs. recognizing that a verify failure is
    ## NOT decisive at all (the other two).

  strictVerifyUnavailableNeedle* = "signature verification unavailable here"
    ## RFC-0003 §5.2(iii). Verbatim substring of the strict-mode `#error`
    ## text `verify.nim:647` emits when a probe compile's toolchain/mode
    ## cannot run ANY verification tier at all (C++/GCC/Clang/MSVC
    ## `/std:clatest` all unavailable) — reachable in a harvest because this
    ## module adds `-d:softlinkStrictVerify` to EVERY probe compile
    ## (`compileProbe`), turning what would otherwise be a silent no-op
    ## fallback into a hard compile failure `probeOutcomes` can see and
    ## recognize by this exact text. Seeing it means "this build's
    ## verification tier could not even run" — never confused with a real
    ## signature mismatch (`veUnavailable`, not `veAssertMsg`).

  infraFailureMarkers = [
    "internal compiler error",
    "Killed signal terminated program",
  ]
    ## RFC-0003 §5.2(ii), "decisive requires deterministic": textual shapes
    ## of a TRANSIENT INFRASTRUCTURE failure (an OOM-killed `cc1`, a real
    ## GCC/Clang internal compiler error) rather than a genuine,
    ## reproducible verify failure — a corpus×symbol harvest is thousands
    ## of subprocess invocations, and a dying toolchain must never be
    ## silently reinterpreted as a signature fact. `infraFailureReason`
    ## (below) also treats a signal-terminated compiler EXIT CODE as this
    ## same shape, independent of these text markers.

  calibVerifiedSym = "calib_verified"
  calibAbsentSym = "calib_absent"
  calibMismatchedSym = "calib_mismatched"
  calibParamDriftedSym = "calib_param_drifted"
    ## RFC-0003 §5.3/§7 slice B3: the fourth known-answer symbol, added to
    ## make the pin↔classify coupling documented at §5.2(i)/(ii)
    ## structural rather than conventional — a toolchain where the
    ## diagnostics-severity pin (`-Werror=incompatible-pointer-types`,
    ## `defaultHarvestOptions`/`clangHarvestOptions`, above) is absent,
    ## stripped, or ineffective makes THIS symbol classify `fkVerified` or
    ## `fkUnknown` instead of the expected `fkMismatch`, which trips
    ## `runCalibration`'s deviation check and refuses the harvest entirely
    ## (`CalibrationRefusedError`) instead of silently reverting to Gap B.
    ## The existing `calibMismatchedSym` (return-type drift) is unchanged;
    ## the two mismatch calibrations jointly prove both assert paths (the
    ## call-based signature assert AND the dummy-parameter-variable
    ## mechanism the pin protects) have teeth. This quad
    ## (verified/absent/mismatched/param-drifted) now covers every verdict
    ## `classify` can produce from a symbol-level probe.
    ##
    ## Deliberately NO fifth (tier-degraded) calibration symbol: tier
    ## selection is whole-TU/toolchain-wide (§3.1), so a degraded tier
    ## cannot be scoped to one symbol while the others stay at full tier —
    ## degradation already trips `calib_verified` itself (a live tier is a
    ## precondition for a real "verified" fact, not a per-symbol property),
    ## and the strict-needle path is proven separately by B1's
    ## forced-fallback integration test.

func isDiagnosticsPinFlag(flag: string): bool =
  ## RFC-0003 §5.2(i)/B2a: identifies the diagnostics-SEVERITY flags
  ## `defaultHarvestOptions`/`clangHarvestOptions` add (`--passC:
  ## -Werror=...`) among `HarvestOptions.extraFlags`, so `runCalibration`'s
  ## baseline retry-without-pins diagnosis (below) can strip exactly those
  ## and nothing else. Deliberately narrower than "all of extraFlags": a
  ## caller-supplied compiler-SELECTION flag (`--cc:vcc`, `--cc:clang`) is
  ## not a diagnostics pin, and stripping it too would misdiagnose a
  ## genuinely broken `--cc` value as "pin rejected by this toolchain"
  ## instead of the correct "toolchain/PATH itself" shape.
  "-Werror=" in flag

proc defaultHarvestOptions*(): HarvestOptions =
  ## gcc/clang-tuned defaults — the slice's required minimum leg. Callers
  ## targeting another toolchain (MSVC) override `extraFlags`/
  ## `includeFlagPrefix` explicitly; nothing here is auto-detected.
  ##
  ## `proc`, not `func`: `scratchDir: getTempDir()` reads the environment,
  ## which Nim's effect analysis treats as a genuine side effect on Windows
  ## (it infers it pure on POSIX, which is why a `func` here compiled on the
  ## Linux/macOS legs but errored under MSVC). No caller uses it in a
  ## `const`/compile-time context, so plain `proc` is the correct signature.
  # `extraFlags` derives from the shared `harvest_defaults.
  # defaultDiagnosticsPinFlags` (RFC-0003 stage-4 review M7) rather than a
  # literal here, so `harvest_cli.defaultExtraFlags` (the packaged CLI's
  # own copy of these same defaults) can never drift from this proc's
  # defaults again. The two flags in that shared const:
  #   - "-Werror=implicit-function-declaration" — RFC-0001 SS4 B.2's guard
  #     against silently misclassifying `absent` as `verified`.
  #   - "-Werror=incompatible-pointer-types" — RFC-0003 §5.2(i)/§7 slice
  #     B2a: pins the C compiler's pointer-parameter-drift diagnostic to a
  #     hard error on every probe compile — both GCC and Clang accept this
  #     exact spelling. Without it, a parameter-only drift (e.g. `int*` ->
  #     `bool*`, same name/return type) is a mere warning on permissive
  #     toolchains (verify TU compiles -> false `fkVerified`) or a hard
  #     error only on GCC≥14's OWN default (verify TU dies before
  #     softlink's assert ever runs -> `fkUnknown`, never decisive
  #     `fkMismatch`). This pin plus `classify`'s isolation-backed
  #     reclassification (RFC-0003 §5.2 ii) is what makes parameter drift
  #     decisive on every GCC/Clang version. `runCalibration`'s
  #     `calib_param_drifted` symbol (slice B3) is the structural proof
  #     this pin has teeth; the baseline retry-without-pins diagnosis
  #     (below, `runCalibration`) is what happens when an old toolchain
  #     doesn't recognize this exact flag spelling.
  HarvestOptions(
    nimPaths: @["src"],
    extraFlags: defaultDiagnosticsPinFlags,
    includeFlagPrefix: "-I",
    scratchDir: getTempDir(),
    compileTimeoutMs: 300_000,
    maxOutputBytes: 16_777_216,
  )

proc clangHarvestOptions*(): HarvestOptions =
  ## RFC-0003 §5.2(i)/§7 slice B2a: the clang CI leg's opts construction —
  ## `defaultHarvestOptions`'s shared pin PLUS Clang's own
  ## `-Werror=incompatible-function-pointer-types`. Clang splits
  ## function-pointer-TYPED parameter mismatches into this separate
  ## diagnostic (GCC folds the same shape into the pointer-types
  ## diagnostic the shared pin already covers), so the clang leg needs
  ## this additional flag to keep function-pointer-parameter drift
  ## decisive there too.
  ##
  ## Caller-controlled per §8 resolution 1 — no compiler auto-detection
  ## anywhere in this module, mirroring the existing MSVC-override
  ## precedent (`tests/tharvest_msvc_calibration_refusal.nim`'s hand-built
  ## `msvcDefaultOpts` literal). Wiring THIS into a real clang compile on
  ## the macOS CI leg is slice B2c's job, not this proc's — this exists so
  ## that wiring has a documented, tested construction to reach for.
  result = defaultHarvestOptions()
  result.extraFlags.add("--passC:-Werror=incompatible-function-pointer-types")

# ---------------------------------------------------------------------------
# Pure decision logic
# ---------------------------------------------------------------------------

func classify*(o: ProbeOutcomes): FactKind =
  ## RFC-0003 §5.2(ii)'s single total `case` over the stage-enum + evidence-
  ## set shape, superseding RFC-0001 SS4 B.2's original table AND its own
  ## round-2 fallback ("any verify failure without softlink's assert text
  ## -> `fkUnknown`"):
  ##
  ## | stage | evidence | classification |
  ## |---|---|---|
  ## | `psBaselineFailed` | - | `fkUnknown` (headers broken/missing) |
  ## | `psAbsent` | - | `fkAbsent` |
  ## | `psVerified` | - | `fkVerified` |
  ## | `psVerifyFailed` | `veUnavailable` in evidence | `fkUnknown` |
  ## | `psVerifyFailed` | `veUnavailable` NOT in evidence | `fkMismatch` |
  ##
  ## `veAssertMsg` is CONFIRMING evidence only — it never drives the
  ## verdict. RFC-0001's original rationale for the fall-through ("a verify
  ## failure for some other reason is not a signature mismatch") is
  ## narrowed by RFC-0003 §3.1's isolation argument: per-symbol probing
  ## makes the verify TU's ONLY delta over the already-green existence TU
  ## the probed symbol's own assert chain, dummy call, and dummy parameter
  ## declarations (with §3.1's named struct-by-value-shaped residual) — so
  ## ANY failure there that is not confirmed non-decisive (`veUnavailable`)
  ## really is a signature problem, whether or not the C compiler's own
  ## diagnostic happens to also echo softlink's fixed assert text. This is
  ## what makes a hard incompatible-pointer-argument error (RFC-0003 §5,
  ## which kills the TU before softlink's own assert ever runs and so never
  ## emits `assertMismatchNeedle`) classify `fkMismatch` instead of the
  ## `fkUnknown` it used to fall through to.
  ##
  ## Pure and total over `ProbeOutcomes` alone — the "decisive requires
  ## deterministic" guards (retry-once, infra-marker loud abort, RFC-0003
  ## §5.2 ii) live entirely in probe orchestration (`probeOutcomes`,
  ## `resolveVerifyRetry`, below), never here: by the time a `ProbeOutcomes`
  ## reaches this function, orchestration has already resolved any
  ## non-determinism, so `classify` only ever sees a "clean" input.
  case o.stage
  of psBaselineFailed: fkUnknown
  of psAbsent: fkAbsent
  of psVerified: fkVerified
  of psVerifyFailed:
    if veUnavailable in o.evidence: fkUnknown
    else: fkMismatch

func verifyEvidence*(output: string): set[VerifyEvidence] =
  ## Pure classification of a FAILED verify compile's output into
  ## confirming/non-decisive evidence bits — never the verdict itself
  ## (`classify` owns that). Used directly by `resolveVerifyRetry` (below)
  ## on the RETRY compile's output once a verify failure has survived
  ## retry-once, i.e. only once orchestration already knows the failure is
  ## real, not flaky.
  if assertMismatchNeedle in output: result.incl veAssertMsg
  if strictVerifyUnavailableNeedle in output: result.incl veUnavailable

func infraFailureReason*(output: string, exitCode: int): string =
  ## RFC-0003 §5.2(ii): pure detection of whether a failed compile LOOKS
  ## like a transient infrastructure failure (an OOM-killed `cc1`, a real
  ## GCC/Clang internal compiler error, a compiler subprocess killed by a
  ## signal) rather than a genuine, reproducible verify failure. Returns a
  ## non-empty, human-readable reason when it does; the empty string
  ## otherwise. No I/O — directly unit-testable against synthetic
  ## `(output, exitCode)` pairs, independent of ever forcing a real OOM or
  ## ICE in CI.
  ##
  ## The exit-code check relies on a documented `std/osproc`/`std/os`
  ## convention (`exitStatusLikeShell`, used internally by POSIX
  ## `waitForExit`): a child process killed by a signal reports exit code
  ## `128 + signum`, the same convention a POSIX shell uses — so any code
  ## in `(128, 128 + 64]` here means SOME process in the compile chain
  ## (`nim` itself, or a `gcc`/`cc1` child it shells out to) was killed by a
  ## signal rather than exiting normally, independent of whatever text (if
  ## any) made it into the captured output.
  for marker in infraFailureMarkers:
    if marker in output:
      return "compiler output contains the infrastructure-failure marker \"" &
             marker & "\""
  if exitCode > 128 and exitCode <= 128 + 64:
    return "compiler process exited with a signal-terminated status (" &
           $exitCode & ") — likely killed by a signal (e.g. OOM)"
  ""

type
  VerifyFailureDecision* = object
    ## The pure decision RFC-0003 §5.2(ii)'s "decisive requires
    ## deterministic" guards reduce to, given a FIRST verify compile that
    ## already failed non-infra-shaped and a RETRY compile of the identical
    ## args. A case object on `abort` — mirroring `ProbeOutcomes`' own
    ## nonsense-states goal — makes "abort AND also here's a decisive
    ## outcome" unrepresentable.
    case abort*: bool
    of true:
      abortReason*: string
        ## Never empty when `abort == true` — the `HarvestError` message
        ## `probeOutcomes` raises verbatim.
    of false:
      outcome*: ProbeOutcomes
        ## Always `stage: psVerifyFailed` — this decision is only ever
        ## reached once the verify probe has already failed once.
      warning*: string
        ## Non-empty exactly when the failure did NOT reproduce on retry
        ## (flaky) — `probeOutcomes` prints this loudly (`stderr`) rather
        ## than silently recording a non-decisive fact with no trace.

func resolveVerifyRetry*(cName, versionDir: string, firstExitCode, retryExitCode: int,
                          retryOutput: string): VerifyFailureDecision =
  ## Pure — no I/O, no compiling. `probeOutcomes` (below) is responsible for
  ## actually RUNNING the retry compile and for checking the FIRST failure's
  ## own output for an infra shape BEFORE even attempting a retry (a
  ## dying toolchain shouldn't be given a second chance to burn a compile);
  ## this function only decides what the RETRY's outcome means, which is
  ## the piece that benefits from being directly unit-testable against
  ## synthetic exit codes/output with no real flaky or OOM-killed compiler
  ## required.
  ##
  ## Three cases, in priority order:
  ## 1. Retry succeeded (`retryExitCode == 0`) -> the original failure did
  ##    NOT reproduce: flaky, not real. Record the non-decisive outcome
  ##    (`psVerifyFailed` + `veUnavailable`, which `classify` maps to
  ##    `fkUnknown`) with a loud warning naming both outcomes — never
  ##    silently trusted either way.
  ## 2. Retry ALSO failed, and its output/exit code look infra-shaped ->
  ##    abort the whole harvest (the toolchain is dying, not the header).
  ## 3. Retry failed again, deterministically, non-infra-shaped -> a real,
  ##    reproducible verify failure. Evidence comes from the RETRY's output
  ##    (the confirmed-reproducing run), via `verifyEvidence`.
  if retryExitCode == 0:
    return VerifyFailureDecision(abort: false,
      outcome: ProbeOutcomes(stage: psVerifyFailed, evidence: {veUnavailable}),
      warning: "softlink harvest: WARNING - verify probe for '" & cName &
        "' at " & versionDir & " is FLAKY: first compile failed (exit " &
        $firstExitCode & "), retry compile succeeded (exit 0). Recording " &
        "a non-decisive 'unknown' classification rather than trusting " &
        "either outcome — if this recurs, investigate toolchain/resource " &
        "stability (RFC-0003 5.2 ii: decisive requires deterministic).")

  let retryInfra = infraFailureReason(retryOutput, retryExitCode)
  if retryInfra.len > 0:
    return VerifyFailureDecision(abort: true, abortReason:
      "softlink harvest: probe compile for '" & cName & "' at " & versionDir &
      " looks like an INFRASTRUCTURE failure on RETRY, not a genuine " &
      "signature verification failure (" & retryInfra & ") — aborting the " &
      "whole harvest rather than risk recording a poisoned fact (the " &
      "existing maxOutputBytes/compileTimeoutMs philosophy: a dying " &
      "toolchain produces no manifest at all). Compiler output:\n" & retryOutput)

  VerifyFailureDecision(abort: false,
    outcome: ProbeOutcomes(stage: psVerifyFailed, evidence: verifyEvidence(retryOutput)),
    warning: "")

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

proc reqField(j: JsonNode, key, dumpFile: string): JsonNode =
  ## Look up `key` on `j`, raising a `HarvestError` (never a raw, unhelpful
  ## `json.KeyError`) when it's absent. Code-review finding CR1-11: `loadDump`
  ## used to index every field it expects directly (`j["until"]` etc.) — a
  ## probes.json written by an older softlink, from before a schema-adding
  ## RFC (e.g. RFC-0002 slice A1b's `until` key) landed, is missing fields a
  ## CURRENT `loadDump` expects, and the fix for that ("re-run the probe
  ## dump against the current softlink") is a much better diagnostic than a
  ## bare `key not found: until`. Used for every field this proc reads, top-
  ## level and per-proc alike, so the hardening is uniform rather than
  ## limited to the one key the RFC that motivated it happened to add.
  if not j.hasKey(key):
    raise newException(HarvestError,
      "softlink harvest: probe-facts dump " & dumpFile & " is missing the " &
      "'" & key & "' field — this dump predates the current probes.json " &
      "schema (it was most likely written by an older softlink, before a " &
      "schema-adding change). Re-run the -d:softlinkDumpProbes=<dir> " &
      "compile that produced this dump to regenerate it against the " &
      "current schema.")
  j[key]

proc loadDump*(dumpFile: string): ProbeDump =
  ## Parse one `<Base>.probes.json` file (RFC-0001 SS4 B.1 schema; see
  ## `validateProbeJson` in softlink.nimble for the schema this mirrors).
  if not fileExists(dumpFile):
    raise newException(HarvestError,
      "softlink harvest: probe-facts dump not found: " & dumpFile)
  let j = parseJson(readFile(dumpFile))
  result.schemaVersion = reqField(j, "schemaVersion", dumpFile).getInt
  result.kind = reqField(j, "kind", dumpFile).getStr
  result.modulePath = reqField(j, "modulePath", dumpFile).getStr
  result.libPattern = reqField(j, "libPattern", dumpFile).getStr
  result.baseName = reqField(j, "baseName", dumpFile).getStr
  # #22 (defense in depth): `baseName` gets spliced into the output compat-
  # manifest's PATH (`isMainModule`'s `manifestPath`, below) — a legitimate
  # dump's `baseName` is always `dynlib`'s own `libNameToIdent` output
  # (`softlink.nim`), which by construction is non-empty ASCII alphanumeric
  # only (no `.`, `/`, `\`, or `..`). The dump is normally self-produced by
  # the SAME macro, but nothing stops a corrupted or hand-edited dump file
  # from carrying a hostile value here, so this is validated at the one
  # place it enters the system — before ANY consumer (report text, manifest
  # path, ...) ever sees it — rather than only at the path-splice site.
  if result.baseName.len == 0 or not result.baseName.allCharsInSet(IdentChars):
    raise newException(HarvestError,
      "softlink harvest: probe-facts dump " & dumpFile & " has an invalid " &
      "'baseName' (" & escape(result.baseName) & ") — expected a non-empty " &
      "alphanumeric identifier (as `dynlib`'s libNameToIdent always " &
      "produces), got something containing a path separator, '..', or " &
      "another non-identifier character; refusing to use it to build a " &
      "filesystem path")
  for p in reqField(j, "procs", dumpFile):
    result.procs.add ProbeFact(
      nimName: reqField(p, "nimName", dumpFile).getStr,
      cName: reqField(p, "cName", dumpFile).getStr,
      header: reqField(p, "header", dumpFile).getStr,
      prototype: reqField(p, "prototype", dumpFile).getStr,
      verifyWhen: reqField(p, "verifyWhen", dumpFile).getStr,
      optional: reqField(p, "optional", dumpFile).getBool,
      noverify: reqField(p, "noverify", dumpFile).getBool,
      noverifyReason: reqField(p, "noverifyReason", dumpFile).getStr,
      since: reqField(p, "since", dumpFile).getStr,
      until: reqField(p, "until", dumpFile).getStr,
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
  CompileOutcome* = object
    ## Exported alongside `compileProbe*` (RFC-0003 §5.2 iii) so a direct
    ## caller (e.g. the strict-needle integration test) can read a single
    ## probe compile's raw exit code/output without going through
    ## `probeOutcomes`' own existence+verify orchestration.
    exitCode*: int
    output*: string

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
  ## #23: uses `std/tempfiles.createTempDir` (a real `mkdtemp`-style secure
  ## primitive — random name AND atomic, race-free creation) rather than a
  ## predictable name computed separately from the `createDir` that makes
  ## it: a plain `std/oids.genOid`, while globally unique, is a 12-byte
  ## timestamp+counter+machine-id value, not a secret — predictable enough
  ## under the shared, world-writable `getTempDir()` to make a symlink-race
  ## plausible between "compute the name" and "create the directory" (the
  ## two used to be separate steps here; `createTempDir` does both in one
  ## call). Parallel-safe by construction, same as before (RFC-0001 SS4
  ## B.2: "the unique nimcache is what makes per-symbol probing genuinely
  ## embarrassingly parallel").
  createTempDir("sl_harvest_", "", base)

type
  ReaderMsgKind = enum rmkChunk, rmkDone, rmkExceeded
  ReaderMsg = object
    case kind: ReaderMsgKind
    of rmkChunk: data: string
    of rmkDone, rmkExceeded: discard

  ReaderArgs = tuple[process: Process, maxOutputBytes: int, chan: ptr Channel[ReaderMsg]]

proc killProcessTree(p: Process) {.gcsafe.} =
  ## Kills not just `p` but its whole descendant tree, so that if `p` (the
  ## direct child, `nim c`) has itself forked a real C compiler (gcc ->
  ## cc1/as/ld), those grandchildren die too. This matters because they
  ## inherit the merged stdout pipe's write-end: killing only `p` leaves the
  ## pipe open as long as any grandchild survives, so `readOutputThread`'s
  ## blocked `readData` never sees EOF, never sends its terminal message,
  ## and `joinThread` in `runProcess` hangs forever waiting for a thread
  ## that cannot be force-detached.
  ##
  ## POSIX: `runProcess` arranges for `p` to be the leader of its OWN new
  ## process group (PGID == its own PID) by wrapping the real command in
  ## `setsid <exe> <args...>` — deliberately the ONLY mechanism used (see
  ## `runProcess`'s comment for why both `poDaemon` and a parent-side
  ## `setpgid` call were tried and dropped: the former is not just
  ## backend-gated but actively conflicts with `setsid` when both fire, and
  ## the latter always loses the race against the child's own
  ## already-completed exec). This works identically regardless of which
  ## internal osproc backend `startProcess` happens to use, which is what
  ## makes it toolchain-independent rather than gated like `poDaemon`.
  ## Every descendant `p` forks inherits that same PGID (a fork never
  ## changes process group on its own), so `killpg` reaches the
  ## grandchildren directly instead of relying on the immediate child to
  ## propagate anything.
  ##
  ## Because grouping now happens BEFORE this proc ever runs (inside
  ## `setsid`'s own pre-exec syscall), `p`'s actual group is read fresh via
  ## `getpgid` rather than *assumed* to equal its PID. That fresh read is
  ## also what makes the self-kill hazard structurally impossible: this
  ## proc additionally reads the HARVESTER'S OWN group (`getpgid(Pid(0))`)
  ## and refuses to call `killpg` at all unless `p`'s group is both valid
  ## (> 0, i.e. `getpgid` didn't fail) AND strictly different from ours. If
  ## the grouping above somehow didn't take (`setsid` missing from PATH, or
  ## some other unexpected failure) then `p` is still sitting in the
  ## harvester's own group, `childPgid == ownPgid`, and `killpg` is skipped
  ## entirely — it is not merely unlikely to hit the
  ## harvester's own group, the guard makes it impossible, because the one
  ## case that would aim `killpg` at our own group is exactly the case this
  ## `if` excludes. In that degraded case the fallback below (a plain
  ## single-PID `kill(p)`, always run) still kills the immediate child; only
  ## a grandchild that outlives `p` and keeps writing to the pipe would go
  ## unreached — strictly worse (a possible hang) but never a self-kill.
  ##
  ## Windows: `poDaemon` there only means "no console window" (no process-
  ## group equivalent in osproc), so there is no cheap in-stdlib group kill.
  ## `taskkill /F /T` is the best-effort tree-kill parity path — not
  ## exercised by CI, which runs Linux-only Docker.
  when defined(posix):
    # `getpgid`/`killpg` are raw `importc` wrappers around C library calls
    # (`<unistd.h>`/`<signal.h>`) — no Nim GC interaction, so the compiler
    # accepts them under this proc's own `{.gcsafe.}` pragma with no extra
    # `{.cast(gcsafe).}` needed; that's what makes it safe to call this
    # proc from `readOutputThread`'s worker thread.
    try:
      let childPid = Pid(processID(p))
      let childPgid = getpgid(childPid)
      let ownPgid = getpgid(Pid(0))
      if childPgid > Pid(0) and childPgid != ownPgid:
        # Safe: `childPgid` is demonstrably NOT the harvester's own group,
        # so this can never signal the harvester itself.
        discard killpg(childPgid, SIGKILL)
    except OSError:
      discard
  else:
    try:
      discard execCmd("taskkill /F /T /PID " & $processID(p))
    except OSError:
      discard
  # ALWAYS also signal the immediate child directly — the correct fallback
  # both when the group kill above was skipped (grouping failed, degraded
  # to single-PID) and as pure belt-and-suspenders when it wasn't (e.g. `p`
  # already reaped by the time `killpg` ran).
  try:
    if running(p): kill(p)
  except OSError:
    discard

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
      killProcessTree(args.process)
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
  # Grouping `p` into its OWN new process group (PGID == its own PID) is
  # what lets `killProcessTree` reach a grandchild compiler process via
  # `killpg` — see that proc's doc comment. Two mechanisms were tried
  # before arriving at the one actually used below; both are recorded here
  # because either one, alone, LOOKS reasonable and this comment exists so
  # nobody reintroduces them:
  #
  # 1. `poDaemon` in `startProcess`'s options: on osproc's `posix_spawn`
  #    backend this passes `POSIX_SPAWN_SETPGROUP` (new group, PGID == own
  #    PID) — race-free, in-kernel, before exec. But that backend is itself
  #    gated by `useProcessAuxSpawn = declared(posix_spawn) and not
  #    defined(useFork) and not defined(useClone) and not defined(linux)`
  #    in vanilla upstream osproc (e.g. `nimlang/nim:2.2.0`) — the trailing
  #    `not defined(linux)` makes this FALSE on standard Linux builds, so
  #    `poDaemon` silently does nothing there (this repo's pinned
  #    `ghcr.io/coreyleavitt/nim:2.2.10` image widens the gate to be
  #    Linux-inclusive, so `poDaemon` alone happens to suffice THERE, but
  #    this proc must not assume every downstream user's toolchain has that
  #    patch). Not merely insufficient on its own — see "What actually
  #    works" below for why it is actively HARMFUL once combined with the
  #    fix that covers the gap it leaves.
  # 2. A parent-side `setpgid(Pid(processID(p)), Pid(processID(p)))` call
  #    right after `startProcess` returns, to cover the fork/exec backend
  #    `poDaemon` misses. This is a DEAD END, empirically confirmed on
  #    `nimlang/nim:2.2.0`: Nim's own fork/exec spawner
  #    (`startProcessAuxFork` in `lib/pure/osproc.nim`) synchronizes with
  #    the child over a CLOEXEC-tagged error pipe — the parent blocks
  #    reading that pipe until the child's `exec*()` syscall either
  #    succeeds (closing the pipe via CLOEXEC) or fails (writing an errno
  #    into it) — so by the time `startProcess` returns control to this
  #    proc, the child has, by construction, ALREADY completed its exec.
  #    POSIX `setpgid` explicitly forbids a THIRD PARTY (the parent, here,
  #    trying to change ITS OWN CHILD's group after the fact) from changing
  #    a process's group once that process has exec'd — that's an EACCES,
  #    not a narrow race to win. Confirmed: this call always returned
  #    -1/EACCES(13) against `sh -c "sleep 30 & wait"` on `nimlang/nim:2.2.0`.
  #
  # What actually works: wrap the real command in `setsid <exe> <args...>`
  # (below), WITHOUT `poDaemon`. `setsid(1)`'s own `setsid()` syscall runs
  # INSIDE the wrapper's own process, before ITS OWN exec of the real
  # command — no cross-process race at all, since a process changing its
  # own group is unrestricted. It execs the real command in place (no
  # extra fork, hence no extra PID/PGID layer to lose track of — confirmed:
  # `setsid sh -c 'echo $$'` reports the SAME value as both its own pid and
  # its process-group id) PROVIDED it isn't already a process-group leader
  # when it tries; `setsid()` fails with EPERM on an existing leader, and
  # `setsid(1)`'s fallback for that is to fork a detached grandchild and
  # exit immediately itself (confirmed via `ps`: the wrapper's tracked PID
  # gets reparented to PID 1 nearly instantly) — silently orphaning
  # `runProcess`'s `p` from the real, still-running process it's supposed
  # to be tracking. This is EXACTLY what `poDaemon` would trigger on a
  # backend where it fires (`POSIX_SPAWN_SETPGROUP` already makes the
  # spawned process its own group leader before `setsid`'s exec even runs)
  # — confirmed empirically as a full regression back to ~30s on
  # `ghcr.io/coreyleavitt/nim:2.2.10` when `poDaemon` and the `setsid`
  # wrapper below were combined. A process freshly spawned by
  # `startProcess` WITHOUT `poDaemon` always inherits the PARENT's PGID
  # (never its own PID) on both backends, so it is never already a leader,
  # so `setsid`'s inner call always succeeds cleanly — this is why
  # `poDaemon` is deliberately NOT in the options set below, and doing so
  # is backend-independent by construction: it does not matter whether
  # `startProcess` used `posix_spawn` or fork/exec internally.
  var spawnExe = exe
  var spawnArgs = args
  when defined(posix):
    # R4-L2: one merged `when defined(posix):` block (finding/probe +
    # conditional reassignment together) rather than two separate blocks
    # bracketing the unconditional `spawnExe`/`spawnArgs` decls above —
    # cosmetic, behavior-preserving.
    let setsidPath = findExe("setsid")
    if setsidPath.len > 0:
      # Graceful degradation (same policy as this repo's MSVC C23 gate): if
      # `setsid` isn't on PATH (unusual on Linux — it ships in util-linux,
      # present on every image this repo targets — but some minimal/non-
      # Linux POSIX system might lack it), fall through to the plain,
      # unwrapped `exe`. `p` then simply keeps whatever group it inherits
      # (ours), and `killProcessTree`'s getpgid guard correctly refuses to
      # `killpg` in that case (see its doc comment), falling back to its
      # always-run single-PID `kill` — a real but bounded degradation (a
      # grandchild could keep the pipe open), never a crash and never a
      # self-kill hazard.
      spawnArgs = @[exe] & args
      spawnExe = setsidPath
  var p = startProcess(spawnExe, args = spawnArgs,
                        options = {poStdErrToStdOut, poUsePath})
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
        killProcessTree(p)
        # Fall through and keep polling: `killProcessTree` kills `p`'s
        # entire process group (see its doc comment above), not just `p`
        # itself, so the merged stdout pipe's write-end genuinely closes
        # even if `p` had forked a real compiler (grandchildren inherit
        # that pipe). That's what lets `readOutputThread`'s blocked read
        # return EOF promptly and send `rmkDone` — the loop above still
        # exits via the normal `finished = true` path, just with
        # `timedOut` recorded. A plain single-PID `kill(p)` would NOT be
        # enough here: it only signals the immediate child, leaving any
        # grandchild that still holds the pipe open free to keep it open
        # indefinitely — which is exactly the hang this fix closes.
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

const
  harvestInvariantDefines* = ["softlinkStrictVerify", "softlinkProbeGroundTruth",
                               "softlinkHarvestSession"]
    ## RFC-0003 round-2 review R2-1, single point: the three defines
    ## `compileProbe` itself adds to EVERY probe compile (RFC-0003 §4.1).
    ## Reserved against BOTH `compileProbe`'s `defines` parameter and
    ## `HarvestOptions.extraFlags` — no caller, internal or external, may
    ## set any of these; doing so (e.g. the shipped CLI's own documented
    ## `--extra-flag:-d:softlinkProbeGroundTruth=false`) would silently
    ## defeat ground-truth harvesting, since Nim applies the LAST `-d:`
    ## occurrence on its command line rather than erroring on a repeat.
    ##
    ## Exported (round-4 review R4-2): so doc-sync tests (tests/
    ## tharvest_cli.nim's usageText coverage test) and CLI documentation can
    ## derive the reserved-name list from source instead of hand-copying it,
    ## the same way `harvest_defaults.defaultDiagnosticsPinFlags` already
    ## keeps `defaultExtraFlags` in sync (stage-4 review M7). See
    ## `harvestReservedDefines` below for the flat combined list most doc-
    ## sync consumers actually want.

  harvestInternalOnlyDefines* = ["softlinkProbeOnly", "softlinkProbeExistence"]
    ## `compileProbe`'s own INTERNAL `defines`-PARAMETER vocabulary —
    ## legitimately passed there by `probeOutcomes`/`runCalibration`/the
    ## fast path (all in THIS module). Reserved only against
    ## `HarvestOptions.extraFlags`: an operator smuggling either name in via
    ## `--extra-flag`/a hand-built `HarvestOptions` corrupts probe identity
    ## the same way overriding an invariant define does, but the `defines`
    ## parameter itself must stay free for those internal callers. Exported
    ## for the same doc-sync reason as `harvestInvariantDefines` above.

  harvestReservedDefines* = @harvestInvariantDefines & @harvestInternalOnlyDefines
    ## Flat, combined list of every harvest-reserved define name, in the
    ## order a user-facing doc surface should enumerate them — for doc-sync
    ## tests (tests/tharvest_cli.nim's "usageText names every harvest-
    ## reserved define" test, round-4 review R4-2) and CLI documentation
    ## that only needs "which names are reserved", not "which scope(s)
    ## each name is reserved against". `rejectReservedDefineOverrides`
    ## below still reads the two split consts directly, since ITS logic
    ## genuinely depends on the scope distinction (`harvestInternalOnlyDefines`
    ## is legitimate in the `defines` parameter, never in `extraFlags`).

func defineSpecSetsName(spec, name: string): bool =
  ## `spec` is a bare `-d`/`--define` VALUE with no flag prefix, exactly the
  ## shape `compileProbe`'s `defines` parameter elements carry (e.g.
  ## `"softlinkProbeOnly=corpuslib_x"` or `"release"`) — true if it sets
  ## `name`, bare or with a `=value` suffix, allowing for any spelling of
  ## `name` Nim's OWN `-d:`/`--define` SYMBOL TABLE treats as the same
  ## define (round-5 review R5-1, correcting round-4's model): that table
  ## is `modeStyleInsensitive` (`options.nim`), dispatched via
  ## `cmpIgnoreStyle` — case is folded on EVERY character, INCLUDING the
  ## first, and underscores are stripped. This is the define-TABLE rule,
  ## not `nimIdentNormalize`'s SOURCE-identifier rule (which keeps the
  ## first character's case) — round 4 mistakenly used the latter, so
  ## `"SoftlinkProbeGroundTruth"` (capital-S) was wrongly treated as a
  ## different identifier from `"softlinkProbeGroundTruth"`, even though
  ## both set the identical Nim booldefine (empirically confirmed:
  ## `-d:Foo`, `-d:FOO=true`, `-d:f_o_o` all set booldefine `foo`). Fixed
  ## by comparing via `strutils.normalize` (full lowercase + strip
  ## underscores — the same relation `cmpIgnoreStyle` induces once both
  ## sides are folded this way) instead. Comparing the normalized NAME
  ## PORTION (up to the first `=`, if any) for FULL-STRING equality —
  ## rather than a prefix/startsWith check — is what keeps the boundary
  ## property: `strutils.normalize` of `"softlinkProbeGroundTruthX"` is
  ## `"softlinkprobegroundtruthx"`, never equal to
  ## `"softlinkprobegroundtruth"`, so an unrelated name merely sharing a
  ## prefix is never a false positive.
  let namePart = block:
    let eqIdx = spec.find('=')
    if eqIdx >= 0: spec[0 ..< eqIdx] else: spec
  namePart.normalize == name.normalize

func extraFlagSetsDefine(flag, name: string): bool =
  ## `flag` is a raw `nim c` command-line flag as it appears in
  ## `HarvestOptions.extraFlags` (e.g. `"-d:softlinkProbeGroundTruth=false"`
  ## or `"--passC:-Wall"`) — true if it's a `-d`/`--define` flag setting
  ## `name` (under `defineSpecSetsName`'s style-insensitive `normalize`
  ## equality, above — mirroring Nim's own `-d:`/`--define` symbol table,
  ## not the source-identifier rule; see round-5 review R5-1).
  ##
  ## RFC-0003 round-4 review R4-1: Nim's compiler dispatches `-d`/`--define`
  ## (and every other switch) by NORMALIZING the switch name itself —
  ## `strutils.normalize` (full lowercase + strip underscores) — before
  ## comparing it to the switch's canonical spelling, exactly the same
  ## normalization `nim --DE_FINE:foo` or `nim -D:foo` already receive on
  ## the real command line. The round-3 fix's 4-spelling `startsWith` list
  ## (`-d:`/`-d=`/`--define:`/`--define=`) was itself an under-claim of
  ## this: `-D:`, `--Define:`, `--DEFINE=`, `--de_fine:` are all genuine,
  ## equally-live spellings it silently missed (`-D` is C-preprocessor
  ## muscle memory — the most realistic one). This implementation instead
  ## mirrors Nim's own dispatch directly: split `flag` into a switch
  ## portion (everything after its leading dash(es), up to the first `:`
  ## or `=`) and a value portion, normalize the switch portion the same way
  ## Nim does, and compare it to `"d"`/`"define"`. A flag with no `:`/`=`
  ## separator at all (e.g. bare `"--define"`) sets no value and can't
  ## reference `name`, so it's not a match. Nothing about this claims to
  ## cover more than `-d`/`--define` — a `--passC:-d:foo`-style flag never
  ## matches, since its switch portion is `"passC"`, not `"d"`.
  ##
  ## Anything beyond what Nim's own switch/identifier normalization
  ## recognizes (a future `nim` CLI feature, a config-file define, etc.) is
  ## caught by defense in depth instead: `compileProbe` always appends its
  ## own reserved `-d:` flags LAST, and Nim applies only the last
  ## `-d`/`--define` occurrence for a given symbol regardless of spelling,
  ## so a scan gap here can never reopen Gap A — it can only downgrade a
  ## loud refusal to a silent (but still ground-truth-safe) no-op.
  if flag.len == 0 or flag[0] != '-':
    return false
  var i = 0
  while i < flag.len and flag[i] == '-':
    inc i
  let sepIdx = flag.find({':', '='}, i)
  if sepIdx < 0:
    return false
  let switchPart = flag[i ..< sepIdx].normalize
  if switchPart != "d" and switchPart != "define":
    return false
  defineSpecSetsName(flag[sepIdx + 1 .. ^1], name)

func reservedDefineMsg(spelling, name: string): string =
  "softlink harvest: refusing to compile — '" & spelling & "' attempts " &
  "to set the harvest-reserved define '" & name & "'. This define is a " &
  "harvest-session invariant that compileProbe itself adds to EVERY " &
  "probe compile (RFC-0003 §4.1); no caller may override it, silently " &
  "or otherwise (RFC-0003 round-2 review R2-1 — this is exactly how " &
  "the documented `--extra-flag:-d:softlinkProbeGroundTruth=false` " &
  "misuse would otherwise defeat ground truth on every probe, since " &
  "Nim silently applies the LAST `-d:` occurrence on its command line " &
  "rather than erroring on a repeat). Remove this flag."

proc rejectReservedDefineOverrides(defines, extraFlags: seq[string]) =
  ## RFC-0003 round-2 review R2-1, part (a) — the loud half of the fix: a
  ## caller cannot get this far with an explicit attempt to override a
  ## harvest-reserved define, whether spelled via the internal `defines`
  ## parameter or via `HarvestOptions.extraFlags` (which is exactly how the
  ## shipped CLI's `--extra-flag` reaches this proc). Part (b), the
  ## ordering fix below, is defense in depth for anything beyond what Nim's
  ## own switch normalization and define-table name rules recognize
  ## (round-4 review R4-1; name-matching corrected to the define-table's
  ## fully style-insensitive relation per round-5 review R5-1) — see
  ## `extraFlagSetsDefine`'s and `defineSpecSetsName`'s doc comments.
  for d in defines:
    for name in harvestInvariantDefines:
      if defineSpecSetsName(d, name):
        raise newException(HarvestError, reservedDefineMsg("-d:" & d, name))
  for f in extraFlags:
    for name in harvestInvariantDefines:
      if extraFlagSetsDefine(f, name):
        raise newException(HarvestError, reservedDefineMsg(f, name))
    for name in harvestInternalOnlyDefines:
      if extraFlagSetsDefine(f, name):
        raise newException(HarvestError, reservedDefineMsg(f, name))

proc compileProbe*(nimExe, modulePath, nimcacheRoot: string, opts: HarvestOptions,
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
  ##
  ## Exported (`*`), mirroring `runProcess`'s own precedent, so a single
  ## probe compile's behavior under caller-controlled flags can be tested
  ## directly (RFC-0003 §5.2 iii's integration-level strict-needle proof:
  ## `--passC:-U__GNUC__ --passC:-U__clang__` against a self-contained
  ## fixture, forcing the tier chain's otherwise-unreachable-on-Linux
  ## fallback) without needing a full dump/corpus-driven `harvest()` call.
  ##
  ## `-d:softlinkStrictVerify` is added to EVERY probe compile this proc
  ## makes, unconditionally (RFC-0003 §5.2 iii/§7 slice B1) — turning
  ## `verify.nim`'s otherwise-silent no-op fallback (an unsupported
  ## compiler/mode gracefully skipping verification) into the real
  ## `#error` needle `strictVerifyUnavailableNeedle` names, so a degraded
  ## verification tier is loud instead of a silent hole. Verified inert
  ## against every committed fixture corpus (round 2 of the RFC's review):
  ## on the gcc/clang toolchains this project targets, every probe reaches
  ## the `__GNUC__`/`__cplusplus` tier long before the fallback, so this
  ## define changes no generated C and no committed compile-count/golden
  ## fixture.
  ##
  ## `-d:softlinkProbeGroundTruth` + `-d:softlinkHarvestSession` are ALSO
  ## added to EVERY probe compile this proc makes, unconditionally
  ## (RFC-0003 §4.1/§4.3, stage-4 review findings M6/M2/L1) — this is now
  ## the SINGLE place that guarantees the RFC §4.1 invariant ("every
  ## compile [the harvester] issues... carries
  ## `-d:softlinkProbeGroundTruth`/`-d:softlinkHarvestSession`"), the same
  ## way the paragraph above makes `compileProbe` the single place that
  ## guarantees `-d:softlinkStrictVerify`. Previously the pair was
  ## assembled at each CALL SITE (`probeOutcomes`'s and the fast path's own
  ## local `groundTruthDefines` lets, plus one inline literal at the
  ## standard-path baseline) — the exact per-site smearing
  ## `effectiveVerifyWhen` (verify.nim) was built to prevent for
  ## `p.verifyWhen` reads, and it left three compiles (calibration's
  ## baseline, its pin-stripped retry, and the fast path's fallback
  ## baseline) omitting the defines entirely, contradicting the RFC's "no
  ## exceptions" framing. Folding both defines in here closes that gap
  ## structurally: NO call site needs to (or may) pass either define
  ## itself, so a future call site cannot omit them.
  ##
  ## RFC-0003 round-2 review R2-1 — "cannot omit" above is NOT the same
  ## claim as "cannot be overridden", and batch-1's doc comment conflated
  ## the two: Nim silently honors the LAST `-d:NAME[=VALUE]` occurrence on
  ## a command line, so appending caller `defines`/`opts.extraFlags` AFTER
  ## the three `args.add("-d:...")` lines below let a caller's own
  ## `-d:softlinkProbeGroundTruth=false` (e.g. via the shipped CLI's
  ## documented `--extra-flag`) silently win and defeat ground truth on
  ## every probe — the exact Gap-A hole this proc exists to close, reopened
  ## through its own front door. The fix is now two independent
  ## mechanisms, and the "structurally impossible" framing below is only
  ## true because of BOTH together:
  ##   1. `rejectReservedDefineOverrides` (above), called FIRST, scans both
  ##      `defines` and `opts.extraFlags` for any `-d`/`--define` spelling
  ##      of a harvest-reserved name and raises `HarvestError` naming the
  ##      offending flag — a loud, immediate refusal for any EXPLICIT
  ##      override attempt this scan recognizes (round-4 review R4-1: every
  ##      switch spelling Nim's own normalize dispatch accepts for
  ##      `-d`/`--define`; round-5 review R5-1: every name spelling Nim's
  ##      own `-d:` symbol table treats as the same define — the table is
  ##      `modeStyleInsensitive`, i.e. `cmpIgnoreStyle`/`strutils.normalize`
  ##      folding case on EVERY character including the first, NOT
  ##      `nimIdentNormalize`'s source-identifier rule, which round 4
  ##      mistakenly assumed — see `defineSpecSetsName`'s doc comment).
  ##   2. The three invariant `args.add("-d:...")` lines are placed AFTER
  ##      `defines`/`opts.extraFlags` are appended (immediately before
  ##      `modulePath`, below) rather than before — so even a spelling the
  ##      scan somehow failed to recognize would still
  ##      lose the last-wins race to the invariants, never win it. This is
  ##      pure defense in depth; the scan is the one that turns a misuse
  ##      attempt into a loud, actionable error instead of a silent no-op
  ##      that merely happens not to take effect.
  ## Calibration/baseline compiles (which pass `softlinkProbeOnly=-`,
  ## suppressing every proc's verification apparatus outright) receive the
  ## invariant pair too — inert there by construction, included on
  ## principle rather than as a special-cased exception, per the RFC's own
  ## "no flag, no opt-out" framing.
  rejectReservedDefineOverrides(defines, opts.extraFlags)
  var args = @["c", "--noLinking", "--nimcache:" & freshDir(nimcacheRoot)]
  for p in opts.nimPaths:
    args.add("--path:" & p)
  for d in includeDirs:
    args.add("--passC:" & opts.includeFlagPrefix & d)
  for d in defines:
    args.add("-d:" & d)
  args.add(opts.extraFlags)
  args.add("-d:softlinkStrictVerify")
  args.add("-d:softlinkProbeGroundTruth")
  args.add("-d:softlinkHarvestSession")
  args.add(modulePath)
  let (output, code) = runProcess(nimExe, args, opts.compileTimeoutMs, opts.maxOutputBytes)
  CompileOutcome(exitCode: code, output: output)

proc probeOutcomes*(nimExe, modulePath, versionDir, cName, nimcacheRoot: string,
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
  ## Exported (`*`) so RFC-0003 §5.2(iii)'s integration-level strict-needle
  ## proof and other direct probe-level tests can drive it without a full
  ## dump/corpus `harvest()` call.
  ##
  ## `compileCounter`, when non-nil, is incremented once per real compile
  ## this call performs (existence, verify, and — new in RFC-0003 §5.2(ii)
  ## — the retry-once compile when the verify probe fails) — `nil` (the
  ## default) leaves compiles uncounted, which is what `runCalibration`'s
  ## own calls rely on (calibration compiles are deliberately excluded from
  ## `HarvestResult.compileCount`, see that field's doc comment).
  ##
  ## RFC-0003 §5.2(ii), "decisive requires deterministic": a verify failure
  ## is never recorded on the strength of a SINGLE compile. The first
  ## failure's own output is checked for an infra-failure shape BEFORE any
  ## retry is attempted (a dying toolchain doesn't get a second compile
  ## burned on it); otherwise the identical compile is retried exactly
  ## once, and `resolveVerifyRetry` (pure, unit-tested independently) turns
  ## the pair of outcomes into either a decisive `ProbeOutcomes`, a
  ## non-decisive one with a loud warning (flaky), or a `HarvestError`
  ## (infra-shaped on retry too).
  # RFC-0003 §4.1/§7 slice A2 (defines now folded into `compileProbe` itself
  # per the stage-4 review's M6/M2/L1 fix — see that proc's doc comment):
  # ground truth is THE harvest semantic for the standard per-symbol
  # pipeline — no flag, no opt-out. Every compile this proc issues
  # (existence, verify, retry) carries BOTH `-d:softlinkProbeGroundTruth`
  # (defeat every since/until/verifyWhen gate and the probed symbol's own
  # vendored {.prototype.} decl, so the fact recorded is "the declared
  # signature is valid against this version's headers", independent of
  # whatever compatibility scaffolding the binding carries so ORDINARY
  # compiles work across versions) and `-d:softlinkHarvestSession` (the
  # misuse-guard's required companion — `genVerifyBlock` raises a macro
  # error if ground truth is set without it), unconditionally, because
  # `compileProbe` itself now adds them to every call it makes. This proc
  # is shared by BOTH the standard per-version loop AND the fast path's
  # failing-singleton fallback (`harvest`'s `plan.needsStandard` loop) —
  # RFC-0003 §7 slice A3 additionally relies on the SAME guarantee reaching
  # the fast path's OWN whole-module/bisection-group compile sites (see
  # this module's `harvest` doc comment), so the two paths' `facts` are
  # provably identical over every probed symbol, not just the gate-free
  # ones A2 alone could cover.
  let existence = compileProbe(nimExe, modulePath, nimcacheRoot, opts, @[versionDir],
    @["softlinkProbeOnly=" & cName, "softlinkProbeExistence"])
  if compileCounter != nil: inc compileCounter[]
  if existence.exitCode != 0:
    return ProbeOutcomes(stage: psAbsent)

  let verify = compileProbe(nimExe, modulePath, nimcacheRoot, opts, @[versionDir],
    @["softlinkProbeOnly=" & cName])
  if compileCounter != nil: inc compileCounter[]
  if verify.exitCode == 0:
    return ProbeOutcomes(stage: psVerified)

  let firstInfra = infraFailureReason(verify.output, verify.exitCode)
  if firstInfra.len > 0:
    raise newException(HarvestError,
      "softlink harvest: probe compile for '" & cName & "' at " & versionDir &
      " looks like an INFRASTRUCTURE failure, not a genuine signature " &
      "verification failure (" & firstInfra & ") — aborting the whole " &
      "harvest rather than risk recording a poisoned fact (the existing " &
      "maxOutputBytes/compileTimeoutMs philosophy: a dying toolchain " &
      "produces no manifest at all). Compiler output:\n" & verify.output)

  let retry = compileProbe(nimExe, modulePath, nimcacheRoot, opts, @[versionDir],
    @["softlinkProbeOnly=" & cName])
  if compileCounter != nil: inc compileCounter[]
  let decision = resolveVerifyRetry(cName, versionDir, verify.exitCode, retry.exitCode, retry.output)
  case decision.abort
  of true:
    raise newException(HarvestError, decision.abortReason)
  of false:
    if decision.warning.len > 0:
      stderr.writeLine(decision.warning)
    return decision.outcome

# ---------------------------------------------------------------------------
# Calibration preflight
# ---------------------------------------------------------------------------

proc writeCalibrationFixture(dir: string) =
  ## A tiny, self-contained known-answer quad, generated at runtime (not
  ## checked in) so the harvester works standalone after B8's packaging —
  ## see RFC-0001 SS4 B.2 design guidance point 3 (extended to a quad by
  ## RFC-0003 §5.3/§7 slice B3). One header pins three real declarations;
  ## the binding module pins FOUR procs against it:
  ## - `calib_verified` — signature matches exactly -> expect `fkVerified`.
  ## - `calib_absent`   — the header never declares it at all -> `fkAbsent`.
  ## - `calib_mismatched` — declared `int(int,int)`, bound as `cdouble` ->
  ##   `fkMismatch` (return-type drift; exercises the call-based signature
  ##   assert).
  ## - `calib_param_drifted` — declared `int(int*)`, bound with a `ptr
  ##   bool` parameter -> `fkMismatch` (parameter-only pointer drift;
  ##   exercises the `-Werror=incompatible-pointer-types` diagnostics pin —
  ##   see `calibParamDriftedSym`'s own doc comment above for why this
  ##   symbol exists and why there is no fifth).
  writeFile(dir / "calib.h", """
#ifndef SOFTLINK_HARVEST_CALIB_H
#define SOFTLINK_HARVEST_CALIB_H
int calib_verified(int a, int b);
int calib_mismatched(int a, int b);
int calib_param_drifted(int *p);
#endif
""")
  writeFile(dir / "calib_binding.nim", """
import softlink

dynlib "libsoftlinkharvestcalib.so":
  proc calib_verified(a: cint, b: cint): cint {.cdecl, header: "calib.h".}
  proc calib_absent(a: cint): cint {.cdecl, header: "calib.h".}
  proc calib_mismatched(a: cint, b: cint): cdouble {.cdecl, header: "calib.h".}
  proc calib_param_drifted(p: ptr bool): cint {.cdecl, header: "calib.h".}
""")

proc runCalibration*(opts: HarvestOptions = defaultHarvestOptions()): CalibrationOutcome =
  ## RFC-0001 SS4 B.2 calibration preflight: runs the known-verified/known-
  ## absent/known-mismatched/known-param-drifted quad (RFC-0003 §5.3/§7
  ## slice B3 added the fourth member, `calib_param_drifted`) through the
  ## IDENTICAL pipeline `harvest` uses and requires exactly the expected
  ## four classifications. This is the structural guard against a degraded
  ## verification tier (default-mode MSVC's graceful no-op fallback
  ## silently makes EVERY probe trivially succeed, poisoning results with
  ## false `verified`), a warning-only implicit-declaration configuration,
  ## or the diagnostics-severity pin (`-Werror=incompatible-pointer-types`)
  ## being absent/stripped/ineffective for parameter-only pointer drift.
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
    # RFC-0003 §5.2(i): split the diagnosis when diagnostics pin flags are
    # present. Without this, an old toolchain that doesn't recognize a pin
    # flag's exact spelling (an unrecognized `-Werror=<name>` is itself a
    # hard error on GCC, independent of any header content) fails HERE,
    # before any verification define is even active, and got the generic
    # "toolchain/PATH itself" message below — sending an operator debugging
    # the wrong layer (nothing is wrong with the compiler itself; the flag
    # spelling is what this toolchain rejects). Retry the IDENTICAL
    # baseline once with only the pin flags stripped (`isDiagnosticsPinFlag`
    # — compiler-selection flags like `--cc:vcc` stay in place, see that
    # func's doc comment): if THAT compile succeeds, the pins are the
    # culprit.
    let pinFlags = opts.extraFlags.filterIt(isDiagnosticsPinFlag(it))
    if pinFlags.len > 0:
      var strippedOpts = opts
      strippedOpts.extraFlags = opts.extraFlags.filterIt(not isDiagnosticsPinFlag(it))
      let baselineNoPins = compileProbe(nimExe, modulePath, scratch, strippedOpts,
        @[scratch], @["softlinkProbeOnly=-"])
      if baselineNoPins.exitCode == 0:
        return CalibrationOutcome(ok: false, diagnosis:
          "softlink harvest calibration: the BASELINE compile of the " &
          "built-in calibration fixture failed WITH these diagnostics pin " &
          "flags applied (" & pinFlags.join(" ") & "), but SUCCEEDED when " &
          "retried WITHOUT them — this is a diagnostics pin flag rejected " &
          "by this toolchain (RFC-0003 §5.2 i), not a broken toolchain/PATH. " &
          "Check HarvestOptions.extraFlags against this compiler's actual " &
          "capabilities/version. Compiler output (with pins):\n" & baseline.output)
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
    calibParamDriftedSym: fkMismatch,
  }.toTable

  var observed = initTable[string, FactKind]()
  for sym in [calibVerifiedSym, calibAbsentSym, calibMismatchedSym, calibParamDriftedSym]:
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
  ## standard existence/verify probes' teeth against a known-answer quad
  ## (RFC-0001 SS4 B.2; RFC-0003 §7 slice B3), and `opts.fastPath` only
  ## changes how the CORPUS
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
  ##
  ## RFC-0003 §7 slice A3: both ground-truth defines now reach the fast
  ## path's OWN compile sites too — the whole-module compile below AND
  ## `groupVerifies`' bisection-group compiles — closing the gap A2
  ## deliberately left open (a gate-masked drift used to survive the fast
  ## path's own group-level shortcuts even though the standard path,
  ## sharing `probeOutcomes`, already defeated it). Stage-4 review (M6):
  ## both defines are now folded into `compileProbe` itself, so neither
  ## site here mentions them by name any more — see that proc's doc
  ## comment for the single point of guarantee. One exclusion remains,
  ## load-bearing (§4.3's "stamp exclusion"): a `header`+`prototype` proc's
  ## vendored decl compiles cleanly whether or not the header still declares the symbol,
  ## and the whole-module compile carries NO `softlinkProbeOnly` at all —
  ## so `isProbedTarget` (the predicate gating the vendored-decl
  ## suppression, `verify.nim`) is false for every proc there regardless of
  ## ground truth, and the decl is ALWAYS emitted. A passing whole-module
  ## compile is therefore not evidence for such a proc; it always falls
  ## through to an individual `probeOutcomes` call below, whether the
  ## whole-module compile passed OR failed. Bisection GROUP compiles are
  ## different and need no such exclusion: `softlinkProbeOnly` names an
  ## explicit multi-symbol list there, so `isProbedTarget` (and the
  ## suppression it gates) is independently true for EVERY member named in
  ## a group, prototype-carrying or not — a passing group compile really
  ## does mean every member, prototype-carrying members included,
  ## individually verifies against the header alone. `probeTargets` is fed
  ## to `bisectPlan` unfiltered for exactly this reason.
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
    # `isCorpusTrackable` (softlink/versions, code-review finding #21) is
    # the SAME predicate `softlink/directives.applyCompatManifest`'s own
    # `trackable` list uses on the consumption side — extracted so the two
    # sides cannot silently drift apart. The three `elif` arms below are
    # unchanged: they only choose WHICH diagnostic reason to record for a
    # symbol the shared predicate already said is not trackable.
    if isCorpusTrackable(p.noverify, p.header.len > 0):
      probeTargets.add(p)
      result.probedSymbols.add(p.cName)
    elif p.noverify:
      result.skipped.add SkipNote(cname: p.cName,
        reason: "noverify — excluded from header verification entirely, " &
                "nothing to probe")
    elif p.prototype.len > 0:
      result.skipped.add SkipNote(cname: p.cName,
        reason: "prototype-only (no header) — corpus-invariant, skipped")
    else:
      result.skipped.add SkipNote(cname: p.cName,
        reason: "no header or prototype recorded — nothing to probe")

  for v in result.versions:
    let versionDir = corpusDir / v

    if opts.fastPath:
      # RFC-0001 SS4 B.2, optional fast-path (slice B7). See `harvest`'s own
      # doc comment for the full algorithm; this block is its I/O.
      #
      # RFC-0003 §7 slice A3: both this compile AND `groupVerifies`' own
      # compiles (below) carry the ground-truth defines — folded into
      # `compileProbe` itself now (stage-4 review M6), so no defines are
      # passed here by name — see `harvest`'s doc comment for why the fast
      # path needs this reaching all the way here, not just `probeOutcomes`.
      let fast = compileProbe(nimExe, dump.modulePath, scratchRoot, opts,
        @[versionDir], @[])
      inc result.compileCount
      if fast.exitCode == 0:
        result.baselineOk[v] = true
        for p in probeTargets:
          var facts = result.facts.getOrDefault(p.cName)
          if p.prototype.len > 0:
            # RFC-0003 §4.3 stamp exclusion (see `harvest`'s doc comment):
            # a passing whole-module compile is not evidence for a
            # prototype-carrying proc — its vendored decl is unconditionally
            # emitted in this compile shape (no `softlinkProbeOnly` at all),
            # so removal is invisible to it regardless of ground truth. Its
            # own existence probe (inside `probeOutcomes`) is the only
            # decisive removal detector.
            let o = probeOutcomes(nimExe, dump.modulePath, versionDir, p.cName,
              scratchRoot, opts, addr result.compileCount)
            facts[v] = classify(o)
          else:
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
      #
      # RFC-0003 §7 slice A3: `groupVerifies` carries both ground-truth
      # defines too (via `compileProbe` itself, stage-4 review M6 — not
      # passed here by name), so a gate-masked drift that survives the
      # whole-module compile FAILING alongside some other symbol cannot be
      # re-masked once bisection isolates it into its own group — the exact
      # hole A2 deliberately left open here (`harvest`'s doc comment). Unlike the
      # whole-module compile above, `probeTargets` is bisected UNFILTERED
      # (prototype-carrying procs included): `softlinkProbeOnly` names an
      # explicit multi-symbol list in every group compile, so
      # `verify.nim`'s `isProbedTarget` — and the vendored-decl suppression
      # it gates under ground truth — is independently true for every
      # member actually named in a given group, prototype-carrying or not.
      # A passing group compile is therefore genuine evidence for ALL of
      # its members, which is what lets this fixture's two same-gate
      # symbols (`corpuslib_gated_until`/`corpuslib_gated_crosscheck`, both
      # closing at 2.0.0) bisect down to two independent failing
      # singletons rather than needing a dedicated third fixture symbol.
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
    #
    # RFC-0003 §7 slice A2 (stage-4 review M6/M2): the standard baseline
    # compile ALSO carries both ground-truth defines, for the same "every
    # probe compile this path issues" reason `probeOutcomes` does above —
    # inert here by construction (`softlinkProbeOnly=-` suppresses every
    # proc's verification apparatus outright, so no gate is ever evaluated
    # in this specific compile), but consistent with the RFC's "no flag, no
    # opt-out" framing rather than a special-cased exception. `compileProbe`
    # itself now guarantees this (M6's fix), so this call site no longer
    # spells either define by name.
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

  # RFC-0003 §2/§7 slice C1: `harvesterVersion` is OMITTED from the
  # `"harvest"` object entirely when `meta.harvesterVersion` is empty (the
  # SAME "omit unless present" convention `header` above already uses for
  # unbounded interval sides) — never emitted as an empty string. This is
  # what keeps every pre-C1 pinned-`HarvestMeta` golden-fixture test in
  # tests/tharvest.nim byte-for-byte unchanged (none of them set this new
  # field), while `defaultHarvestMeta()` (real harvests) always stamps it.
  var harvestObj = %*{"toolchain": meta.toolchain, "tier": meta.tier,
                       "abi": meta.abi, "date": meta.date}
  if meta.harvesterVersion.len > 0:
    harvestObj["harvesterVersion"] = %meta.harvesterVersion

  %*{
    "schema": 1,
    "lib": r.baseName.toLowerAscii(),
    "harvest": harvestObj,
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
    harvesterVersion: softlinkVersion,
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
