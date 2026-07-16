# Package
version       = "0.7.0"
author        = "Corey Leavitt"
description   = "Type-safe optional dynamic library bindings for Nim"
license       = "Apache-2.0"
srcDir        = "src"

# Dependencies
requires "nim >= 2.0.0"

import std/json
import std/strutils
import "src/softlink/versions"

proc validateProbeJson(path, expectKind, expectBaseName: string) =
  ## RFC-0001 §4 B.1 nimble-task check: schema validation for one
  ## `<Base>.probes.json` file written by `-d:softlinkDumpProbes=<dir>`.
  ## Checks existence, valid JSON, every required top-level/per-proc key
  ## present, AND no unexpected extra key (the guard against an accidental
  ## source-text/repr field creeping back into the schema — see the RFC's
  ## round-2 "no source text" note). OS-agnostic (plain JSON key
  ## inspection, not compiler-diagnostic-wording), so the SAME call works
  ## unchanged from all three OS branches below, unlike every grep/findstr
  ## fixture check in this file.
  if not fileExists(path):
    quit("softlink: RFC-0001 slice B1 expected probe-facts file to exist: " & path)
  let j = parseJson(readFile(path))
  const topKeys = ["schemaVersion", "kind", "modulePath", "libPattern",
                    "baseName", "procs"]
  for key in topKeys:
    if not j.hasKey(key):
      quit("softlink: RFC-0001 slice B1: " & path &
           " missing required top-level key '" & key & "'")
  if j.len != topKeys.len:
    quit("softlink: RFC-0001 slice B1: " & path &
         " has unexpected top-level key(s) beyond the schema: " & $j)
  if j["kind"].getStr != expectKind:
    quit("softlink: RFC-0001 slice B1: " & path & " kind mismatch: expected '" &
         expectKind & "', got '" & j["kind"].getStr & "'")
  if j["baseName"].getStr != expectBaseName:
    quit("softlink: RFC-0001 slice B1: " & path &
         " baseName mismatch: expected '" & expectBaseName & "', got '" &
         j["baseName"].getStr & "'")
  if j["modulePath"].getStr.len == 0:
    quit("softlink: RFC-0001 slice B1: " & path & " has an empty modulePath")
  if j["procs"].kind != JArray or j["procs"].len == 0:
    quit("softlink: RFC-0001 slice B1: " & path & " has no procs array (or it's empty)")
  const procKeys = ["nimName", "cName", "header", "prototype", "verifyWhen",
                     "optional", "noverify", "noverifyReason", "since"]
  for p in j["procs"]:
    for key in procKeys:
      if not p.hasKey(key):
        quit("softlink: RFC-0001 slice B1: " & path &
             " has a proc entry missing required key '" & key & "': " & $p)
    if p.len != procKeys.len:
      quit("softlink: RFC-0001 slice B1: " & path &
           " has a proc entry with unexpected extra key(s) — possible " &
           "source-text leak: " & $p)
  echo "softlink: RFC-0001 slice B1: validated " & path

proc expectCompileFailure(cmd: string) =
  ## RFC-0001 slice A4: assert a compile FAILS by exit code alone. Every
  ## other tfail_* check in this file greps compiler/softlink output for a
  ## specific diagnostic string via `exec cmd | grep -q ...` — `exec`
  ## itself raises (failing the task) on a nonzero exit, so piping through
  ## a grep that succeeds exactly when the expected wording is present is
  ## how those checks turn "found the message" into "task step passes".
  ## That trick is unavailable here on purpose: A4's failure is the C/C++
  ## compiler's OWN diagnostic for a redeclaration conflict (wording varies
  ## by compiler/version — gcc/clang say "conflicting types for ...", MSVC
  ## says C2371), not a fixed softlink string, so nothing portable to grep
  ## for exists across all four CI legs. `gorgeEx` (unlike `exec`) returns
  ## the exit code instead of raising on failure, so the polarity can be
  ## inverted directly: this check PASSES when the compile FAILS.
  ##
  ## RFC-0001 slice A9: hoisted to file scope (was local to `task test`) so
  ## `task testMsvcExitCodes` below can share it verbatim — no logic
  ## duplication between the two tasks. Behavior is unchanged.
  let (output, code) = gorgeEx(cmd)
  if code == 0:
    echo output
    quit("softlink: RFC-0001 slice A4 expected a compile FAILURE (header " &
         "vs. prototype conflict on testlib_add) but the compile " &
         "SUCCEEDED: " & cmd)

proc writeManifestFromTemplate(tmplPath, outPath: string) =
  ## RFC-0001 §B.5, slice B6a design guidance: materialize a `*.tmpl.json`
  ## compat-manifest fixture (tracked) into its real, gitignored
  ## `*.compat.json` path, substituting a `${ABI}` placeholder with THIS
  ## CI leg's real target ABI tag — computed via `softlink/versions.abiTag`,
  ## the IDENTICAL function `dynlib`/`verifyProcs`'s own ABI check calls at
  ## macro-expansion time (one shared definition, imported at the top of
  ## this file) — so a fixture authored once passes the ABI check on every
  ## OS leg, not just the one it was written on. A template with no
  ## `${ABI}` placeholder (e.g. `testlib_abi_mismatch.tmpl.json`, whose abi
  ## is deliberately fixed and wrong on every real target) round-trips
  ## unchanged.
  writeFile(outPath, readFile(tmplPath).replace("${ABI}", abiTag()))

proc expectManifestCompileOk(cmd: string, mustContain, mustNotContain: openArray[string]) =
  ## RFC-0001 §B.5/§B.5a, slice B6a: assert `cmd` (a compile invocation)
  ## SUCCEEDS, and its output contains every string in `mustContain` and
  ## none in `mustNotContain`. Every manifest-consumption diagnostic is
  ## softlink's OWN text, but — unlike this file's other softlink-string
  ## checks, which grep/findstr-split per OS — this asserts at the
  ## NimScript level directly (`gorgeEx` + plain `in`), the same trick
  ## `expectCompileFailure`/`expectAnchor` above already use, so ONE call
  ## works identically from all three OS branches below.
  let (output, code) = gorgeEx(cmd)
  if code != 0:
    echo output
    quit("softlink: RFC-0001 slice B6a expected a compile SUCCESS: " & cmd)
  for s in mustContain:
    if s notin output:
      echo output
      quit("softlink: RFC-0001 slice B6a expected compile output to " &
           "contain '" & s & "': " & cmd)
  for s in mustNotContain:
    if s in output:
      echo output
      quit("softlink: RFC-0001 slice B6a expected compile output to NOT " &
           "contain '" & s & "': " & cmd)

proc expectManifestCompileFail(cmd: string, mustContain: openArray[string]) =
  ## The failure-polarity mirror of `expectManifestCompileOk` above.
  let (output, code) = gorgeEx(cmd)
  if code == 0:
    echo output
    quit("softlink: RFC-0001 slice B6a expected a compile FAILURE: " & cmd)
  for s in mustContain:
    if s notin output:
      echo output
      quit("softlink: RFC-0001 slice B6a expected compile output to " &
           "contain '" & s & "': " & cmd)

proc expectWrapperBeforeLoad(cmd: string) =
  ## RFC-0001 §9/§C.1, slice C1a pinning check: in the macro's expanded
  ## output, the first wrapper proc (`proc foo(...)`) must textually precede
  ## `proc loadFoo(): LoadResult`. This is the exact property C1b's future
  ## `versionProbe:` directive depends on — its body is spliced INTO the
  ## generated `loadX` and may call the block's own wrappers, which would be
  ## a use-before-declaration at the Nim top level if `loadX` still emitted
  ## first. `--expandMacro:dynlib` against the existing
  ## `tests/thint_noverify.nim` fixture (derived base name "Foo", first proc
  ## "foo") reliably reproduces the full expanded statement list in Nim's
  ## `[ExpandMacro]` hint, so a plain substring-index comparison at the
  ## NimScript level — no grep/findstr split needed, same trick
  ## `expectManifestCompileOk` above already uses — works identically on all
  ## three OS legs.
  let (output, code) = gorgeEx(cmd)
  if code != 0:
    echo output
    quit("softlink: RFC-0001 slice C1a expected a compile SUCCESS: " & cmd)
  let wrapperIdx = output.find("\nproc foo(")
  let loadIdx = output.find("\nproc loadFoo(")
  if wrapperIdx < 0:
    echo output
    quit("softlink: RFC-0001 slice C1a expected to find wrapper proc " &
         "'foo' in the macro expansion: " & cmd)
  if loadIdx < 0:
    echo output
    quit("softlink: RFC-0001 slice C1a expected to find 'proc loadFoo' " &
         "in the macro expansion: " & cmd)
  if not (wrapperIdx < loadIdx):
    echo output
    quit("softlink: RFC-0001 slice C1a expected wrapper proc 'foo' to " &
         "precede 'proc loadFoo' in the generated code (codegen order: " &
         "vars -> wrappers -> loadX), but it didn't: " & cmd)

proc corpusBaseName(path: string): string =
  ## Last path component of a NimScript `listDirs`/`listFiles` result
  ## (`"tests/corpus/1.0.0"` -> `"1.0.0"`). NimScript's directory walkers
  ## consistently return forward-slash-joined paths on every OS this task
  ## runs on (the existing `walkGenSources` helper above already relies on
  ## the same assumption for `.c`/`.cpp` suffix checks), so a plain `rfind`
  ## on `'/'` is enough — no `std/os` import needed.
  let i = path.rfind('/')
  if i < 0: path else: path[i + 1 .. ^1]

proc runCorpusChecks() =
  ## RFC-0001 slice B3a: validates the fixture corpus at tests/corpus has
  ## every property the (not-yet-written) slice B3 harvester will depend
  ## on. This is this slice's ENTIRE test surface — no harvester code, no
  ## classification loop, just proof the fixtures can exercise all four
  ## classification outcomes. See tests/corpus/README.md for the full
  ## classification narrative.
  const corpusDir = "tests/corpus"
  const corpusJsonPath = corpusDir & "/corpus.json"
  const b3aTag = "softlink: RFC-0001 slice B3a: "

  if not fileExists(corpusJsonPath):
    quit(b3aTag & "expected corpus provenance file to exist: " & corpusJsonPath)
  let j = parseJson(readFile(corpusJsonPath))
  if not j.hasKey("corpus") or j["corpus"].kind != JArray or j["corpus"].len == 0:
    quit(b3aTag & corpusJsonPath & " missing a non-empty top-level 'corpus' array")
  let entries = j["corpus"]

  # Disk-side: exactly the version directories actually present.
  var diskVersions: seq[string] = @[]
  for d in listDirs(corpusDir):
    diskVersions.add(corpusBaseName(d))

  # Manifest-side: validate each entry's shape, and the exactly-one-prepare
  # invariant, while collecting the versions it names.
  var manifestVersions: seq[string] = @[]
  var prepareCount = 0
  for entry in entries:
    if not entry.hasKey("version") or entry["version"].kind != JString:
      quit(b3aTag & "a corpus.json entry is missing a string 'version': " & $entry)
    let ver = entry["version"].getStr
    # Validated against the REAL contract slice B0 shipped
    # (src/softlink/versions.parseVersion), not a lexical approximation —
    # confirmed empirically that importing that module from a nimble task
    # works fine (nimble's NimScript VM, unlike bare macro/VM compile-time
    # code, has a working `getCurrentDir`-style environment; see the
    # `dumpProbesDir` comment below for the general asymmetry). A version
    # string this corpus records but the shared comparator can't parse
    # would silently break B4's interval compression later, so failing
    # loudly here is exactly the guard this slice is supposed to provide.
    if parseVersion(ver).isNone:
      quit(b3aTag & "corpus.json version '" & ver &
           "' does not parse under softlink/versions.parseVersion")
    manifestVersions.add(ver)
    if not entry.hasKey("source") or entry["source"].kind != JString:
      quit(b3aTag & "corpus.json entry for version '" & ver & "' is missing a string 'source'")
    let src = entry["source"].getStr
    let atPos = src.find('@')
    if not src.startsWith("git:") or atPos < 0:
      quit(b3aTag & "corpus.json entry for version '" & ver &
           "' has a malformed 'source' (expected 'git:owner/repo@<sha>'): " & src)
    let sha = src[atPos + 1 .. ^1]
    var shaOk = sha.len == 40
    if shaOk:
      for c in sha:
        if c notin {'0'..'9', 'a'..'f', 'A'..'F'}:
          shaOk = false
          break
    if not shaOk:
      quit(b3aTag & "corpus.json entry for version '" & ver &
           "' has a 'source' whose commit hash is not 40 hex characters: " & src)
    if entry.hasKey("prepare"):
      if entry["prepare"].kind != JString or entry["prepare"].getStr.len == 0:
        quit(b3aTag & "corpus.json entry for version '" & ver &
             "' has a non-string or empty 'prepare'")
      inc prepareCount

  if prepareCount != 1:
    quit(b3aTag & "expected exactly ONE corpus.json entry with a 'prepare' " &
         "hook (the prepare-hook example the slice brief calls for), found " &
         $prepareCount)

  # Disk <-> manifest must name exactly the same set of versions.
  for v in manifestVersions:
    if v notin diskVersions:
      quit(b3aTag & "corpus.json names version '" & v &
           "' but tests/corpus/" & v & "/ does not exist on disk")
  for v in diskVersions:
    if v notin manifestVersions:
      quit(b3aTag & "tests/corpus/" & v &
           "/ exists on disk but corpus.json has no entry for it")
  if diskVersions.len != 3:
    quit(b3aTag & "expected exactly 3 corpus version directories " &
         "(1.0.0, 2.0.0, 3.0.0 per the slice brief), found " &
         $diskVersions.len & ": " & $diskVersions)

  # Each version directory contains EXACTLY one file, testlib.h — the name
  # the future B3 binding module's `#include "testlib.h"` will resolve
  # against once the corpus dir is prepended via `--passC:-I`.
  for v in diskVersions:
    let files = listFiles(corpusDir & "/" & v)
    if files.len != 1 or corpusBaseName(files[0]) != "testlib.h":
      quit(b3aTag & "tests/corpus/" & v &
           "/ must contain exactly one file, testlib.h — found: " & $files)

  # Compile-behavior invariant: the classification table's baseline row.
  # A trivial TU including "testlib.h" must compile with 1.0.0 and 2.0.0
  # prepended, and must FAIL with 3.0.0 prepended (the broken-include
  # version) — the executable proof this corpus can actually drive a
  # baseline-fails-so-everything-classifies-`unknown` outcome, not merely
  # a header comment asserting it does.
  const scratchTu = corpusDir & "/_b3a_compile_check.c"
  writeFile(scratchTu, "#include \"testlib.h\"\nint main(void) { return 0; }\n")
  # Mirrors this task's OWN per-OS compiler choice for building testlib.c
  # (gcc on the linux and windows-mingw branches below, cc on macosx) so
  # this check exercises the SAME toolchain the rest of the suite already
  # depends on, not a fresh assumption. `-fsyntax-only` is supported by
  # both gcc and clang (macOS's `cc`) and needs no object/link step —
  # exactly a "does this TU compile" question, nothing more.
  const corpusCc = when defined(windows): "gcc" elif defined(macosx): "cc" else: "gcc"
  proc corpusCompiles(version: string): bool =
    let (_, code) = gorgeEx(corpusCc & " -fsyntax-only -I " & corpusDir &
      "/" & version & " " & scratchTu)
    code == 0
  if not corpusCompiles("1.0.0"):
    rmFile(scratchTu)
    quit(b3aTag & "expected tests/corpus/1.0.0/testlib.h to compile cleanly, it did not")
  if not corpusCompiles("2.0.0"):
    rmFile(scratchTu)
    quit(b3aTag & "expected tests/corpus/2.0.0/testlib.h to compile cleanly, it did not")
  if corpusCompiles("3.0.0"):
    rmFile(scratchTu)
    quit(b3aTag & "expected tests/corpus/3.0.0/testlib.h (the broken-include " &
         "version) to FAIL to compile, but it compiled cleanly")
  rmFile(scratchTu)

  # Signature-change invariant: corpuslib_changed's declaration text must
  # differ between 1.0.0 and 2.0.0 (the deliberate signature change), while
  # corpuslib_stable's must be identical (the control) — a grep-level check
  # via plain readFile/`in`, no shell tool needed.
  let text1 = readFile(corpusDir & "/1.0.0/testlib.h")
  let text2 = readFile(corpusDir & "/2.0.0/testlib.h")
  const stableDecl = "int corpuslib_stable(int a, int b);"
  const changedDecl1 = "int corpuslib_changed(int a);"
  const changedDecl2 = "double corpuslib_changed(int a);"
  if stableDecl notin text1 or stableDecl notin text2:
    quit(b3aTag & "expected the IDENTICAL corpuslib_stable declaration in " &
         "both 1.0.0/testlib.h and 2.0.0/testlib.h")
  if changedDecl1 notin text1:
    quit(b3aTag & "expected 1.0.0/testlib.h to declare '" & changedDecl1 & "'")
  if changedDecl2 notin text2:
    quit(b3aTag & "expected 2.0.0/testlib.h to declare '" & changedDecl2 & "'")
  if changedDecl1 in text2:
    quit(b3aTag & "expected 2.0.0/testlib.h's corpuslib_changed declaration " &
         "to differ from 1.0.0's, but 1.0.0's text is still present in 2.0.0")

  echo "softlink: RFC-0001 slice B3a: validated tests/corpus (" &
       $diskVersions.len & " versions, prepare-hook on 1)"

proc runHarvesterCheck() =
  ## RFC-0001 slice B3: the harvester classification loop, real end to end —
  ## `tests/tharvest.nim` (a compiled Nim program, NOT a NimScript check like
  ## every other `run*Checks` proc in this file) generates its own B.1
  ## probe-facts dump for `tests/tharvest_binding.nim` via a real
  ## `-d:softlinkDumpProbes=<dir>` compile, then feeds that dump to
  ## `tools/harvest/harvester.nim`'s `harvest()` and asserts the full
  ## classification matrix against `tests/corpus` (slice B3a) via
  ## `std/unittest` `check`s — plus the pure `classify()` decision table
  ## (every row, including the row this integration can't cheaply reach:
  ## a verify failure WITHOUT softlink's own assert message -> `unknown`)
  ## and the calibration preflight. `std/unittest` sets a nonzero program
  ## exit on any failed `check` (same mechanism `nim c -r ... test_softlink`
  ## already relies on above), so `exec` here fails the task exactly like
  ## every other check in this file.
  ##
  ## Real cost, unlike this file's other (compile-only or single-compile)
  ## checks: each `harvest()`/`runCalibration()` call is a handful of REAL
  ## `nim c --noLinking` subprocess compiles (baseline once per corpus
  ## version, existence+verify per probed symbol) — roughly 20 compiles for
  ## this fixture, on the order of a minute of wall time. Linux/gcc only
  ## (the slice's stated required minimum leg; RFC-0001 §9 B3's MSVC
  ## coverage is the calibration-REFUSAL check in `task testMsvcExitCodes`
  ## below, a much cheaper single-preflight run) — not wired into the
  ## macOS/windows-mingw branches: doubling this cost on every CI leg for a
  ## mechanism that doesn't vary by OS wasn't judged worth it; revisit if
  ## Stage B ships a regression those legs would have caught.
  ##
  ## RFC-0001 slice B8: `tests/tharvest_cli.nim` unit-tests
  ## `tools/harvest/harvest_cli.nim`'s `parseHarvestCli` — a PURE function
  ## over `seq[string]`, zero subprocess/filesystem access — so it costs
  ## well under a second, unlike the ~1-minute real-compile suite above.
  ## Run right alongside it (same `runHarvesterCheck` proc) so both of this
  ## slice's suites are exercised by the one `task test` call site below.
  exec "nim c -r --path:src tests/tharvest_cli.nim"
  exec "nim c -r --path:src tests/tharvest.nim"

task test, "Run tests":
  # testlib.c is compiled under several names to exercise deriveLibPattern:
  #   libtestlib.*  — explicit-pattern block (verbatim escape hatch)
  #   libmagic.*    — bare logical name "magic" resolves here
  #   libvern.so.3  — runtime-only versioned soname (Linux; no bare symlink)
  # Negative compile tests (grep/findstr exit nonzero if the expected message
  # is absent, failing the task — including if the file unexpectedly compiles):
  # - #14: a duplicate dynlib block must fail with the clear guard error,
  #   not a raw redefinition leaking from softlink.nim.
  # - verifyWhen: a TRUE gate condition must verify at full strength — a
  #   wrong signature must still fail the C compile with "signature mismatch".
  # - verifyWhen+noverify on one proc is contradictory → macro must error.
  # - RFC-0001 slice A1: prototype+noverify on one proc is contradictory →
  #   macro must error (both select a declaration source).
  # - RFC-0001 slice A3: a {.prototype.}-verified proc whose Nim signature
  #   disagrees with the vendored prototype must fail with "signature
  #   mismatch" — same diagnostic wording as the header-driven case, since
  #   both go through the same call-based _Static_assert chain.
  # Diagnostic tests: {.noverify.} symbols must be enumerated at compile time —
  # a Hint normally, upgraded to a Warning under -d:softlinkStrictVerify.
  # Positive C-inspection check (RFC-0001 slice A2): a {.prototype.}-only
  # proc must emit a real `extern` declaration into the generated C, proving
  # verification actually ran against it (not merely compiled by accident).
  # RFC-0001 slice A4: {.header.} and {.prototype.} coexist (cross-checking,
  # A1/A2 — testlib_add above, both `nim c`/`nim cpp`), and an AGREEING pair
  # already compiles as part of the normal suite. This slice adds the mirror
  # negative: a CONFLICTING pair (testlib.h says `int testlib_add(int,int)`;
  # the vendored prototype says `double testlib_add(int,int)`) must fail the
  # C compile — the two file-scope `extern` declarations `emitPrototypeDecl`
  # and the header `#include` both produce are incompatible redeclarations,
  # so the C/C++ compiler itself rejects them (C11 6.7p4), before softlink's
  # own call-based `_Static_assert` ("signature mismatch") gets a chance to
  # run. Because the failure is the COMPILER's own diagnostic (wording is
  # "conflicting types for ..." on gcc/clang, C2371 on MSVC — not softlink's
  # string), this check asserts on EXIT CODE ONLY, via `expectCompileFailure`
  # below — no grep of compiler prose, unlike every other tfail_* check in
  # this file. That makes it portable to all four CI legs (gcc/g++/clang/
  # clang++/MSVC) by construction. Exercised under both `nim c` and `nim cpp`
  # (the `extern "C"` path is exactly what makes the C++ leg meaningful — see
  # `emitPrototypeDecl`'s doc comment in src/softlink.nim).
  const dupFailCheck = "nim c --path:src tests/tfail_duplicate_dynlib.nim"
  const gateFailCheck = "nim c --path:src --passC:-I. tests/tfail_verifywhen_mismatch.nim"
  const contraFailCheck = "nim c --path:src tests/tfail_verifywhen_noverify.nim"
  const protoContraFailCheck = "nim c --path:src tests/tfail_prototype_noverify.nim"
  const protoMismatchFailCheck = "nim c --path:src --passC:-I. tests/tfail_prototype_mismatch.nim"
  # RFC-0001 slice A4: the conflict fixture, compiled under BOTH backends.
  # No OS-specific dependency (compile-only, no library load), but wired
  # into all three OS branches below to mirror this file's existing style
  # of one self-contained script per CI leg.
  const protoConflictCCheck = "nim c --path:src --passC:-I. tests/tfail_prototype_conflict.nim"
  const protoConflictCppCheck = "nim cpp --path:src --passC:-I. tests/tfail_prototype_conflict.nim"
  # RFC-0001 slice A8: verifyProcs parity pins for {.prototype.} — the RFC's
  # own framing is that parity with dynlib already exists STRUCTURALLY (A0
  # gave both macros the same `parseProcPragmas`; A2 wired prototype
  # emission through the shared `genVerifyBlock`/`collectVProcs` path), and
  # this slice's job is to PIN that with tests so a future refactor can't
  # silently regress the verifyProcs side without dynlib's own tests
  # noticing. The A3 (mismatch) and A4 (conflict) analogs below are C-level
  # failures — `compiles()` only catches Nim-side macro errors, never a
  # C-level _Static_assert or redeclaration conflict (the C compiler runs
  # later, outside Nim's semantic check) — so they reuse the tfail-fixture
  # pattern instead of a suite-level `compiles()` test, exactly like their
  # dynlib originals.
  const vpProtoMismatchFailCheck =
    "nim c --path:src --passC:-I. tests/tfail_verifyprocs_prototype_mismatch.nim"
  const vpProtoConflictCCheck =
    "nim c --path:src --passC:-I. tests/tfail_verifyprocs_prototype_conflict.nim"
  const vpProtoConflictCppCheck =
    "nim cpp --path:src --passC:-I. tests/tfail_verifyprocs_prototype_conflict.nim"

  proc expectNoEmptyInclude(dumpCmd: string) =
    ## RFC-0001 slice A6: assert the generated C contains no `#include ""`
    ## — the exact invalid directive the RFC calls out (§3 A.1: "the
    ## verify TU's include-collection loop must skip empty headerFile
    ## entries (today it would emit an invalid #include \"\")") — for an
    ## all-prototype-only block (no {.header.} anywhere). NOT a blanket
    ## "zero #include substring anywhere" check: every Nim-generated .c
    ## file unconditionally #includes its own runtime headers
    ## (`nimbase.h` et al.), and `genVerifyBlock` itself unconditionally
    ## emits one further fixed scaffolding line, `#include <type_traits>`
    ## (guarded by `#if defined(__cplusplus)`), needed by the C++ tier's
    ## const-stripping helper for ANY proc going through that tier —
    ## header-driven or not. Neither of those is "a header this BLOCK
    ## asked to verify against" in the RFC's sense; the one thing that
    ## must never appear is the malformed empty-string directive a
    ## missing `headerFile != ""` guard would produce.
    ##
    ## This is an ABSENCE assertion, so (unlike every `grep -q` presence
    ## check in this file) it can't just be `exec cmd | grep -q ...`: that
    ## pattern makes the task FAIL when the string is absent, the opposite
    ## polarity of what's wanted here. Same `gorgeEx` + Nim-side decision
    ## shape as `expectCompileFailure` above — `dumpCmd` is an OS-
    ## appropriate "dump these generated .c files to stdout" command
    ## (`cat`/`type`), not a search tool, so there's no exit-code polarity
    ## to fight in the first place.
    let (output, _) = gorgeEx(dumpCmd)
    if "#include \"\"" in output:
      echo output
      quit("softlink: RFC-0001 slice A6 expected NO invalid `#include \"\"` " &
           "in the all-prototype-only verify TU, but found one")
  # (--compileOnly: the diagnostics fire at macro expansion, so skipping the
  # C compile+link keeps the check fast and leaves no stray binary behind.)
  const hintCheck = "nim c --compileOnly --path:src tests/thint_noverify.nim"
  const warnCheck = "nim c --compileOnly --path:src -d:softlinkStrictVerify tests/thint_noverify.nim"
  # RFC-0001 §3 A.2, slice A7: the {.noverify: "justification".} string is
  # now READ (previously accepted and silently discarded) and folded into
  # the same hint/warning checked above — this fixture carries one proc
  # with a justification and one bare {.noverify.} proc, so both renderings
  # ("<reason text>" and the "(no justification)" placeholder for the bare
  # form) are exercised in the same compile.
  const reasonHintCheck = "nim c --compileOnly --path:src tests/thint_noverify_reason.nim"
  const reasonWarnCheck = "nim c --compileOnly --path:src -d:softlinkStrictVerify tests/thint_noverify_reason.nim"
  # RFC-0001 slice A6: a {.prototype.}-only proc (no {.header.}) whose
  # prototype references a non-builtin identifier (found via the shared
  # A1 tokenizer) must emit a hint naming it — "this prototype may need
  # `header:` to resolve <T>" — upgraded to a warning under
  # -d:softlinkStrictVerify, same convention as the {.noverify.} hint above.
  const nonBuiltinHintCheck =
    "nim c --compileOnly --path:src tests/thint_prototype_nonbuiltin.nim"
  const nonBuiltinWarnCheck = "nim c --compileOnly --path:src " &
    "-d:softlinkStrictVerify tests/thint_prototype_nonbuiltin.nim"
  # RFC-0001 slice A2: a {.prototype.}-only proc (testlib_protoonly, no
  # {.header.}) must be verified for real against its vendored C prototype —
  # emitted as a file-scope `extern` declaration in the verify TU, ahead of
  # the standard call-based _Static_assert chain. "Genuinely verified"
  # vs. A1's interim "silently unverified" are indistinguishable from a
  # runtime unittest (both compile and dispatch identically), so this
  # inspects the generated C directly for the extern declaration. The
  # emitted text (including the `#if defined(__cplusplus) extern "C" { ...
  # }` wrapper) is backend-agnostic — written to the .c file regardless of
  # target — so one C-backend --compileOnly run covers both backends.
  const protoEmitDir = "tests/nimcache_protocheck"
  const protoEmitCheck = "nim c --compileOnly --nimcache:" & protoEmitDir &
    " --path:src --passC:-I. tests/test_softlink.nim"
  # RFC-0001 slice A6: the empty-include skip. A verifyProcs block whose
  # procs are ALL prototype-only (no {.header.} anywhere) must NOT emit
  # the invalid `#include ""` a naive per-proc header loop would produce
  # (see `expectNoEmptyInclude` above) while still emitting the vendored
  # `extern` declaration — the skip must not silently disable verification
  # too.
  const protoOnlyDir = "tests/nimcache_protoonly"
  const protoOnlyCheck = "nim c --compileOnly --nimcache:" & protoOnlyDir &
    " --path:src tests/tcheck_protoonly_no_include.nim"
  const protoOnlyDecl = "extern int softlink_a6_protoonly_check(int a, int b);"
  # RFC-0001 slice A5: {.prototype.} + {.verifyWhen.} composition — the gate
  # must wrap the emitted DECLARATION itself, not merely its assert (A.1:
  # "both the emitted declaration and its assert are gated by the #if").
  # testlib_proto_gated_true's `#if (TESTLIB_VERSION >= 1)` gate holds
  # (TESTLIB_VERSION is 1); `emitPrototypeDecl` always emits the
  # `#if defined(__cplusplus)` / `extern "C" {` / `#endif` wrapper and then
  # the `extern` declaration itself within the 5 lines right after the gate
  # line, so finding the declaration text inside that window (via `grep -A5`)
  # proves the gate actually wraps the declaration, not some unrelated part
  # of the file. `-F` (fixed-string) sidesteps the `(`/`*`/`/` characters in
  # both patterns being read as regex metacharacters.
  const protoGateTrueAnchor =
    "#if (TESTLIB_VERSION >= 1) /* softlink verifyWhen: prototype decl */"
  const protoGateTrueDecl = "extern int testlib_proto_gated_true(void);"
  const protoGateTrueCheck = "grep -rFA5 '" & protoGateTrueAnchor & "' " &
    protoEmitDir & " | grep -Fq '" & protoGateTrueDecl & "'"
  # The false-gate mirror — REQUIRED, not merely supplementary (see below for
  # why). testlib_proto_gated_false's `#if (TESTLIB_VERSION >= 99)` gate does
  # NOT hold (TESTLIB_VERSION is 1), and its vendored prototype is
  # deliberately WRONG — different return type and arity than the real C
  # function. Finding both the gate line and the deliberately-wrong extern
  # text in the generated C proves the declaration was emitted-but-suppressed
  # (never seen by the C compiler).
  #
  # Empirically verified this grep is load-bearing, not decorative: injecting
  # a declaration-gating regression (emitPrototypeDecl always emitting the
  # `extern`, ignoring `verifyWhen`) left `nim c --compileOnly` AND the full
  # `nim c -r`/`nim cpp -r` suite green — every runtime test, including this
  # slice's dispatch checks, still passed. Runtime dispatch never calls a
  # C symbol by name (it goes through a dlsym'd function pointer), and this
  # fixture has no `{.header.}` to conflict with, so a leaked, unused,
  # wrong-arity `extern` declaration is inert C — nothing calls it, nothing
  # else declares the same symbol, so gcc never objects. Only this grep
  # caught the injected regression. This is why a false-gate proc's runtime
  # behavior (the RFC's "(suite)" scope for this item) cannot by itself prove
  # the DECLARATION is gated — only the assert's independent, already-correct
  # gating (unaffected by the injected bug) — so this C-inspection is added
  # beyond the slice's literal text to actually close that coverage gap.
  const protoGateFalseAnchor =
    "#if (TESTLIB_VERSION >= 99) /* softlink verifyWhen: prototype decl */"
  const protoGateFalseDecl =
    "extern void testlib_proto_gated_false(double a, double b, double c);"
  const protoGateFalseCheck = "grep -rFA5 '" & protoGateFalseAnchor & "' " &
    protoEmitDir & " | grep -Fq '" & protoGateFalseDecl & "'"
  # RFC-0001 slice A8: verifyProcs parity for the non-builtin-identifier hint
  # (slice A6). thint_prototype_nonbuiltin.nim above is dynlib-only; this is
  # the verifyProcs mirror, same fixture shape, through `verifyProcs` instead.
  const vpNonBuiltinHintCheck =
    "nim c --compileOnly --path:src tests/thint_verifyprocs_prototype_nonbuiltin.nim"
  const vpNonBuiltinWarnCheck = "nim c --compileOnly --path:src " &
    "-d:softlinkStrictVerify tests/thint_verifyprocs_prototype_nonbuiltin.nim"
  # RFC-0001 slice A8: verifyProcs parity for slice A2's "prototype-only
  # proc is genuinely verified, not silently skipped" proof. The verifyProcs
  # block in test_softlink.nim binds testlib_unheralded (absent from
  # testlib.h) via {.prototype.} alone; dynlib's OWN binding of the same C
  # symbol stays on {.noverify.} (the #14 regression fixture) and so is
  # excluded from `genVerifyBlock`'s `procs` filter entirely — it never
  # emits an extern declaration for testlib_unheralded. That makes this grep
  # unambiguous: the only possible source of `extern int
  # testlib_unheralded(void);` in the whole compiled TU is verifyProcs's
  # prototype-only emission path, proven the same way A2 proved it for
  # dynlib's testlib_protoonly above (a runtime unittest can't tell
  # "genuinely verified" from "silently unverified" apart — verifyProcs has
  # no runtime unittests at all).
  const vpProtoOnlyDecl = "extern int testlib_unheralded(void);"
  # RFC-0001 slice A8: the verifyProcs analog of the A5 true/false-gate
  # C-inspection pair above (protoGateTrueCheck/protoGateFalseCheck), using
  # vp_proto_gated_true/vp_proto_gated_false — C names UNIQUE to the
  # verifyProcs block (never bound by the dynlib block), so a match can only
  # be explained by verifyProcs's own emission, not dynlib's (see the doc
  # comment on those two procs in test_softlink.nim for why sharing a name
  # with the dynlib fixture would leave this ambiguous). Empirically
  # verified load-bearing during this slice's TDD cycle: fault-injecting
  # `collectVProcs` to drop `verifyWhen`/`prototype` on the way into
  # `SoftlinkProc` (verifyProcs-specific code, NOT shared with dynlib's own
  # body-collection loop) left the full suite green but was caught here.
  const vpProtoGateTrueDecl = "extern int vp_proto_gated_true(void);"
  const vpProtoGateTrueCheck = "grep -rFA5 '" & protoGateTrueAnchor & "' " &
    protoEmitDir & " | grep -Fq '" & vpProtoGateTrueDecl & "'"
  const vpProtoGateFalseDecl =
    "extern void vp_proto_gated_false(double a, double b, double c);"
  const vpProtoGateFalseCheck = "grep -rFA5 '" & protoGateFalseAnchor & "' " &
    protoEmitDir & " | grep -Fq '" & vpProtoGateFalseDecl & "'"

  # RFC-0001 slice B1: -d:softlinkDumpProbes=<dir> probe-facts dump.
  # tests/tcheck_dump_probes.nim contains one dynlib block (base name
  # "Dumpfoo") and one verifyProcs block (base name "VerifyTestlib_noop" —
  # see the tag-reuse rationale on `dumpProbeFacts`'s call site in
  # src/softlink.nim). Validation is schema/JSON-shaped, not compiler-
  # diagnostic-wording-shaped, so — unlike every other check in this file —
  # it needs no grep/findstr split: `runDumpProbesCheck` below is called
  # verbatim, unchanged, from all three OS branches.
  #
  # `-d:softlinkDumpProbes` requires an ABSOLUTE directory (src/softlink.nim's
  # `dumpProbeFacts` doc comment has the full explanation: `staticExec`'s
  # subprocess cwd is tied to softlink.nim's own directory, not this
  # process's), so the dir is built from `getCurrentDir()` — nimble tasks
  # run in an unrestricted NimScript VM where `getCurrentDir()` genuinely
  # works (unlike ordinary compile-time macro/VM code, where it fails with
  # "cannot 'importc' variable at compile time; getcwd" — the exact
  # asymmetry that makes the absolute-path requirement necessary in the
  # first place).
  let dumpProbesDir = getCurrentDir() & "/tests/nimcache_dumpprobes"
  let dumpProbesCheck = "nim c --compileOnly --path:src -d:softlinkDumpProbes=" &
    dumpProbesDir & " tests/tcheck_dump_probes.nim"
  const dumpProbesNoDefineCheck =
    "nim c --compileOnly --path:src tests/tcheck_dump_probes.nim"

  proc runDumpProbesCheck() =
    ## RFC-0001 slice B1: exercises BOTH macros' dump path, the "stale file
    ## at the target path gets cleanly replaced" atomicity proxy (§4 B.1:
    ## "a torn write must never be observable" — the race itself can't be
    ## driven from a task, but a pre-existing garbage file at the target
    ## path getting replaced by a fresh, valid document is something this
    ## CAN check), and the no-define path (byte-identical behavior: no
    ## dump directory at all — this slice is purely additive).
    let dynlibFile = dumpProbesDir & "/Dumpfoo.probes.json"
    let verifyFile = dumpProbesDir & "/VerifyTestlib_noop.probes.json"
    if dirExists(dumpProbesDir): rmDir(dumpProbesDir)
    # No-define control: compiling the SAME fixture without the define must
    # create no dump directory whatsoever.
    exec dumpProbesNoDefineCheck
    if dirExists(dumpProbesDir):
      quit("softlink: RFC-0001 slice B1 expected NO " & dumpProbesDir &
           " directory without -d:softlinkDumpProbes — the dump must be " &
           "inert when the define is absent")
    # Stale-file replacement: a pre-existing, non-JSON file at the target
    # path must be cleanly replaced by write-then-rename, not appended to
    # or left corrupt.
    mkDir(dumpProbesDir)
    writeFile(dynlibFile, "not valid json, pre-existing garbage")
    writeFile(verifyFile, "not valid json, pre-existing garbage")
    exec dumpProbesCheck
    validateProbeJson(dynlibFile, "dynlib", "Dumpfoo")
    validateProbeJson(verifyFile, "verifyProcs", "VerifyTestlib_noop")
    rmDir(dumpProbesDir)

  # RFC-0001 §4 B.2: define-gated probe modes (`-d:softlinkProbeOnly=<sym|->`
  # / `-d:softlinkProbeExistence`). tests/tcheck_probe_only.nim carries one
  # dynlib block spanning all four declaration-source/gating axes the slice
  # brief calls for: testlib_add (header + prototype, cross-checked),
  # testlib_noop (header only), testlib_future (optional + header),
  # testlib_gated (verifyWhen-gated + header) — reusing existing testlib.h
  # symbols already proven correct elsewhere in this suite, same convention
  # as tcheck_dump_probes.nim. tests/tcheck_probe_only_verifyprocs.nim
  # proves the identical mechanism through `verifyProcs` alone (suppression/
  # probing/existence classification lives once, in the shared
  # `genVerifyBlock`, so both macros get it for free — see src/softlink.nim).
  #
  # Verification is inspected DIRECTLY against softlink's own emitted C via
  # `walkGenSources`/`expectAnchor` below (NimScript's own `listDirs`/
  # `listFiles`/`readFile` — NOT `std/os`'s `walkDirRec`; importing
  # `std/os` here breaks NimScript builtins, per this file's other notes).
  # That inspection targets softlink's OWN text, not a C/C++ compiler's
  # diagnostic wording, so — like `validateProbeJson`'s schema check above —
  # it needs no grep/findstr split and runs identically from all three OS
  # branches via one call, `runProbeOnlyChecks()`.
  const probeOnlyM0 = "tests/nimcache_probeonly_m0"
  const probeOnlyM1 = "tests/nimcache_probeonly_m1"
  const probeOnlyM2 = "tests/nimcache_probeonly_m2"
  const probeOnlyM3 = "tests/nimcache_probeonly_m3"
  const probeOnlyM3cpp = "tests/nimcache_probeonly_m3cpp"
  const probeOnlyM4 = "tests/nimcache_probeonly_m4"
  # RFC-0001 §4 B.2, slice B7 (fast-path list support):
  #   M5 -d:softlinkProbeOnly=testlib_add,testlib_noop — a two-symbol list
  #      keeps BOTH symbols' verification, suppresses the other two procs.
  #   M8 -d:softlinkProbeOnly=testlib_add,<space>testlib_noop — pins this
  #      slice's whitespace-not-trimmed decision (see the `softlinkProbeOnly`
  #      const's doc comment in src/softlink.nim): the untrimmed, space-
  #      padded second element never equals any real C name, so it behaves
  #      as if absent from the list (fails closed) rather than matching.
  const probeOnlyM5 = "tests/nimcache_probeonly_m5"
  const probeOnlyM8 = "tests/nimcache_probeonly_m8"
  const probeOnlyV0 = "tests/nimcache_probeonly_v0"
  const probeOnlyV1 = "tests/nimcache_probeonly_v1"
  const probeOnlyV2 = "tests/nimcache_probeonly_v2"
  const probeOnlyDirs = [probeOnlyM0, probeOnlyM1, probeOnlyM2, probeOnlyM3,
                          probeOnlyM3cpp, probeOnlyM4, probeOnlyM5, probeOnlyM8,
                          probeOnlyV0, probeOnlyV1, probeOnlyV2]

  const poAssertAdd = "softlink: testlib_add signature mismatch vs tests/testlib.h"
  const poAssertNoop = "softlink: testlib_noop signature mismatch vs tests/testlib.h"
  const poAssertFuture = "softlink: testlib_future signature mismatch vs tests/testlib.h"
  const poAssertGated = "softlink: testlib_gated signature mismatch vs tests/testlib.h"
  const poProtoDeclAdd = "extern int testlib_add(int a, int b);"
  const poInclude = "#include \"tests/testlib.h\""
  const poExistAddGcc = "sizeof(__typeof__(&testlib_add))"
  const poExistAddCpp = "sizeof(decltype(&testlib_add))"
  # Adjacency proof (same rigor as protoGateTrueCheck's `grep -A5` above,
  # just expressed as one literal substring instead of a shell pipeline):
  # the gated proc's existence reference — ALL THREE tiers — sits directly
  # inside its own `#if (EXPR)` gate, exactly as `emitPrototypeDecl`'s
  # verifyWhen wrapping already proved for {.prototype.} decls.
  const poExistGatedGated =
    "#if (TESTLIB_VERSION >= 1) /* softlink verifyWhen */\n" &
    "#if defined(__cplusplus)\n(void)sizeof(decltype(&testlib_gated));\n" &
    "#elif defined(__GNUC__)\n(void)sizeof(__typeof__(&testlib_gated));"

  # RFC-0001 §4 B.2, slice B7: the malformed-list and multi-symbol-plus-
  # existence macro errors are softlink's OWN fixed text, but — like
  # `expectManifestCompileFail` above — asserted via `gorgeEx` + plain `in`
  # at the NimScript level rather than an OS-specific grep/findstr pipe, so
  # these two checks run identically from all three OS branches through
  # this one `runProbeOnlyChecks()` call (no triplication needed).
  const poMalformedListAnchor = "malformed -d:softlinkProbeOnly"
  const poMultiExistenceAnchor = "requires exactly ONE probed symbol"

  const vpoAssertMagic = "softlink: testlib_magic signature mismatch vs tests/testlib.h"
  const vpoAssertProtoonly = "softlink: testlib_protoonly signature mismatch vs vendored prototype"
  const vpoProtoDeclProtoonly = "extern int testlib_protoonly(void);"
  const vpoExistMagicGcc = "sizeof(__typeof__(&testlib_magic))"

  proc walkGenSources(dir: string): seq[string] =
    ## All generated .c/.cpp files under one --nimcache dir. NimScript's
    ## `listDirs`/`listFiles` are each non-recursive (see their doc
    ## comments in system/nimscript.nim), so this walks the tree by hand
    ## with an explicit stack rather than reaching for `std/os.walkDirRec`.
    var stack = @[dir]
    while stack.len > 0:
      let d = stack.pop()
      for f in listFiles(d):
        if f.endsWith(".c") or f.endsWith(".cpp"):
          result.add(f)
      for sub in listDirs(d):
        stack.add(sub)

  proc slurpGenSources(dir: string): string =
    for f in walkGenSources(dir):
      result.add(readFile(f))
      result.add('\n')

  proc expectAnchor(dir, needle, label: string, wantPresent: bool) =
    ## RFC-0001 slice B2: presence/absence assertion against softlink's own
    ## emitted C for one probe-mode compile. `wantPresent = false` covers
    ## the suppression side of the brief (an absence assertion, the same
    ## polarity problem `expectNoEmptyInclude` above already solves for a
    ## single fixed needle — this generalizes it to an arbitrary needle so
    ## every probe-mode assertion below doesn't need its own bespoke helper).
    let found = needle in slurpGenSources(dir)
    if found != wantPresent:
      quit("softlink: RFC-0001 slice B2 (" & label & "): expected '" &
           needle & "' to be " & (if wantPresent: "PRESENT" else: "ABSENT") &
           " under " & dir & ", but it was " &
           (if found: "present" else: "absent"))

  proc runProbeOnlyChecks() =
    ## Compiles both probe-mode fixtures under every configuration the
    ## slice brief lists, then asserts on the resulting generated C. Exits
    ## non-zero (via `quit`, from `expectAnchor`, or from `exec` itself
    ## raising on a nonzero compiler exit) on any mismatch.
    for d in probeOnlyDirs:
      if dirExists(d): rmDir(d)

    let cBase = "nim c --compileOnly --path:src --passC:-I. --nimcache:"
    # For the two macro-ERROR checks below (M6/M7) a --nimcache dir would
    # never get populated (the compile never reaches codegen) — same
    # nimcache-free style `expectManifestCompileFail`'s own callers use.
    let cBaseNoCache = "nim c --compileOnly --path:src --passC:-I. "
    # M0: no defines — control. Every predicate in genVerifyBlock's probe
    # logic is unreachable when both consts are at their default/empty
    # value, so this compile is byte-identical to pre-B2 emission by
    # construction; this assertion is the executable proof of that claim.
    exec cBase & probeOnlyM0 & " tests/tcheck_probe_only.nim"
    # M1: -d:softlinkProbeOnly=- — suppress everything (harvester baseline).
    exec cBase & probeOnlyM1 & " -d:softlinkProbeOnly=- tests/tcheck_probe_only.nim"
    # M2: -d:softlinkProbeOnly=testlib_add — only that symbol survives.
    exec cBase & probeOnlyM2 & " -d:softlinkProbeOnly=testlib_add tests/tcheck_probe_only.nim"
    # M3: M2 + -d:softlinkProbeExistence — existence-only for testlib_add.
    exec cBase & probeOnlyM3 &
      " -d:softlinkProbeOnly=testlib_add -d:softlinkProbeExistence tests/tcheck_probe_only.nim"
    # M3cpp: the SAME M3 combination under `nim cpp`, proving the C++
    # decltype existence tier (not merely the GCC/Clang __typeof__ one).
    exec "nim cpp --compileOnly --path:src --passC:-I. --nimcache:" & probeOnlyM3cpp &
      " -d:softlinkProbeOnly=testlib_add -d:softlinkProbeExistence tests/tcheck_probe_only.nim"
    # M4: -d:softlinkProbeOnly=testlib_gated -d:softlinkProbeExistence —
    # proves the existence reference for a {.verifyWhen.}-gated proc stays
    # inside that proc's own #if (EXPR) gate.
    exec cBase & probeOnlyM4 &
      " -d:softlinkProbeOnly=testlib_gated -d:softlinkProbeExistence tests/tcheck_probe_only.nim"

    expectAnchor(probeOnlyM0, poAssertAdd, "M0 control: testlib_add assert", true)
    expectAnchor(probeOnlyM0, poAssertNoop, "M0 control: testlib_noop assert", true)
    expectAnchor(probeOnlyM0, poAssertFuture, "M0 control: testlib_future assert", true)
    expectAnchor(probeOnlyM0, poAssertGated, "M0 control: testlib_gated assert", true)
    expectAnchor(probeOnlyM0, poProtoDeclAdd, "M0 control: testlib_add prototype decl", true)
    expectAnchor(probeOnlyM0, poInclude, "M0 control: header include", true)

    expectAnchor(probeOnlyM1, poAssertAdd, "M1 suppress-all: testlib_add assert", false)
    expectAnchor(probeOnlyM1, poAssertNoop, "M1 suppress-all: testlib_noop assert", false)
    expectAnchor(probeOnlyM1, poAssertFuture, "M1 suppress-all: testlib_future assert", false)
    expectAnchor(probeOnlyM1, poAssertGated, "M1 suppress-all: testlib_gated assert", false)
    expectAnchor(probeOnlyM1, poProtoDeclAdd, "M1 suppress-all: testlib_add prototype decl", false)
    expectAnchor(probeOnlyM1, poInclude, "M1 suppress-all: header include still present", true)

    expectAnchor(probeOnlyM2, poAssertAdd, "M2 probe-add: testlib_add assert", true)
    expectAnchor(probeOnlyM2, poAssertNoop, "M2 probe-add: testlib_noop assert", false)
    expectAnchor(probeOnlyM2, poAssertFuture, "M2 probe-add: testlib_future assert", false)
    expectAnchor(probeOnlyM2, poAssertGated, "M2 probe-add: testlib_gated assert", false)
    expectAnchor(probeOnlyM2, poProtoDeclAdd, "M2 probe-add: testlib_add prototype decl", true)

    expectAnchor(probeOnlyM3, poAssertAdd, "M3 existence-add: testlib_add assert", false)
    expectAnchor(probeOnlyM3, poProtoDeclAdd, "M3 existence-add: testlib_add prototype decl", false)
    expectAnchor(probeOnlyM3, poExistAddGcc, "M3 existence-add: __typeof__ existence reference", true)
    expectAnchor(probeOnlyM3cpp, poExistAddCpp, "M3cpp existence-add: decltype existence reference", true)
    expectAnchor(probeOnlyM3cpp, poAssertAdd, "M3cpp existence-add: testlib_add assert", false)
    expectAnchor(probeOnlyM3cpp, poProtoDeclAdd, "M3cpp existence-add: testlib_add prototype decl", false)

    expectAnchor(probeOnlyM4, poExistGatedGated,
      "M4 existence-gated: existence reference sits inside its own verifyWhen gate", true)
    expectAnchor(probeOnlyM4, poAssertGated, "M4 existence-gated: testlib_gated assert", false)

    # RFC-0001 §4 B.2, slice B7 (fast-path list support for
    # -d:softlinkProbeOnly): a two-symbol list keeps BOTH members verified,
    # suppressing every proc NOT named — the same suppression rule M2 above
    # already proves for a singleton list, generalized.
    exec cBase & probeOnlyM5 &
      " -d:softlinkProbeOnly=testlib_add,testlib_noop tests/tcheck_probe_only.nim"
    expectAnchor(probeOnlyM5, poAssertAdd, "M5 probe-list(add,noop): testlib_add assert", true)
    expectAnchor(probeOnlyM5, poAssertNoop, "M5 probe-list(add,noop): testlib_noop assert", true)
    expectAnchor(probeOnlyM5, poAssertFuture, "M5 probe-list(add,noop): testlib_future assert", false)
    expectAnchor(probeOnlyM5, poAssertGated, "M5 probe-list(add,noop): testlib_gated assert", false)
    expectAnchor(probeOnlyM5, poProtoDeclAdd, "M5 probe-list(add,noop): testlib_add prototype decl", true)

    # M8: the whitespace-not-trimmed decision (see `softlinkProbeOnly`'s doc
    # comment in src/softlink.nim) — a list element padded with a leading
    # space is used VERBATIM, so it never equals the real C name and simply
    # never matches (fails closed), rather than being trimmed or rejected.
    exec cBase & probeOnlyM8 &
      " \"-d:softlinkProbeOnly=testlib_add, testlib_noop\" tests/tcheck_probe_only.nim"
    expectAnchor(probeOnlyM8, poAssertAdd, "M8 probe-list whitespace-not-trimmed: testlib_add assert", true)
    expectAnchor(probeOnlyM8, poAssertNoop,
      "M8 probe-list whitespace-not-trimmed: testlib_noop assert (untrimmed ' testlib_noop' never matches)", false)

    # M6: a malformed list (empty element from a doubled comma) is a macro
    # error naming the malformed define — never a silent partial match
    # (same no-silent-degradation principle as every other malformed-input
    # check in this file).
    expectManifestCompileFail(
      cBaseNoCache & " -d:softlinkProbeOnly=testlib_add,,testlib_noop tests/tcheck_probe_only.nim",
      [poMalformedListAnchor])

    # M7: a MULTI-symbol -d:softlinkProbeOnly list combined with
    # -d:softlinkProbeExistence is a macro error — existence is a per-
    # singleton stage of the standard three-probe pipeline; a group
    # existence probe is meaningless (singleton + existence is UNCHANGED,
    # already covered by M3/M4 above).
    expectManifestCompileFail(
      cBaseNoCache & " -d:softlinkProbeOnly=testlib_add,testlib_noop -d:softlinkProbeExistence " &
        "tests/tcheck_probe_only.nim",
      [poMultiExistenceAnchor])

    exec cBase & probeOnlyV0 & " tests/tcheck_probe_only_verifyprocs.nim"
    exec cBase & probeOnlyV1 & " -d:softlinkProbeOnly=testlib_magic tests/tcheck_probe_only_verifyprocs.nim"
    exec cBase & probeOnlyV2 &
      " -d:softlinkProbeOnly=testlib_magic -d:softlinkProbeExistence tests/tcheck_probe_only_verifyprocs.nim"

    expectAnchor(probeOnlyV0, vpoAssertMagic, "V0 control (verifyProcs): testlib_magic assert", true)
    expectAnchor(probeOnlyV0, vpoAssertProtoonly, "V0 control (verifyProcs): testlib_protoonly assert", true)
    expectAnchor(probeOnlyV0, vpoProtoDeclProtoonly, "V0 control (verifyProcs): testlib_protoonly prototype decl", true)

    expectAnchor(probeOnlyV1, vpoAssertMagic, "V1 probe-magic (verifyProcs): testlib_magic assert", true)
    expectAnchor(probeOnlyV1, vpoAssertProtoonly, "V1 probe-magic (verifyProcs): testlib_protoonly assert", false)
    expectAnchor(probeOnlyV1, vpoProtoDeclProtoonly, "V1 probe-magic (verifyProcs): testlib_protoonly prototype decl", false)

    expectAnchor(probeOnlyV2, vpoAssertMagic, "V2 existence-magic (verifyProcs): testlib_magic assert", false)
    expectAnchor(probeOnlyV2, vpoExistMagicGcc, "V2 existence-magic (verifyProcs): __typeof__ existence reference", true)

    for d in probeOnlyDirs:
      if dirExists(d): rmDir(d)

  # RFC-0001 §B.5/§B.5a, slice B6a: the `compatManifest` body directive —
  # grammar, erroring stub, path resolution, and every compile-time
  # consumption check (schema, lib identity, ABI, disjoint/exhaustive,
  # since-contradiction, mismatch warning, not-in-manifest hint,
  # degraded-tier warning). Fixture manifests under tests/manifests/ are
  # tracked as `*.tmpl.json` templates (a `${ABI}` placeholder where the
  # check must pass on every OS leg) and materialized into their real,
  # gitignored `*.compat.json` paths per run — see
  # `writeManifestFromTemplate` above.
  const manifestTmplBases = ["testlib", "testlib_schema2", "testlib_wronglib",
    "testlib_overlap", "testlib_gap", "testlib_since", "testlib_vp_subset",
    "testlib_vp_since", "testlib_abi_mismatch"]

  proc runManifestChecks() =
    const mdir = "tests/manifests/"
    for base in manifestTmplBases:
      writeManifestFromTemplate(mdir & base & ".tmpl.json", mdir & base & ".compat.json")

    const mcBase = "nim c --compileOnly --path:src --passC:-I. "

    expectManifestCompileOk(mcBase & "tests/tcheck_manifest_ok.nim", [], [
      "not in compat manifest", "recorded a 'mismatch' interval",
      "only supports schema", "is for library", "ignoring the compat manifest"])

    expectManifestCompileFail(mcBase & "tests/tfail_manifest_dup_directive.nim",
      ["duplicate compatManifest directive"])

    expectManifestCompileFail(mcBase & "tests/tfail_manifest_outside_block.nim",
      ["compatManifest is a body directive"])

    expectManifestCompileFail(mcBase & "tests/tfail_manifest_bad_path.nim",
      ["manifest file not found"])

    expectManifestCompileFail(mcBase & "tests/tfail_manifest_bad_path_type.nim",
      ["unrecognized argument"])

    expectManifestCompileFail(mcBase & "tests/tfail_manifest_bad_refuse_type.nim",
      ["must be a bool literal"])

    expectManifestCompileFail(mcBase & "tests/tfail_manifest_no_path.nim",
      ["requires a string literal manifest path"])

    expectManifestCompileFail(mcBase & "tests/tfail_manifest_schema_newer.nim",
      ["only supports schema 1"])

    expectManifestCompileFail(mcBase & "tests/tfail_manifest_wrong_lib.nim",
      ["is for library 'notthislib'"])

    expectManifestCompileFail(mcBase & "tests/tfail_manifest_overlap.nim",
      ["an overlap"])

    expectManifestCompileFail(mcBase & "tests/tfail_manifest_gap.nim",
      ["a gap"])

    expectManifestCompileFail(mcBase & "tests/tfail_manifest_since_contradiction.nim",
      ["corrected lower bound is 2.0.0"])

    expectManifestCompileFail(mcBase & "tests/tfail_since_unparseable.nim",
      ["does not parse as a version"])

    expectManifestCompileOk(mcBase & "tests/tcheck_manifest_mismatch_warning.nim",
      ["recorded a 'mismatch' interval"], [])

    # RFC-0001 §9/§C.1/§C.4b: the version-probe static drift-call scan —
    # a probe directly calling a wrapper whose symbol carries any
    # `mismatch` interval in the attached manifest is a macro error
    # ("testlib_noop" is recorded `mismatch` across the whole corpus, same
    # fixture the mismatch-warning check directly above uses); a probe
    # calling a wrapper with NO mismatch interval (`testlib_add`, recorded
    # `verified`) compiles fine.
    expectManifestCompileFail(mcBase & "tests/tfail_probe_drift_call.nim",
      ["the version probe may only call symbols with no known drift ranges"])

    expectManifestCompileOk(mcBase & "tests/tcheck_versionprobe_drift_free.nim", [], [])

    expectManifestCompileOk(mcBase & "tests/tcheck_manifest_not_in_manifest_hint.nim",
      ["not in compat manifest"], [])

    expectManifestCompileOk(mcBase & "tests/tcheck_manifest_abi_mismatch.nim",
      ["ignoring the compat manifest entirely"], ["corrected lower bound"])

    expectManifestCompileFail(mcBase & "tests/tfail_manifest_refuse_verifyprocs.nim",
      ["nothing to refuse on verifyProcs"])

    expectManifestCompileOk(mcBase & "tests/tcheck_manifest_verifyprocs_subset.nim",
      ["recorded a 'mismatch' interval", "not in compat manifest"], [])

    expectManifestCompileFail(mcBase & "tests/tfail_manifest_verifyprocs_since_contradiction.nim",
      ["corrected lower bound is 2.0.0"])

    # RFC-0001 §B.5/§9, slice B6b: the interval-const embedding,
    # `softlinkCompatFacts<Base>: seq[SymbolFacts]` — a `static:` assert
    # failure inside each fixture would itself fail the compile, so
    # `expectManifestCompileOk`/`expectManifestCompileFail` succeeding IS
    # the const-shape/const-absence assertion; no extra output-string
    # check is needed beyond what each fixture already asserts internally.
    expectManifestCompileOk(mcBase & "tests/tcheck_manifest_facts_const.nim", [], [])

    expectManifestCompileOk(mcBase & "tests/tcheck_manifest_facts_const_absent.nim", [], [])

    expectManifestCompileOk(mcBase & "tests/tcheck_manifest_facts_const_abi_ignored.nim",
      ["ignoring the compat manifest entirely"], [])

    # Check 9 (degraded-tier warning): direct C-inspection, mirroring
    # `runProbeOnlyChecks`'s own `expectAnchor` convention above — the
    # macro cannot know at expansion time which C tier fires, so the
    # `#pragma message` is asserted PRESENT in the emitted C for the
    # manifest-attached fixture and ABSENT for its no-manifest twin.
    const degradedWithDir = "tests/nimcache_manifest_degraded_with"
    const degradedWithoutDir = "tests/nimcache_manifest_degraded_without"
    if dirExists(degradedWithDir): rmDir(degradedWithDir)
    if dirExists(degradedWithoutDir): rmDir(degradedWithoutDir)
    exec mcBase & "--nimcache:" & degradedWithDir & " tests/tcheck_manifest_degraded_with.nim"
    exec mcBase & "--nimcache:" & degradedWithoutDir & " tests/tcheck_manifest_degraded_without.nim"
    const degradedNeedle = "softlink: compat manifest attached but this " &
      "compile's verification tier degraded to no-op"
    expectAnchor(degradedWithDir, degradedNeedle,
      "manifest attached: degraded-tier pragma present", true)
    expectAnchor(degradedWithoutDir, degradedNeedle,
      "no manifest: degraded-tier pragma absent", false)
    rmDir(degradedWithDir)
    rmDir(degradedWithoutDir)

    for base in manifestTmplBases:
      rmFile(mdir & base & ".compat.json")

  proc runVersionProbeChecks() =
    ## RFC-0001 §9/§C.1, slice C1b: the `versionProbe` directive's negative
    ## compile checks — grammar misuse (duplicate, malformed shapes),
    ## outside-block stub, and verifyProcs rejection — plus the
    ## `declared()` proof that no directive means no state vars at all.
    ## Same `expectManifestCompileFail`/`gorgeEx` pattern as
    ## `runManifestChecks` above (OS-agnostic: plain `in` substring checks
    ## against softlink's OWN diagnostic text, not compiler-wording greps).
    const vpBase = "nim c --compileOnly --path:src --passC:-I. "

    expectManifestCompileFail(vpBase & "tests/tfail_versionprobe_duplicate.nim",
      ["duplicate versionProbe directive"])

    expectManifestCompileFail(vpBase & "tests/tfail_versionprobe_bare.nim",
      ["versionProbe requires a statement body"])

    expectManifestCompileFail(vpBase & "tests/tfail_versionprobe_empty_call.nim",
      ["versionProbe requires a statement body"])

    expectManifestCompileFail(vpBase & "tests/tfail_versionprobe_outside_block.nim",
      ["versionProbe is a body directive"])

    expectManifestCompileFail(vpBase & "tests/tfail_versionprobe_verifyprocs.nim",
      ["versionProbe has no meaning in verifyProcs"])

    expectManifestCompileOk(vpBase & "tests/tcheck_versionprobe_absent.nim", [], [])

  proc runCompatReportManifestChecks(runCmd: string) =
    ## RFC-0001 §9/§C.2, slice C2: `fooCompat()`'s runtime attestation
    ## against an ACTUALLY attached compat manifest (atAttested /
    ## atOutOfCorpus) needs a real `versionProbe` load — something the
    ## `--compileOnly` fixtures `runManifestChecks` drives above can't
    ## exercise. `runCmd` is the exact per-OS "load the shared testlib and
    ## run" command prefix each of the three call sites below already uses
    ## for `tests/test_softlink.nim` itself (library-path env var included);
    ## `tests/tcompat_report_manifest.nim` binds the identical
    ## `libtestlib.so`/`.dylib`/`.dll`, so it needs the same prefix.
    const mdir = "tests/manifests/"
    const base = "testlib_compat_report"
    writeManifestFromTemplate(mdir & base & ".tmpl.json", mdir & base & ".compat.json")
    exec runCmd & " tests/tcompat_report_manifest.nim"
    rmFile(mdir & base & ".compat.json")

  proc runDriftRequiredChecks(runCmd: string) =
    ## RFC-0001 §C.3, slice C4c: drift refusal for REQUIRED symbols — a
    ## real `versionProbe` load, exactly like `runCompatReportManifestChecks`
    ## above, needed for the same reason (the `--compileOnly` fixtures
    ## `runManifestChecks` drives can't exercise a real load). Two new
    ## modules, each its own `dynlib` block on `libtestlib.so` (per-module
    ## duplicate-block-guard scoping, same reasoning as
    ## `tests/tcompat_report_manifest.nim`'s own doc comment):
    ##   - `tests/tcompat_drift_required.nim`: `testlib_gated` bound
    ##     REQUIRED (C4b's own fixture binds the identical .so symbol
    ##     `optional`) — the happy path, lrOk-implies-safe, out-of-corpus,
    ##     and unload/reload behaviors (TDD items 1-4).
    ##   - `tests/tcompat_drift_refuse_false.nim`: `compatManifest(...,
    ##     refuse = false)` — proves the per-block escape hatch disables
    ##     BOTH the required unwind (C4c) and the optional re-nil (C4b)
    ##     (item 5).
    ## `tests/tcompat_drift_required.nim` is ALSO compiled and run a SECOND
    ## time with `-d:softlinkNoDriftRefusal` (item 6, the build-wide
    ## downstream-consumer override) — that file's own
    ## `driftRefusalOverridden` const flips the one assertion the define
    ## changes, so both invocations share one test body.
    const mdir = "tests/manifests/"
    const reqBase = "testlib_drift_required"
    const refuseFalseBase = "testlib_refuse_false"
    writeManifestFromTemplate(mdir & reqBase & ".tmpl.json", mdir & reqBase & ".compat.json")
    writeManifestFromTemplate(mdir & refuseFalseBase & ".tmpl.json", mdir & refuseFalseBase & ".compat.json")
    exec runCmd & " tests/tcompat_drift_required.nim"
    exec runCmd & " -d:softlinkNoDriftRefusal tests/tcompat_drift_required.nim"
    exec runCmd & " tests/tcompat_drift_refuse_false.nim"
    rmFile(mdir & reqBase & ".compat.json")
    rmFile(mdir & refuseFalseBase & ".compat.json")

  proc runDegradationChecks(runCmd: string) =
    ## RFC-0001 §9/§C.2, slice C5 — degradation matrix, cell 2: "no probe +
    ## manifest attached" needs a REAL load (a manifest with real fact
    ## intervals, attached to a block with NO versionProbe), exactly like
    ## `runCompatReportManifestChecks`/`runDriftRequiredChecks` above, for
    ## the same reason (the `--compileOnly` fixtures `runManifestChecks`
    ## drives can't exercise a real load). `tests/tcompat_degradation.nim`
    ## binds the identical `libtestlib.so`/`.dylib`/`.dll` (its own module —
    ## per-module duplicate-block-guard scoping, same reasoning as
    ## `tests/tcompat_report_manifest.nim`'s own doc comment). The
    ## remaining degradation cells (probe-less/manifest-less "neither", and
    ## unload-on-never-loaded) need no manifest at all and live directly in
    ## `tests/test_softlink.nim`, run by the plain `nim c -r`/`nim cpp -r`
    ## calls above already.
    const mdir = "tests/manifests/"
    const base = "testlib_degradation"
    writeManifestFromTemplate(mdir & base & ".tmpl.json", mdir & base & ".compat.json")
    exec runCmd & " tests/tcompat_degradation.nim"
    rmFile(mdir & base & ".compat.json")

  # RFC-0001 §4 B.2, classification-table discriminators: the heart of the
  # RFC's harvester classification table, proven directly against the
  # shipped mechanism (no harvester exists yet — that's slice B3):
  # - a verify-mode probe of a real symbol bound with a deliberately WRONG
  #   Nim signature must still fail with softlink's own "signature
  #   mismatch" (probing a single symbol is not a weaker check);
  # - the SAME mismatched binding under existence mode must SUCCEED (an
  #   existence reference never depends on the declared signature);
  # - an existence probe of a symbol the header does NOT declare must FAIL
  #   (this is what lets a future harvester classify `absent`) — checked
  #   under both `nim c` (GCC/Clang __typeof__ tier) and `nim cpp` (C++
  #   decltype tier) via `expectCompileFailure` (exit-code only: this is a
  #   raw "undeclared identifier" compiler diagnostic, not softlink's own
  #   string — see `expectCompileFailure`'s doc comment above).
  const probeMismatchVerifyFailCheck =
    "nim c --path:src --passC:-I. -d:softlinkProbeOnly=testlib_add " &
    "tests/tcheck_probe_existence_mismatch.nim"
  const probeMismatchExistenceSuccessCheck =
    "nim c --compileOnly --path:src --passC:-I. -d:softlinkProbeOnly=testlib_add " &
    "-d:softlinkProbeExistence tests/tcheck_probe_existence_mismatch.nim"
  const probeAbsentCCheck =
    "nim c --path:src --passC:-I. -d:softlinkProbeOnly=testlib_totally_absent " &
    "-d:softlinkProbeExistence tests/tfail_probe_existence_absent.nim"
  const probeAbsentCppCheck =
    "nim cpp --path:src --passC:-I. -d:softlinkProbeOnly=testlib_totally_absent " &
    "-d:softlinkProbeExistence tests/tfail_probe_existence_absent.nim"
  # RFC-0001 §4 B.2, design guidance point 4: `-d:softlinkProbeExistence`
  # set without `softlinkProbeOnly` naming a real symbol (unset, or the
  # `"-"` all-suppress sentinel) is a meaningless probe configuration and
  # must be a clear macro-expansion-time error — softlink's own string,
  # so (unlike the two checks directly above) this pair DOES need the
  # grep/findstr split, same as every other softlink-diagnostic check in
  # this file.
  const probeNoTargetUnsetCheck =
    "nim c --path:src --passC:-I. -d:softlinkProbeExistence " &
    "tests/tfail_probe_existence_no_target.nim"
  const probeNoTargetSentinelCheck =
    "nim c --path:src --passC:-I. -d:softlinkProbeExistence " &
    "-d:softlinkProbeOnly=- tests/tfail_probe_existence_no_target.nim"
  const probeNoTargetAnchor =
    "requires -d:softlinkProbeOnly=<CName> naming a real probed symbol"

  # RFC-0001 §9/§C.1, slice C1a: codegen-order pinning check (see
  # `expectWrapperBeforeLoad`'s doc comment above). Runs once, unconditionally,
  # like the `expectManifestCompileOk`/`expectManifestCompileFail` checks
  # above it — no OS-specific wording involved, so no three-way split.
  const wrapperOrderCheck =
    "nim c --compileOnly --path:src --expandMacro:dynlib tests/thint_noverify.nim"
  expectWrapperBeforeLoad(wrapperOrderCheck)

  if dirExists(protoEmitDir): rmDir(protoEmitDir)
  if dirExists(protoOnlyDir): rmDir(protoOnlyDir)
  when defined(windows):
    exec "gcc -shared -o tests/testlib.dll tests/testlib.c"
    exec "gcc -shared -o tests/libmagic.dll tests/testlib.c"
    # RFC-0001 slice A9: this branch is now exercised by CI (via `nimble
    # test`) for the first time — previously ci.yaml called `nim c -r`/
    # `nim cpp -r` directly and set `PATH="./tests:$PATH"` itself (see the
    # old "Run tests (GCC/Clang)" step) so the compiled test binary's
    # bare-name LoadLibrary("testlib.dll") could find it via Windows' PATH-
    # search step of the documented DLL search order. This task never did
    # that, so this branch would fail library resolution the moment CI
    # actually ran it. `putEnv` (unlike a shell-only prefix) persists for
    # the rest of THIS script process, so it covers both exec calls below.
    putEnv("PATH", "tests;" & getEnv("PATH"))
    exec "nim c -r --path:src --passC:-I. tests/test_softlink.nim"
    # Regression matrix for #12: cpp backend must also pass.
    exec "nim cpp -r --path:src --passC:-I. tests/test_softlink.nim"
    exec dupFailCheck & " 2>&1 | findstr /C:\"collides with an earlier dynlib block\" >NUL"
    exec gateFailCheck & " 2>&1 | findstr /C:\"signature mismatch\" >NUL"
    exec contraFailCheck & " 2>&1 | findstr /C:\"contradicts\" >NUL"
    exec protoContraFailCheck & " 2>&1 | findstr /C:\"contradicts\" >NUL"
    exec protoMismatchFailCheck & " 2>&1 | findstr /C:\"signature mismatch\" >NUL"
    expectCompileFailure(protoConflictCCheck)
    expectCompileFailure(protoConflictCppCheck)
    # RFC-0001 slice A8: verifyProcs parity analogs of the A3/A4 negative
    # fixtures directly above.
    exec vpProtoMismatchFailCheck & " 2>&1 | findstr /C:\"signature mismatch\" >NUL"
    expectCompileFailure(vpProtoConflictCCheck)
    expectCompileFailure(vpProtoConflictCppCheck)
    exec hintCheck & " 2>&1 | findstr /C:\"not header-verified\" | findstr /C:\"Hint:\" >NUL"
    exec warnCheck & " 2>&1 | findstr /C:\"not header-verified\" | findstr /C:\"Warning:\" >NUL"
    exec reasonHintCheck & " 2>&1 | findstr /C:\"private symbol, no public header at any version\" | findstr /C:\"Hint:\" >NUL"
    exec reasonHintCheck & " 2>&1 | findstr /C:\"(no justification)\" >NUL"
    exec reasonWarnCheck & " 2>&1 | findstr /C:\"private symbol, no public header at any version\" | findstr /C:\"Warning:\" >NUL"
    exec reasonWarnCheck & " 2>&1 | findstr /C:\"(no justification)\" >NUL"
    exec nonBuiltinHintCheck & " 2>&1 | findstr /C:\"may need `header:` to resolve\" | findstr /C:\"Hint:\" >NUL"
    exec nonBuiltinWarnCheck & " 2>&1 | findstr /C:\"may need `header:` to resolve\" | findstr /C:\"Warning:\" >NUL"
    # RFC-0001 slice A8: verifyProcs parity analog of the A6 non-builtin
    # hint check directly above.
    exec vpNonBuiltinHintCheck & " 2>&1 | findstr /C:\"may need `header:` to resolve\" | findstr /C:\"Hint:\" >NUL"
    exec vpNonBuiltinWarnCheck & " 2>&1 | findstr /C:\"may need `header:` to resolve\" | findstr /C:\"Warning:\" >NUL"
    exec protoEmitCheck
    exec "findstr /s /m /c:\"extern int testlib_protoonly(void);\" " &
      protoEmitDir & "\\*.c >NUL"
    # RFC-0001 slice A8: verifyProcs parity analog of A2's dynlib
    # prototype-only emission proof above — see `vpProtoOnlyDecl`'s doc
    # comment for why this grep is unambiguous.
    exec "findstr /s /m /c:\"" & vpProtoOnlyDecl & "\" " &
      protoEmitDir & "\\*.c >NUL"
    # RFC-0001 slice A5 (Windows proxy): findstr has no "-A" context-lines
    # equivalent to grep's, so this checks the gate line and the declaration
    # text are each present in the generated C SEPARATELY — weaker than the
    # adjacency proof the Unix branches below run, but still catches the
    # gate or the declaration going missing entirely.
    exec "findstr /s /m /c:\"" & protoGateTrueAnchor & "\" " &
      protoEmitDir & "\\*.c >NUL"
    exec "findstr /s /m /c:\"" & protoGateTrueDecl & "\" " &
      protoEmitDir & "\\*.c >NUL"
    exec "findstr /s /m /c:\"" & protoGateFalseAnchor & "\" " &
      protoEmitDir & "\\*.c >NUL"
    exec "findstr /s /m /c:\"" & protoGateFalseDecl & "\" " &
      protoEmitDir & "\\*.c >NUL"
    # RFC-0001 slice A8: verifyProcs parity analogs of the A5 true/false-gate
    # C-inspection pair directly above (same weaker Windows-proxy shape:
    # anchor and declaration checked as separate presence tests, not
    # adjacency-proven).
    exec "findstr /s /m /c:\"" & protoGateTrueAnchor & "\" " &
      protoEmitDir & "\\*.c >NUL"
    exec "findstr /s /m /c:\"" & vpProtoGateTrueDecl & "\" " &
      protoEmitDir & "\\*.c >NUL"
    exec "findstr /s /m /c:\"" & protoGateFalseAnchor & "\" " &
      protoEmitDir & "\\*.c >NUL"
    exec "findstr /s /m /c:\"" & vpProtoGateFalseDecl & "\" " &
      protoEmitDir & "\\*.c >NUL"
    rmDir(protoEmitDir)
    exec protoOnlyCheck
    expectNoEmptyInclude("type " & protoOnlyDir & "\\*.c")
    exec "findstr /s /m /c:\"" & protoOnlyDecl & "\" " &
      protoOnlyDir & "\\*.c >NUL"
    rmDir(protoOnlyDir)
    runDumpProbesCheck()
    # RFC-0001 §4 B.2: define-gated probe modes.
    exec probeMismatchVerifyFailCheck & " 2>&1 | findstr /C:\"signature mismatch\" >NUL"
    exec probeMismatchExistenceSuccessCheck
    expectCompileFailure(probeAbsentCCheck)
    expectCompileFailure(probeAbsentCppCheck)
    exec probeNoTargetUnsetCheck & " 2>&1 | findstr /C:\"" & probeNoTargetAnchor & "\" >NUL"
    exec probeNoTargetSentinelCheck & " 2>&1 | findstr /C:\"" & probeNoTargetAnchor & "\" >NUL"
    runProbeOnlyChecks()
    runCorpusChecks()
    runManifestChecks()
    runVersionProbeChecks()
    runCompatReportManifestChecks("nim c -r --path:src --passC:-I.")
    runDriftRequiredChecks("nim c -r --path:src --passC:-I.")
    runDegradationChecks("nim c -r --path:src --passC:-I.")
  elif defined(macosx):
    exec "cc -shared -fPIC -o tests/libtestlib.dylib tests/testlib.c"
    exec "cc -shared -fPIC -o tests/libmagic.dylib tests/testlib.c"
    # RFC-0001 slice A9: this branch is now exercised by CI (via `nimble
    # test`) for the first time — previously ci.yaml called `nim c -r`/
    # `nim cpp -r` directly with `DYLD_LIBRARY_PATH=./tests` set itself (see
    # the old "Run tests (GCC/Clang)" step); this task never set it, so
    # dlopen("libtestlib.dylib") would fail (macOS's dlopen/dyld default
    # search does not include the cwd, only DYLD_LIBRARY_PATH/
    # DYLD_FALLBACK_LIBRARY_PATH and a few system dirs). Mirrors the
    # `LD_LIBRARY_PATH=./tests` prefix the `else` (Linux) branch below
    # already uses (POSIX `VAR=val cmd` syntax works the same way here).
    exec "DYLD_LIBRARY_PATH=./tests nim c -r --path:src --passC:-I. tests/test_softlink.nim"
    exec "DYLD_LIBRARY_PATH=./tests nim cpp -r --path:src --passC:-I. tests/test_softlink.nim"
    exec dupFailCheck & " 2>&1 | grep -q 'collides with an earlier dynlib block'"
    exec gateFailCheck & " 2>&1 | grep -q 'signature mismatch'"
    exec contraFailCheck & " 2>&1 | grep -q 'contradicts'"
    exec protoContraFailCheck & " 2>&1 | grep -q 'contradicts'"
    exec protoMismatchFailCheck & " 2>&1 | grep -q 'signature mismatch'"
    expectCompileFailure(protoConflictCCheck)
    expectCompileFailure(protoConflictCppCheck)
    # RFC-0001 slice A8: verifyProcs parity analogs of the A3/A4 negative
    # fixtures directly above.
    exec vpProtoMismatchFailCheck & " 2>&1 | grep -q 'signature mismatch'"
    expectCompileFailure(vpProtoConflictCCheck)
    expectCompileFailure(vpProtoConflictCppCheck)
    exec hintCheck & " 2>&1 | grep 'not header-verified' | grep -q 'Hint:'"
    exec warnCheck & " 2>&1 | grep 'not header-verified' | grep -q 'Warning:'"
    exec reasonHintCheck & " 2>&1 | grep 'private symbol, no public header at any version' | grep -q 'Hint:'"
    exec reasonHintCheck & " 2>&1 | grep -q '(no justification)'"
    exec reasonWarnCheck & " 2>&1 | grep 'private symbol, no public header at any version' | grep -q 'Warning:'"
    exec reasonWarnCheck & " 2>&1 | grep -q '(no justification)'"
    exec nonBuiltinHintCheck & " 2>&1 | grep 'may need `header:` to resolve' | grep -q 'Hint:'"
    exec nonBuiltinWarnCheck & " 2>&1 | grep 'may need `header:` to resolve' | grep -q 'Warning:'"
    # RFC-0001 slice A8: verifyProcs parity analog of the A6 non-builtin
    # hint check directly above.
    exec vpNonBuiltinHintCheck & " 2>&1 | grep 'may need `header:` to resolve' | grep -q 'Hint:'"
    exec vpNonBuiltinWarnCheck & " 2>&1 | grep 'may need `header:` to resolve' | grep -q 'Warning:'"
    exec protoEmitCheck
    exec "grep -rq 'extern int testlib_protoonly(void);' " & protoEmitDir
    # RFC-0001 slice A8: verifyProcs parity analog of A2's dynlib
    # prototype-only emission proof directly above.
    exec "grep -rq '" & vpProtoOnlyDecl & "' " & protoEmitDir
    exec protoGateTrueCheck
    exec protoGateFalseCheck
    # RFC-0001 slice A8: verifyProcs parity analogs of the A5 true/false-gate
    # C-inspection pair directly above.
    exec vpProtoGateTrueCheck
    exec vpProtoGateFalseCheck
    rmDir(protoEmitDir)
    exec protoOnlyCheck
    expectNoEmptyInclude("cat " & protoOnlyDir & "/*.c")
    exec "grep -rq '" & protoOnlyDecl & "' " & protoOnlyDir
    rmDir(protoOnlyDir)
    runDumpProbesCheck()
    # RFC-0001 §4 B.2: define-gated probe modes.
    exec probeMismatchVerifyFailCheck & " 2>&1 | grep -q 'signature mismatch'"
    exec probeMismatchExistenceSuccessCheck
    expectCompileFailure(probeAbsentCCheck)
    expectCompileFailure(probeAbsentCppCheck)
    exec probeNoTargetUnsetCheck & " 2>&1 | grep -q '" & probeNoTargetAnchor & "'"
    exec probeNoTargetSentinelCheck & " 2>&1 | grep -q '" & probeNoTargetAnchor & "'"
    runProbeOnlyChecks()
    runCorpusChecks()
    runManifestChecks()
    runVersionProbeChecks()
    runCompatReportManifestChecks("DYLD_LIBRARY_PATH=./tests nim c -r --path:src --passC:-I.")
    runDriftRequiredChecks("DYLD_LIBRARY_PATH=./tests nim c -r --path:src --passC:-I.")
    runDegradationChecks("DYLD_LIBRARY_PATH=./tests nim c -r --path:src --passC:-I.")
  else:
    exec "gcc -shared -fPIC -o tests/libtestlib.so tests/testlib.c"
    exec "gcc -shared -fPIC -o tests/libmagic.so tests/testlib.c"
    # Versioned soname with NO bare libvern.so — forces the major fallback.
    exec "gcc -shared -fPIC -o tests/libvern.so.3 tests/testlib.c"
    exec "LD_LIBRARY_PATH=./tests nim c -r --path:src --passC:-I. tests/test_softlink.nim"
    exec "LD_LIBRARY_PATH=./tests nim cpp -r --path:src --passC:-I. tests/test_softlink.nim"
    exec dupFailCheck & " 2>&1 | grep -q 'collides with an earlier dynlib block'"
    exec gateFailCheck & " 2>&1 | grep -q 'signature mismatch'"
    exec contraFailCheck & " 2>&1 | grep -q 'contradicts'"
    exec protoContraFailCheck & " 2>&1 | grep -q 'contradicts'"
    exec protoMismatchFailCheck & " 2>&1 | grep -q 'signature mismatch'"
    expectCompileFailure(protoConflictCCheck)
    expectCompileFailure(protoConflictCppCheck)
    # RFC-0001 slice A8: verifyProcs parity analogs of the A3/A4 negative
    # fixtures directly above.
    exec vpProtoMismatchFailCheck & " 2>&1 | grep -q 'signature mismatch'"
    expectCompileFailure(vpProtoConflictCCheck)
    expectCompileFailure(vpProtoConflictCppCheck)
    # RFC-0001 slice A4, optional extra confidence (gcc/clang-gated only —
    # never on the Windows/MSVC branch above): also inspect the compiler's
    # own wording for the redeclaration conflict. Deliberately NOT required
    # for the check to pass (the exit-code assertion above already is the
    # required, portable check) — this is a supplementary sanity grep on the
    # one CI leg most likely to catch a wording regression in this specific
    # gcc version, kept out of the required path since gcc's exact phrasing
    # ("conflicting types for ...") is not a stable cross-version/cross-
    # compiler contract the way softlink's own diagnostic strings are.
    exec protoConflictCCheck & " 2>&1 | grep -q 'conflicting types for'"
    # RFC-0001 slice A8: same optional gcc-gated wording sanity check, for
    # the verifyProcs conflict fixture.
    exec vpProtoConflictCCheck & " 2>&1 | grep -q 'conflicting types for'"
    exec hintCheck & " 2>&1 | grep 'not header-verified' | grep -q 'Hint:'"
    exec warnCheck & " 2>&1 | grep 'not header-verified' | grep -q 'Warning:'"
    exec reasonHintCheck & " 2>&1 | grep 'private symbol, no public header at any version' | grep -q 'Hint:'"
    exec reasonHintCheck & " 2>&1 | grep -q '(no justification)'"
    exec reasonWarnCheck & " 2>&1 | grep 'private symbol, no public header at any version' | grep -q 'Warning:'"
    exec reasonWarnCheck & " 2>&1 | grep -q '(no justification)'"
    exec nonBuiltinHintCheck & " 2>&1 | grep 'may need `header:` to resolve' | grep -q 'Hint:'"
    exec nonBuiltinWarnCheck & " 2>&1 | grep 'may need `header:` to resolve' | grep -q 'Warning:'"
    # RFC-0001 slice A8: verifyProcs parity analog of the A6 non-builtin
    # hint check directly above.
    exec vpNonBuiltinHintCheck & " 2>&1 | grep 'may need `header:` to resolve' | grep -q 'Hint:'"
    exec vpNonBuiltinWarnCheck & " 2>&1 | grep 'may need `header:` to resolve' | grep -q 'Warning:'"
    exec protoEmitCheck
    exec "grep -rq 'extern int testlib_protoonly(void);' " & protoEmitDir
    # RFC-0001 slice A8: verifyProcs parity analog of A2's dynlib
    # prototype-only emission proof directly above.
    exec "grep -rq '" & vpProtoOnlyDecl & "' " & protoEmitDir
    exec protoGateTrueCheck
    exec protoGateFalseCheck
    # RFC-0001 slice A8: verifyProcs parity analogs of the A5 true/false-gate
    # C-inspection pair directly above.
    exec vpProtoGateTrueCheck
    exec vpProtoGateFalseCheck
    rmDir(protoEmitDir)
    exec protoOnlyCheck
    expectNoEmptyInclude("cat " & protoOnlyDir & "/*.c")
    exec "grep -rq '" & protoOnlyDecl & "' " & protoOnlyDir
    rmDir(protoOnlyDir)
    runDumpProbesCheck()
    # RFC-0001 §4 B.2: define-gated probe modes.
    exec probeMismatchVerifyFailCheck & " 2>&1 | grep -q 'signature mismatch'"
    exec probeMismatchExistenceSuccessCheck
    expectCompileFailure(probeAbsentCCheck)
    expectCompileFailure(probeAbsentCppCheck)
    exec probeNoTargetUnsetCheck & " 2>&1 | grep -q '" & probeNoTargetAnchor & "'"
    exec probeNoTargetSentinelCheck & " 2>&1 | grep -q '" & probeNoTargetAnchor & "'"
    runProbeOnlyChecks()
    runCorpusChecks()
    runManifestChecks()
    runVersionProbeChecks()
    runCompatReportManifestChecks("LD_LIBRARY_PATH=./tests nim c -r --path:src --passC:-I.")
    runDriftRequiredChecks("LD_LIBRARY_PATH=./tests nim c -r --path:src --passC:-I.")
    runDegradationChecks("LD_LIBRARY_PATH=./tests nim c -r --path:src --passC:-I.")
    runHarvesterCheck()

task testMsvcExitCodes, "RFC-0001 slice A9: MSVC-only exit-code compile-failure checks":
  ## `task test`'s `when defined(windows):` branch always builds the
  ## fixture libraries with `gcc` and never passes `--cc:vcc`/`/std:clatest`
  ## -- it targets the windows-mingw CI leg, not MSVC. Making it MSVC-aware
  ## too (real `cl`-built fixtures, full suite, all grep checks under MSVC's
  ## diagnostic wording) is more surgery than RFC-0001 Section 9 A9 asks
  ## for: the RFC's stated minimum for the MSVC leg is the portable,
  ## exit-code-only A4 checks (softlink-authored-string greps are required
  ## on Linux/gcc only -- MSVC diagnostics differ enough from gcc/clang's
  ## that grepping them here would be the "overreach into flaky territory"
  ## the slice brief warns against). The full MSVC suite run (real `cl`,
  ## `/std:clatest` C23 gate, `-d:softlinkStrictVerify` no-op-tier trap) is
  ## unaffected and still runs directly from ci.yaml's own "Run tests
  ## (MSVC)" step, same as before this slice -- this task adds coverage, it
  ## doesn't replace that.
  ##
  ## These four checks need no built library at all (compile-only, no
  ## runtime dlsym dispatch), so they can run standalone against the real
  ## MSVC `cl` via `--cc:vcc`, independent of `task test`'s fixture-build
  ## assumptions. Mirrors RFC-0001 slice A4's C/C++ backend pair, for both
  ## the dynlib (tfail_prototype_conflict.nim) and verifyProcs
  ## (tfail_verifyprocs_prototype_conflict.nim) prototype-conflict fixtures
  ## already used by `task test`'s own `protoConflictCCheck`/
  ## `protoConflictCppCheck`/`vpProtoConflictCCheck`/`vpProtoConflictCppCheck`
  ## (same fixtures, same `expectCompileFailure` helper, `--cc:vcc` swapped
  ## in for the default gcc and `/I.`/`/std:clatest` swapped in for `-I.`).
  const vccFlags = " --cc:vcc --path:src --passC:/I. --passC:/std:clatest "
  expectCompileFailure("nim c" & vccFlags & "tests/tfail_prototype_conflict.nim")
  expectCompileFailure("nim cpp" & vccFlags & "tests/tfail_prototype_conflict.nim")
  expectCompileFailure("nim c" & vccFlags & "tests/tfail_verifyprocs_prototype_conflict.nim")
  expectCompileFailure("nim cpp" & vccFlags & "tests/tfail_verifyprocs_prototype_conflict.nim")

  # RFC-0001 slice B3: the harvester's calibration preflight must REFUSE
  # under MSVC's DEFAULT compile mode (`--cc:vcc`, no `/std:clatest`) — the
  # structural guard against a degraded verification tier silently
  # poisoning a harvest with false `verified` facts. Unlike the four
  # checks above (which assert a raw COMPILE fails), this asserts a
  # successful compile-and-RUN whose own `std/unittest` checks are the
  # actual assertion — `tests/tharvest_msvc_calibration_refusal.nim` sets
  # a nonzero program result if any of its checks fail (same mechanism
  # `runHarvesterCheck` in `task test` above relies on), so `exec` here
  # fails this task exactly like every other check does. The ORCHESTRATING
  # `nim c -r` below deliberately does NOT pass `--cc:vcc` itself — only
  # the harvester's INTERNAL probe compiles (configured inside that test
  # file) target vcc; see its doc comment for the full rationale.
  exec "nim c -r --path:src tests/tharvest_msvc_calibration_refusal.nim"
