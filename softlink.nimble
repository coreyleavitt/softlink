# Package
version       = "0.11.1"
author        = "Corey Leavitt"
description   = "Type-safe optional dynamic library bindings for Nim"
license       = "Apache-2.0"
srcDir        = "src"

# Dependencies
requires "nim >= 2.0.0"

import std/json
import std/strutils
import "src/softlink/versions"

proc checkVersionOfRecordPin() =
  ## RFC-0003 §2/§7 slice C1: `softlink/versions.softlinkVersion` is
  ## `HarvestMeta.harvesterVersion`'s source of truth (tools/harvest/
  ## harvester.nim's `defaultHarvestMeta`) -- deliberately hand-bumped
  ## rather than derived from `NimblePkgVersion` (which would stamp the
  ## harvest CLI's own independent 0.1.x lineage, not the core package's --
  ## see that const's own doc comment). Hand-bumped values drift apart
  ## silently unless something checks them: `version` below is nimble's own
  ## top-level NimScript global (assigned at the top of THIS file, already
  ## in scope everywhere below it in the same script); `softlinkVersion` is
  ## already in scope via this file's own `import "src/softlink/versions"`
  ## above -- no new import needed on either side of the comparison.
  if version != softlinkVersion:
    quit("softlink: RFC-0003 slice C1: softlink.nimble's version ('" &
         version & "') and softlink/versions.softlinkVersion ('" &
         softlinkVersion & "') have drifted apart -- bump both together " &
         "(HarvestMeta.harvesterVersion is sourced from the versions.nim " &
         "const specifically so it reflects the CORE package's own " &
         "release, not the harvest CLI's independent 0.1.x lineage -- see " &
         "RFC-0003 SS2)")

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
                     "optional", "noverify", "noverifyReason", "since", "until"]
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
  ## specific diagnostic string via `exec cmd | grep -Fq ...` — `exec`
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

proc runDualNimcacheCompile(dir1, dir2, baseFlags, extraFlag2, fixture,
                             exePath: string) =
  ## Shared "dual-compile" shape behind RFC-0002's gated-drift and
  ## synthesized-gate checks: the SAME fixture compiled TWICE via `nim c`,
  ## each invocation getting its own `--nimcache` dir. A `-D`/`/D` define
  ## changes no Nim-emitted C, so a shared nimcache risks Nim's
  ## content-hashed cache reusing the first invocation's object file and the
  ## second "passing" without recompiling anything under the new header
  ## shape at all — see each call site's own doc comment for the
  ## hand-verified RED evidence this per-invocation isolation is built to
  ## catch. `baseFlags` is shared by both invocations (already carrying its
  ## own leading/trailing spaces, e.g. `" --path:src --passC:-I. "` or the
  ## MSVC `vccFlags`); `extraFlag2` (e.g. a `-DTESTLIB_VERSION=2` define) is
  ## appended after `baseFlags`, before `fixture`, to the SECOND invocation
  ## only — the flag that flips the header branch under test. Cleans up
  ## both nimcache dirs (before AND after, matching every call site's
  ## pre-existing stale-dir defensiveness) and the compiled executable
  ## (`exePath`) once both compiles have run.
  ##
  ## Hoisted to file scope (code-review finding CR1-10) so both `task
  ## test`'s nested `runGatedDriftChecks`/`runVersionMacrosGateChecks` and
  ## `task testMsvcExitCodes`'s top-level vcc-flavored pair can share ONE
  ## definition instead of repeating the same six-line shape four times.
  if dirExists(dir1): rmDir(dir1)
  if dirExists(dir2): rmDir(dir2)
  exec "nim c --nimcache:" & dir1 & baseFlags & fixture
  exec "nim c --nimcache:" & dir2 & baseFlags & extraFlag2 & fixture
  if dirExists(dir1): rmDir(dir1)
  if dirExists(dir2): rmDir(dir2)
  if fileExists(exePath): rmFile(exePath)

proc walkGenSources(dir: string): seq[string] =
  ## All generated .c/.cpp files under one --nimcache dir. NimScript's
  ## `listDirs`/`listFiles` are each non-recursive (see their doc comments
  ## in system/nimscript.nim), so this walks the tree by hand with an
  ## explicit stack rather than reaching for `std/os.walkDirRec`.
  ##
  ## Hoisted to file scope (was local to `task test`, forward-declared
  ## purely so `expectNoEmptyInclude` — defined earlier in that task than
  ## this proc's real body — could call it) so the portable `expectInGenC`
  ## helper below, itself file-scope so every OS branch of `task test` can
  ## share ONE definition instead of tripling a grep/findstr-driven check,
  ## can call it too. `task test`'s own nested helpers (`slurpGenSources`,
  ## `expectAnchor`, `expectAdjacentPair`) still call this exact proc via
  ## ordinary enclosing-scope lookup — no forward declaration needed now
  ## that the one real definition sits above the whole task in the file.
  var stack = @[dir]
  while stack.len > 0:
    let d = stack.pop()
    for f in listFiles(d):
      if f.endsWith(".c") or f.endsWith(".cpp"):
        result.add(f)
    for sub in listDirs(d):
      stack.add(sub)

proc runCapture(cmd: string): string =
  ## Run `cmd` and return its combined stdout+stderr. `gorgeEx` shells out
  ## via `execCmdEx` (`poStdErrToStdOut`), so nim's Hint/Warning/Error text
  ## is captured regardless of which stream it landed on — and because
  ## `cmd` carries NO shell redirect/pipe metacharacters (no `2>&1`, no
  ## `|`), it runs identically via `gorgeEx` on every OS's own shell
  ## (`sh -c` on POSIX, `cmd /c` on Windows).
  let (output, _) = gorgeEx(cmd)
  result = output

proc expectDiag(cmd, label: string, needles: varargs[string]) =
  ## Portable replacement for `exec cmd & " 2>&1 | grep -Fq '<needle>'"` /
  ## `exec cmd & " 2>&1 | findstr /C:\"<needle>\" >NUL"` (including the
  ## doubled-`findstr`/doubled-`grep` Hint:/Warning: pairs — pass every
  ## required needle and all must be present). Runs the BARE compile
  ## command — no `2>&1`/`|`/`>NUL` — and asserts every needle appears in
  ## the captured output. Those exact tokens are what broke Windows CI:
  ## `nimble`'s `exec` (which is `gorgeEx`-based) does not shell-interpret
  ## redirects/pipes, so `nim` itself received `2>&1`, `|`, `findstr`... as
  ## argv and rejected them with "arguments can only be given if the
  ## '--run' option is selected" — a bare command has no such tokens to
  ## mis-parse, on any OS.
  ##
  ## Deliberately exit-code-agnostic, matching the ORIGINAL shell
  ## pipeline's actual semantics: in `cmd1 | cmd2`, the pipe's reported
  ## exit status is cmd2's (grep's/findstr's), never cmd1's, so the
  ## original checks already only ever asserted "the needle is somewhere
  ## in the output" — never anything about whether the compile itself
  ## succeeded or failed. That is exactly what lets this ONE helper cover
  ## both this file's compile-FAILURE checks (the needle is the error
  ## text) and its compile-SUCCESS-with-Hint/Warning checks (the needle is
  ## the hint/warning text).
  let output = runCapture(cmd)
  for n in needles:
    if n notin output:
      echo output
      quit("softlink: expected diagnostic missing: " & label &
           " (needle not found: '" & n & "'): " & cmd)

proc expectInGenC(dir, needle, label: string) =
  ## Portable replacement for `exec "findstr /s /m /c:\"<needle>\" " & dir &
  ## "\\*.c >NUL"` and its `grep -rFq '<needle>' dir` sibling: recursively
  ## reads every generated .c/.cpp under `dir` (via the shared `walkGenSources`
  ## above) and asserts `needle` appears in at least one.
  for f in walkGenSources(dir):
    if needle in readFile(f):
      return
  quit("softlink: expected string not found in generated C: " & label &
       " (needle: '" & needle & "', dir: " & dir & ")")

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

proc expectManifestCompileFail(cmd: string, mustContain: openArray[string],
                                mustNotContain: openArray[string] = []) =
  ## The failure-polarity mirror of `expectManifestCompileOk` above.
  ## `mustNotContain` (RFC-0003 §2/§7 slice C1) defaults to empty so every
  ## pre-existing call site is unaffected.
  let (output, code) = gorgeEx(cmd)
  if code == 0:
    echo output
    quit("softlink: RFC-0001 slice B6a expected a compile FAILURE: " & cmd)
  for s in mustContain:
    if s notin output:
      echo output
      quit("softlink: RFC-0001 slice B6a expected compile output to " &
           "contain '" & s & "': " & cmd)
  for s in mustNotContain:
    if s in output:
      echo output
      quit("softlink: RFC-0003 slice C1 expected compile output to NOT " &
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
  ## return NATIVE-separator paths — forward slashes on POSIX, but
  ## BACKslashes on Windows (`"tests\corpus\1.0.0"`) — so split on whichever
  ## separator appears last rather than assuming `'/'` (that assumption made
  ## every corpus version look absent on the Windows CI leg). `walkGenSources`
  ## above is unaffected: it only does suffix `.c`/`.cpp` checks and re-feeds
  ## whole paths back to `listDirs`/`listFiles`/`readFile`, all of which are
  ## separator-agnostic — no `std/os` import needed here either.
  var i = path.rfind('/')
  let j = path.rfind('\\')
  if j > i: i = j
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

proc slurpGenSourcesFile(dir: string): string =
  ## File-scope twin of `task test`'s own nested `slurpGenSources` (that one
  ## is local to the task and unreachable from here) — identical shape:
  ## concatenate every generated .c/.cpp file under `dir` via the shared
  ## `walkGenSources` walk.
  for f in walkGenSources(dir):
    result.add(readFile(f))
    result.add('\n')

proc extractBetweenAnchors(dir, beginAnchor, endAnchor: string): string =
  ## RFC-0003 §7 A1: the extraction half of the NEW byte-identical
  ## generated-C golden-snapshot mechanism — nothing in this suite did
  ## whole-file/whole-span comparison before this (every existing check
  ## here, `expectAnchor`/`expectAdjacentPair`, is substring- or
  ## adjacency-window-only). `beginAnchor`/`endAnchor` are the EXACT,
  ## tag-scoped literal marker comments `genVerifyBlock` emits around its
  ## include-section scaffolding and its verify-proc body (`src/softlink/
  ## verify.nim`'s "SOFTLINK_VERIFY_APPARATUS_*" anchors) — both markers'
  ## OWN text is excluded from the returned span; only what's BETWEEN them
  ## is compared. `dir` must hold exactly one compile's generated sources
  ## (this is only ever called against `tests/tgolden_verify_apparatus.nim`'s
  ## own dedicated --nimcache dir, which contains exactly one dynlib block,
  ## so the FIRST occurrence of each anchor is unambiguous).
  let text = slurpGenSourcesFile(dir)
  let bIdx = text.find(beginAnchor)
  if bIdx < 0:
    quit("softlink: RFC-0003 slice A1 golden check: begin anchor not " &
         "found under " & dir & ": " & beginAnchor)
  let contentStart = bIdx + beginAnchor.len
  let eIdx = text.find(endAnchor, contentStart)
  if eIdx < 0:
    quit("softlink: RFC-0003 slice A1 golden check: end anchor not " &
         "found (after its matching begin anchor) under " & dir & ": " & endAnchor)
  text[contentStart ..< eIdx]

proc runGoldenVerifyApparatusCheck() =
  ## RFC-0003 §7 A1: the byte-identical half of the NEW golden-snapshot
  ## infrastructure (the absence-under-ground-truth half lives in `task
  ## test`'s own `runGroundTruthChecks`, right next to the
  ## `runProbeOnlyChecks` fixtures it reuses). Compiles the dedicated,
  ## minimal `tests/tgolden_verify_apparatus.nim` fixture (its own tiny
  ## header, `tests/testlib_golden.h`, decoupled from `tests/testlib.h`'s
  ## churn) with NO probe defines at all, extracts the two anchored spans
  ## `genVerifyBlock` emits (the include-section scaffolding and the
  ## verify-proc body — see `extractBetweenAnchors`), and compares each
  ## byte-for-byte against a committed golden file.
  ##
  ## `--stacktrace:off --linetrace:off --excessiveStackTrace:off`: without
  ## these, Nim interleaves `nimln_(<source line number>)` debug-instrumentation
  ## calls into the verify proc's body — hand-verified present in a plain
  ## `nim c --compileOnly` of this same fixture — which would make the
  ## golden's body span drift every time an UNRELATED doc-comment edit in
  ## `tests/tgolden_verify_apparatus.nim` shifts a line number, defeating
  ## the entire point (a golden diff must mean the emitted C actually
  ## changed, not that a comment moved). With them off, the body span
  ## contains only `genVerifyBlock`'s own emitted text, confirmed by hand.
  ##
  ## Linux/gcc leg only, following `runHarvesterCheck`'s own precedent
  ## immediately below (its doc comment's reasoning applies identically
  ## here: this mechanism doesn't vary by OS, so doubling the cost on every
  ## CI leg wasn't judged worth it).
  ##
  ## Mechanical regen path (Nim-version bumps are EXPECTED to eventually
  ## shift Nim's own codegen shape, which must produce a loud diff here,
  ## not silent drift — the fix is to re-run this exact command, inspect
  ## the diff it makes to the golden files, and commit it deliberately):
  ##
  ##   SOFTLINK_REGEN_GOLDEN=1 nimble test
  ##
  ## (or, narrower: `SOFTLINK_REGEN_GOLDEN=1 nim c ... ` is not sufficient
  ## by itself — this proc, not the compiler, does the regen — so the
  ## `nimble test` invocation above, which reaches this proc on the
  ## Linux/gcc leg, is the actual regen command. If run from a container as
  ## root, `chown` the two golden files back to your own uid/gid afterward.)
  const dir = "tests/nimcache_golden_verify_apparatus"
  if dirExists(dir): rmDir(dir)
  ## `deriveLibPattern("libsoftlinkgolden.so")`'s base name — see
  ## `tests/tgolden_verify_apparatus.nim`'s own dynlib pattern string.
  const tag = "Softlinkgolden"
  const beginIncludes = "/* SOFTLINK_VERIFY_APPARATUS_INCLUDES_BEGIN:" & tag & " */\n"
  const endIncludes = "/* SOFTLINK_VERIFY_APPARATUS_INCLUDES_END:" & tag & " */\n"
  const beginBody = "/* SOFTLINK_VERIFY_APPARATUS_BODY_BEGIN:" & tag & " */\n"
  const endBody = "/* SOFTLINK_VERIFY_APPARATUS_BODY_END:" & tag & " */\n"
  const goldenIncludesPath = "tests/golden_verify_apparatus_includes.c"
  const goldenBodyPath = "tests/golden_verify_apparatus_body.c"

  exec "nim c --compileOnly --path:src --passC:-I. --stacktrace:off " &
       "--linetrace:off --excessiveStackTrace:off --nimcache:" & dir &
       " tests/tgolden_verify_apparatus.nim"

  let gotIncludes = extractBetweenAnchors(dir, beginIncludes, endIncludes)
  let gotBody = extractBetweenAnchors(dir, beginBody, endBody)
  rmDir(dir)

  if getEnv("SOFTLINK_REGEN_GOLDEN") == "1":
    writeFile(goldenIncludesPath, gotIncludes)
    writeFile(goldenBodyPath, gotBody)
    echo "softlink: RFC-0003 slice A1: REGENERATED " & goldenIncludesPath &
         " and " & goldenBodyPath & " — inspect the diff and commit deliberately"
    return

  if not fileExists(goldenIncludesPath) or not fileExists(goldenBodyPath):
    quit("softlink: RFC-0003 slice A1 golden check: golden file(s) missing " &
         "— run with SOFTLINK_REGEN_GOLDEN=1 to create them (see " &
         "runGoldenVerifyApparatusCheck's own doc comment)")

  let wantIncludes = readFile(goldenIncludesPath)
  let wantBody = readFile(goldenBodyPath)
  if gotIncludes != wantIncludes:
    quit("softlink: RFC-0003 slice A1 golden check: " & goldenIncludesPath &
         " MISMATCH — generated C's include-section scaffolding changed. " &
         "If this is an intentional verify.nim change (or a Nim-version " &
         "codegen shift), regenerate with SOFTLINK_REGEN_GOLDEN=1 nimble " &
         "test and commit the diff deliberately.\n--- golden ---\n" &
         wantIncludes & "\n--- got ---\n" & gotIncludes)
  if gotBody != wantBody:
    quit("softlink: RFC-0003 slice A1 golden check: " & goldenBodyPath &
         " MISMATCH — generated C's verify-proc body changed. If this is " &
         "an intentional verify.nim change (or a Nim-version codegen " &
         "shift), regenerate with SOFTLINK_REGEN_GOLDEN=1 nimble test and " &
         "commit the diff deliberately.\n--- golden ---\n" & wantBody &
         "\n--- got ---\n" & gotBody)
  echo "softlink: RFC-0003 slice A1: golden verify-apparatus snapshot matches"

proc runHarvesterCheck(clangLeg = false) =
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
  ## version, existence+verify per probed symbol) — 45/48 compiles
  ## (standard/fast path) for this fixture as of RFC-0003 slice B2c's two
  ## added tolerance-control symbols (`tests/tharvest.nim`'s own
  ## compile-count arithmetic pins the exact, derived-then-confirmed
  ## totals), on the order of a minute of wall time.
  ##
  ## `clangLeg` (RFC-0003 slice B2c, round-2 blocking item): this proc used
  ## to run on the Linux/gcc leg only, with a comment explicitly naming
  ## "revisit if Stage B ships a regression those legs would have caught"
  ## as the trigger for wiring it into macOS/clang too — Stage B (B2a's
  ## `-Werror=incompatible-pointer-types` pin, B2b's Gap B end-to-end fix)
  ## now HAS shipped exactly that kind of fix, and B2c adds the const-
  ## tolerance regression controls (RFC-0003 §5.2 i: the pins must not
  ## reverse GH #11's const-tolerance) that only mean something if they're
  ## actually checked under a real clang compile, not just gcc. `clangLeg =
  ## true` passes `-d:softlinkHarvestClangOpts` to `tests/tharvest.nim`,
  ## which — per RFC-0003 §8 resolution 1's "caller-controlled opts, no
  ## auto-detection" principle — is the ONE switch that makes `harvest()`/
  ## `runCalibration()` build their `HarvestOptions` from
  ## `clangHarvestOptions()` instead of `defaultHarvestOptions()` (see that
  ## file's own doc comment on the define). No `--cc:clang` needed: Nim's
  ## own default C compiler on macOS is already clang (Apple's `cc`), same
  ## toolchain `task test`'s macosx branch already builds the fixture
  ## libraries with. Windows/MSVC still gets NO harvest check here — MSVC
  ## calibration-refusal coverage is `task testMsvcExitCodes`'s narrower,
  ## much cheaper single-preflight run (RFC-0001 §9 B3; RFC-0003 slice B3's
  ## territory, not this proc's) — doubling this proc's ~1-minute real-
  ## compile cost onto the windows-mingw leg too was never in scope and
  ## still isn't.
  ##
  ## RFC-0001 slice B8: `tests/tharvest_cli.nim` unit-tests
  ## `tools/harvest/harvest_cli.nim`'s `parseHarvestCli` — a PURE function
  ## over `seq[string]`, zero subprocess/filesystem access — so it costs
  ## well under a second, unlike the ~1-minute real-compile suite above.
  ## Run right alongside it (same `runHarvesterCheck` proc) so both of this
  ## slice's suites are exercised by the one `task test` call site below.
  exec "nim c -r --path:src tests/tharvest_cli.nim"
  let clangDefine = if clangLeg: " -d:softlinkHarvestClangOpts " else: " "
  exec "nim c -r --path:src" & clangDefine & "tests/tharvest.nim"

task test, "Run tests":
  # RFC-0003 §2/§7 slice C1: cheap, first thing -- no point running an
  # ~hour of compiles before catching a version-of-record drift.
  checkVersionOfRecordPin()
  # testlib.c is compiled under several names to exercise deriveLibPattern:
  #   libtestlib.*  — explicit-pattern block (verbatim escape hatch)
  #   libmagic.*    — bare logical name "magic" resolves here
  #   libvern.so.3  — runtime-only versioned soname (Linux; no bare symlink)
  # Negative compile tests (`expectDiag` quits if the expected message is
  # absent, failing the task — including if the file unexpectedly compiles,
  # since a fixed bug would mean the error text — the needle — never appears):
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
  # `emitPrototypeDecl`'s doc comment in src/softlink/verify.nim).
  const dupFailCheck = "nim c --path:src tests/tfail_duplicate_dynlib.nim"
  const gateFailCheck = "nim c --path:src --passC:-I. tests/tfail_verifywhen_mismatch.nim"
  # Finding #19.2: `gateFailCheck`'s fixture (tfail_verifywhen_mismatch.nim)
  # binds `testlib_gated` with a deliberately wrong return type; the bare
  # phrase "signature mismatch" is produced by softlink's diagnostic for
  # ANY mismatched proc, so this pins the specific symbol name the fixture
  # actually exercises, not merely that some mismatch fired somewhere.
  const gateFailAnchor = "testlib_gated signature mismatch"
  const contraFailCheck = "nim c --path:src tests/tfail_verifywhen_noverify.nim"
  const protoContraFailCheck = "nim c --path:src tests/tfail_prototype_noverify.nim"
  # Finding #19.1: both `contraFailCheck` and `protoContraFailCheck` bind a
  # proc named "foo" and both of their respective macro errors contain the
  # bare word "contradicts" (`{.verifyWhen.} contradicts {.noverify.}` vs.
  # `{.prototype.} contradicts {.noverify.}` — see src/softlink/pragmas.nim's
  # `parseProcPragmas`), so a bare `grep -Fq 'contradicts'` on either check
  # can't tell which of the two contradictions actually fired — it would
  # still "pass" if the WRONG one fired. Each anchor below names the exact
  # pragma pair so the grep can only match its own fixture's diagnostic.
  const contraFailAnchor = "{.verifyWhen.} contradicts {.noverify.}"
  const protoContraFailAnchor = "{.prototype.} contradicts {.noverify.}"
  # Finding #19.9 (code-review coverage gap): `analyzePrototype`'s own
  # fpret/variadic CLASSIFICATION is pinned by pure unit tests
  # (tests/test_softlink.nim's "analyzer: ..." suite), and the rejection
  # itself by `compiles()` checks in the same file — but `compiles()` can
  # only observe pass/fail, never inspect the actual diagnostic TEXT, so
  # neither pinned the user-facing wording. These two fixtures + anchors
  # close that gap (see each fixture's own doc comment).
  const protoVariadicFailCheck = "nim c --path:src tests/tfail_prototype_variadic.nim"
  const protoVariadicFailAnchor = "prototype must not be variadic"
  const protoFnptrReturnFailCheck = "nim c --path:src tests/tfail_prototype_fnptr_return.nim"
  const protoFnptrReturnFailAnchor = "prototype has a function-pointer return type"
  const protoMismatchFailCheck = "nim c --path:src --passC:-I. tests/tfail_prototype_mismatch.nim"
  # Finding #19.2: same generic-phrase problem as `gateFailAnchor` above —
  # tfail_prototype_mismatch.nim exercises `testlib_protoonly` specifically,
  # verified against its vendored {.prototype.} (not a header).
  const protoMismatchFailAnchor = "testlib_protoonly signature mismatch vs vendored prototype"
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
  # Finding #19.2: the verifyProcs parity analog of `protoMismatchFailAnchor`
  # above — same symbol (`testlib_protoonly`), same vendored-prototype
  # declaration source, bound through `verifyProcs` instead of `dynlib`.
  const vpProtoMismatchFailAnchor = "testlib_protoonly signature mismatch vs vendored prototype"
  const vpProtoConflictCCheck =
    "nim c --path:src --passC:-I. tests/tfail_verifyprocs_prototype_conflict.nim"
  const vpProtoConflictCppCheck =
    "nim cpp --path:src --passC:-I. tests/tfail_verifyprocs_prototype_conflict.nim"
  # Code-review finding F4 (coverage-only): the {.optional.} rejection
  # branch in `parseProcPragmas`'s `ppmVerifyProcs` arm had zero test
  # coverage. `tests/test_softlink.nim`'s "compile-time: verifyProcs
  # rejects noverify and unknown pragmas" suite now also has a `compiles()`
  # check for `optional`; this fixture + grep additionally pins the EXACT
  # diagnostic wording, following the same tfail-fixture-plus-grep pattern
  # `contraFailCheck` above already uses for the `noverify`/`verifyWhen`
  # contradiction message.
  const vpOptionalFailCheck = "nim c --path:src tests/tfail_verifyprocs_optional.nim"
  const vpOptionalFailAnchor =
    "verifyProcs does not support pragma 'optional' on proc 'vp_optional_fail'"

  proc expectNoEmptyInclude(dir: string) =
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
    ## This is an ABSENCE assertion, so (unlike every `grep -Fq` presence
    ## check in this file) it can't just be `exec cmd | grep -Fq ...`: that
    ## pattern makes the task FAIL when the string is absent, the opposite
    ## polarity of what's wanted here.
    ##
    ## Code-review Finding #5 fix: this used to run an OS-specific
    ## "dump these files to stdout" shell command (`cat`/`type`) via
    ## `gorgeEx` and inspect the captured stdout — which vacuously "passed"
    ## two different ways: (1) `gorgeEx`'s exit code was discarded, so a
    ## missing directory or an unmatched glob (empty output either way)
    ## looked identical to "inspected real files and found nothing bad";
    ## (2) the flat glob (`dir/*.c`) is NON-RECURSIVE, unlike the sibling
    ## presence checks on these same nimcache dirs (`expectAnchor`'s
    ## `grep -rFq`/`findstr /s`), so a nested nimcache subtree would silently
    ## go uninspected. Both are closed by enumerating files Nim-side via the
    ## existing recursive `walkGenSources` and reading them directly with
    ## `readFile` — no shell dump command, no OS split, and a hard failure
    ## when the walk finds nothing to inspect (the vacuous-pass case: an
    ## absence check that inspected zero files proves nothing).
    let files = walkGenSources(dir)
    if files.len == 0:
      quit("softlink: RFC-0001 slice A6 expected to find generated .c/.cpp " &
           "files under '" & dir & "' to inspect for `#include \"\"`, but " &
           "the walk found none — an absence check over zero files proves " &
           "nothing, so this is a failure, not a vacuous pass")
    for f in files:
      if "#include \"\"" in readFile(f):
        echo f
        quit("softlink: RFC-0001 slice A6 expected NO invalid `#include \"\"` " &
             "in the all-prototype-only verify TU, but found one in " & f)
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
  # RFC 0011 S0a item 6: the block-level noverify default collapses every
  # symbol it covers into ONE summary line ("N symbols, block-level
  # reason: ...") in the same hint/warning above, while a proc's OWN
  # explicit {.noverify.} keeps its individual line — this fixture carries
  # two block-defaulted procs and one with its own justification, so both
  # renderings are exercised in the same compile, same convention as
  # `reasonHintCheck`/`reasonWarnCheck` directly above.
  const noverifyBlockHintCheck = "nim c --compileOnly --path:src tests/thint_noverify_block.nim"
  const noverifyBlockWarnCheck = "nim c --compileOnly --path:src -d:softlinkStrictVerify tests/thint_noverify_block.nim"
  # RFC-0002 §4.1/§6, slice A3: a required (non-{.optional.}) proc carrying
  # {.until.} gets the same hint/warning treatment, precedent-named in the
  # RFC as "the per-block noverify hint" above. The fixture header-verifies
  # for real (`header: "tests/testlib.h"`), so this needs `--passC:-I.`
  # like the manifest checks' `mcBase`, unlike the noverify-only fixtures
  # above which need no header at all.
  const untilRequiredHintCheck =
    "nim c --compileOnly --path:src --passC:-I. tests/thint_until_required.nim"
  const untilRequiredWarnCheck = "nim c --compileOnly --path:src --passC:-I. " &
    "-d:softlinkStrictVerify tests/thint_until_required.nim"
  # RFC-0001 slice A6: a {.prototype.}-only proc (no {.header.}) whose
  # prototype references a non-builtin identifier (found via the shared
  # A1 tokenizer) must emit a hint naming it — "this prototype may need
  # `header:` to resolve <T>" — upgraded to a warning under
  # -d:softlinkStrictVerify, same convention as the {.noverify.} hint above.
  const nonBuiltinHintCheck =
    "nim c --compileOnly --path:src tests/thint_prototype_nonbuiltin.nim"
  const nonBuiltinWarnCheck = "nim c --compileOnly --path:src " &
    "-d:softlinkStrictVerify tests/thint_prototype_nonbuiltin.nim"
  # Code-review finding CR1-12: a versionMacros(...) directive nothing in
  # the block consumes (no {.until.} proc synthesized a gate from it) must
  # hint, saying so — unlike every OTHER hint in this group, this one is
  # deliberately NOT upgraded to a warning under -d:softlinkStrictVerify
  # (see `checkVersionMacrosConsumed`'s doc comment, src/softlink/
  # pragmas.nim, for why: it's a lint on dead source, not a verification
  # trust point). `versionMacrosUnusedStrictCheck` below proves that
  # non-escalation directly, rather than merely asserting the plain hint.
  const versionMacrosUnusedHintCheck =
    "nim c --compileOnly --path:src tests/thint_versionmacros_unused.nim"
  const versionMacrosUnusedStrictCheck = "nim c --compileOnly --path:src " &
    "-d:softlinkStrictVerify tests/thint_versionmacros_unused.nim"
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
  # line, so finding the declaration text inside that window proves the gate
  # actually wraps the declaration, not some unrelated part of the file —
  # exactly the adjacency `expectAdjacentPair` (shared, OS-agnostic Nim-side
  # check; see its own doc comment) asserts below, using this anchor/decl pair.
  const protoGateTrueAnchor =
    "#if (TESTLIB_VERSION >= 1) /* softlink verifyWhen: prototype decl */"
  const protoGateTrueDecl = "extern int testlib_proto_gated_true(void);"
  # The false-gate mirror — REQUIRED, not merely supplementary (see below for
  # why). testlib_proto_gated_false's `#if (TESTLIB_VERSION >= 99)` gate does
  # NOT hold (TESTLIB_VERSION is 1), and its vendored prototype is
  # deliberately WRONG — different return type and arity than the real C
  # function. Finding both the gate line and the deliberately-wrong extern
  # text in the generated C proves the declaration was emitted-but-suppressed
  # (never seen by the C compiler).
  #
  # Empirically verified this check is load-bearing, not decorative:
  # injecting a declaration-gating regression (emitPrototypeDecl always
  # emitting the `extern`, ignoring `verifyWhen`) left `nim c --compileOnly`
  # AND the full `nim c -r`/`nim cpp -r` suite green — every runtime test,
  # including this slice's dispatch checks, still passed. Runtime dispatch
  # never calls a C symbol by name (it goes through a dlsym'd function
  # pointer), and this fixture has no `{.header.}` to conflict with, so a
  # leaked, unused, wrong-arity `extern` declaration is inert C — nothing
  # calls it, nothing else declares the same symbol, so gcc never objects.
  # Only `expectAdjacentPair` below caught the injected regression. This is
  # why a false-gate proc's runtime behavior (the RFC's "(suite)" scope for
  # this item) cannot by itself prove the DECLARATION is gated — only the
  # assert's independent, already-correct gating (unaffected by the
  # injected bug) — so this C-inspection is added beyond the slice's
  # literal text to actually close that coverage gap.
  const protoGateFalseAnchor =
    "#if (TESTLIB_VERSION >= 99) /* softlink verifyWhen: prototype decl */"
  const protoGateFalseDecl =
    "extern void testlib_proto_gated_false(double a, double b, double c);"
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
  # C-inspection pair above (protoGateTrueAnchor/protoGateFalseAnchor), using
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
  const vpProtoGateFalseDecl =
    "extern void vp_proto_gated_false(double a, double b, double c);"

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
    # RFC 0011 S0a item 1: the `identBase "DumpfooAlt"` block's dump file —
    # named after the OVERRIDE, not the pattern-derived "Dumpfoo" the
    # first block in this fixture already claims.
    let dynlibAltFile = dumpProbesDir & "/DumpfooAlt.probes.json"
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
    writeFile(dynlibAltFile, "not valid json, pre-existing garbage")
    exec dumpProbesCheck
    validateProbeJson(dynlibFile, "dynlib", "Dumpfoo")
    validateProbeJson(verifyFile, "verifyProcs", "VerifyTestlib_noop")
    validateProbeJson(dynlibAltFile, "dynlib", "DumpfooAlt")

    # RFC 0011 S0a item 3: `dumpfoo_alias` (`{.symbol: "testlib_unheralded".}`)
    # proves `cName` now carries the REAL, independently-tracked C symbol —
    # distinct from `nimName` — rather than always duplicating it (the
    # pre-item-3 state `probeFactsJson`'s own doc comment, src/softlink.nim,
    # used to describe). `validateProbeJson` above only checks the KEY is
    # present, not its value, so this is a separate, targeted assertion.
    let dumpfooJson = parseJson(readFile(dynlibFile))
    var foundAlias = false
    for p in dumpfooJson["procs"]:
      if p["nimName"].getStr == "dumpfoo_alias":
        foundAlias = true
        if p["cName"].getStr != "testlib_unheralded":
          quit("softlink: RFC 0011 S0a item 3: " & dynlibFile &
               " dumpfoo_alias entry: expected cName 'testlib_unheralded', " &
               "got '" & p["cName"].getStr & "'")
        if p["cName"].getStr == p["nimName"].getStr:
          quit("softlink: RFC 0011 S0a item 3: " & dynlibFile &
               " dumpfoo_alias entry: expected cName != nimName for a " &
               "renamed proc, both were '" & p["nimName"].getStr & "'")
    if not foundAlias:
      quit("softlink: RFC 0011 S0a item 3: " & dynlibFile &
           " has no 'dumpfoo_alias' proc entry to validate")
    echo "softlink: RFC 0011 S0a item 3: validated dumpfoo_alias cName != nimName in " & dynlibFile

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
  # `genVerifyBlock`, so both macros get it for free — see src/softlink/verify.nim).
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
  #      const's doc comment in src/softlink/verify.nim): the untrimmed, space-
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
  # Adjacency proof (same rigor as `expectAdjacentPair`'s line-window scan
  # below, just expressed as one literal substring since the exact
  # newline-joined text is known statically): the gated proc's existence
  # reference — ALL THREE tiers — sits directly
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

  proc expectAdjacentPair(dir, anchor, decl, label: string) =
    ## Finding #19.4 (code-review coverage gap): OS-agnostic adjacency proof
    ## — `decl` must occur within 5 lines AFTER a line containing `anchor`,
    ## in the SAME generated .c/.cpp file under `dir` (mirrors grep's own
    ## `-A5` semantics: the matching line plus its 5 following lines).
    ##
    ## Portable-diagnostics cleanup: this used to run ADDITIVELY alongside
    ## two weaker, OS-specific approximations — the POSIX branches' own
    ## `grep -rFA5 anchor | grep -Fq decl` pipeline (built by the now-removed
    ## protoGateTrueCheck/protoGateFalseCheck/vpProtoGateTrueCheck/
    ## vpProtoGateFalseCheck string consts), and the Windows branch's two
    ## INDEPENDENT `findstr` presence checks (anchor present somewhere under
    ## `dir`, decl present somewhere under `dir`) — proving neither text is
    ## missing, but never that they're actually ADJACENT. Both were shell
    ## pipelines/redirects (`exec cmd & " 2>&1 | ..."`-shaped or raw
    ## `grep -rFA5 ... | grep -Fq ...`), the same portability hazard this
    ## whole file's diagnostic checks were migrated away from, and both were
    ## strictly WEAKER than (or, for the grep pipeline, functionally
    ## identical to) this Nim-side check — so rather than port them to yet
    ## another shell-free wrapper, they were deleted outright and this is now
    ## the SOLE adjacency proof, called ONCE (not per-OS-branch) since it's
    ## already fully portable: readFile + a line-window scan, over the same
    ## recursive `walkGenSources` walk `expectAnchor` above already uses.
    ##
    ## Deliberately NOT `readFile(f).splitLines()` + per-line scanning: this
    ## runs against `protoEmitDir`, populated by compiling the ENTIRE
    ## tests/test_softlink.nim (its generated .c can reach several
    ## megabytes) — empirically, `splitLines` over a file that size blows
    ## NimScript's VM iteration budget ("interpretation requires too many
    ## iterations; ... compile with `--maxLoopIterationsVM`"). Plain
    ## `string.find` (locate `anchor`, then a bounded walk counting up to
    ## `windowLines` newlines, then `find` again for `decl` within that byte
    ## range) touches the same text without materializing a full line seq,
    ## and stays well under the VM budget.
    ##
    ## Finding R2-6: when fewer than `windowLines` newlines remain after
    ## `anchor` (anchor near EOF, or the file has no trailing newline), the
    ## inner loop used to `break` with `pos` still sitting at the last
    ## newline it DID find, so `windowEnd` silently TRUNCATED the window
    ## instead of extending it to EOF — a `decl` that appears after that
    ## last newline but before EOF could never be found, a false FAILURE
    ## (fail-safe direction, but still wrong). Snapping `pos` to `text.len`
    ## when the newline search runs dry makes the window extend all the way
    ## to EOF instead, matching grep -A's own end-of-file behavior.
    const windowLines = 5
    for f in walkGenSources(dir):
      let text = readFile(f)
      var searchFrom = 0
      while true:
        let aIdx = text.find(anchor, searchFrom)
        if aIdx < 0: break
        var pos = aIdx
        var nlCount = 0
        while nlCount < windowLines:
          let nlIdx = text.find('\n', pos)
          if nlIdx < 0:
            pos = text.len
            break
          pos = nlIdx + 1
          inc nlCount
        let windowEnd = min(text.len, pos)
        let dIdx = text.find(decl, aIdx)
        if dIdx >= 0 and dIdx < windowEnd:
          return
        searchFrom = aIdx + 1
    quit("softlink: Finding #19.4 (" & label & "): expected '" & decl &
         "' to appear within " & $windowLines & " lines after a line " &
         "containing '" & anchor & "' in some generated file under " &
         dir & ", but no such adjacent pair was found")

  proc runAdjacentPairEofRegressionCheck() =
    ## Finding R2-6 regression test: synthesizes a tiny fixture "generated
    ## source" file whose `anchor` sits close enough to EOF (and with NO
    ## trailing newline) that fewer than `windowLines` newlines remain
    ## after it — exactly the shape the finding describes as "currently
    ## inert" in every REAL generated-C anchor `expectAdjacentPair` checks
    ## elsewhere in this file (all mid-file). Before the R2-6 fix, the
    ## inner loop left `pos`/`windowEnd` sitting at the last newline it did
    ## find, so `decl` sitting on the FINAL, newline-less line was outside
    ## `windowEnd` by construction — a false FAILURE. Worked by hand: the
    ## single newline between `anchor`'s line and `decl`'s line is the only
    ## one in the file, so the old code's `windowEnd` would equal `decl`'s
    ## own start offset (`dIdx < windowEnd` false, not found); the R2-6 fix
    ## snaps `pos` to `text.len` instead, so `windowEnd` covers the whole
    ## file and the match succeeds. `expectAdjacentPair` reports failure by
    ## calling `quit` itself, so simply calling it here and returning
    ## normally IS the regression proof — no separate assertion needed.
    const dir = "tests/nimcache_adjacentpair_eof_regression"
    if dirExists(dir): rmDir(dir)
    mkDir(dir)
    let anchor = "REGRESSION_ANCHOR_R2_6"
    let decl = "REGRESSION_DECL_R2_6"
    # No trailing newline after `decl` -- the exact "anchor near EOF, file
    # doesn't end with a newline" shape R2-6 names.
    writeFile(dir & "/synthetic.c",
      "line0\nline1\nline2\n" & anchor & "\n" & decl)
    expectAdjacentPair(dir, anchor, decl,
      "R2-6 regression: decl on the final, newline-less line after anchor")
    rmDir(dir)

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
    # comment in src/softlink/verify.nim) — a list element padded with a leading
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

    # Code-review finding F9 (Medium): a -d:softlinkProbeOnly name matching
    # NO proc in this block must emit a compile-time WARNING (never a
    # silent total suppression with no signal anything is wrong) — see
    # genVerifyBlock's own doc comment in src/softlink/verify.nim for why this is
    # a warning rather than a hard error (the define is GLOBAL to the whole
    # compilation; a module may legitimately contain multiple dynlib/
    # verifyProcs blocks, and a name targeting a DIFFERENT block correctly
    # suppresses everything in THIS one).
    expectManifestCompileOk(
      cBaseNoCache & " -d:softlinkProbeOnly=testlib_totally_bogus_name tests/tcheck_probe_only.nim",
      ["no proc in this 'Probeonly' block"], [])

    # Control: a name that DOES match a proc in this block (the same
    # `testlib_add` M2 above already proves suppresses correctly) must NOT
    # trigger the new warning — proves no false positive on the ordinary case.
    expectManifestCompileOk(
      cBaseNoCache & " -d:softlinkProbeOnly=testlib_add tests/tcheck_probe_only.nim",
      [], ["no proc in this"])

    # Existence mode gets the identical warning, not a harder error, when
    # its singleton target doesn't match this block — the same legitimate
    # multi-block reasoning applies to existence mode's target.
    expectManifestCompileOk(
      cBaseNoCache & " -d:softlinkProbeOnly=testlib_totally_bogus_name -d:softlinkProbeExistence " &
        "tests/tcheck_probe_only.nim",
      ["no proc in this 'Probeonly' block"], [])

    # Code-review finding R2-3 (Medium): the F9 warning above was built from
    # `allProcs` (INCLUDING `{.noverify.}` procs), not the verification-
    # eligible `procs` subset — so a `-d:softlinkProbeOnly` name matching
    # ONLY a `{.noverify.}` proc's cname never triggered the warning, even
    # though every genuinely-verifiable proc in the block was still being
    # silently, totally suppressed. `tests/tcheck_probe_only_noverify_target.nim`
    # declares `testlib_add` (header-verified) alongside
    # `testlib_noverify_target` ({.noverify.}); probing ONLY the noverify
    # proc's name must still fire the warning.
    expectManifestCompileOk(
      cBaseNoCache & " -d:softlinkProbeOnly=testlib_noverify_target " &
        "tests/tcheck_probe_only_noverify_target.nim",
      ["no proc in this 'Probeonly' block"], [])

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

  # RFC-0003 §4.1/§7 A1: `-d:softlinkProbeGroundTruth` (paired with
  # `-d:softlinkHarvestSession`, else the misuse guard fires — see
  # `gtNoSessionCheck` below) defeats every `{.verifyWhen.}` gate and
  # vendored `{.prototype.}` declaration a probe compile carries, and skips
  # the `versionMacros` visibility guard. Reuses the SAME
  # `tests/tcheck_probe_only.nim`/`tests/tverify_synthesized_gate.nim`
  # fixtures `runProbeOnlyChecks`/RFC-0002's own E2 checks already proved
  # correct WITHOUT ground truth — recompiled here WITH it, so the only
  # variable under test is ground truth's defeat/skip/suppression, not a
  # new fixture shape.
  const gtDirGate = "tests/nimcache_gt_gate"
  const gtDirProto = "tests/nimcache_gt_proto"
  const gtDirGuard = "tests/nimcache_gt_guard"
  const gtDirFastPath = "tests/nimcache_gt_fastpath"
  const gtDirInert = "tests/nimcache_gt_inert"
  const gtDirs = [gtDirGate, gtDirProto, gtDirGuard, gtDirFastPath, gtDirInert]
  const gtNoSessionCheck =
    "nim c --path:src --passC:-I. -d:softlinkProbeGroundTruth " &
    "tests/tfail_groundtruth_no_session.nim"
  const gtNoSessionAnchor = "requires -d:softlinkHarvestSession"

  proc runGroundTruthChecks() =
    for d in gtDirs:
      if dirExists(d): rmDir(d)
    let cBase = "nim c --compileOnly --path:src --passC:-I. --nimcache:"
    const gtDefines = " -d:softlinkProbeGroundTruth -d:softlinkHarvestSession "

    # (1) A hand-written {.verifyWhen.} gate is DEFEATED: testlib_gated's
    # own gate text is absent (the assert becomes unconditional) —
    # `effectiveVerifyWhen` (RFC-0003 §4.1). `poAssertGated`/`testlib_gated`
    # is genuinely correctly-typed against tests/testlib.h at
    # TESTLIB_VERSION=1, so the now-unconditional assert still compiles.
    exec cBase & gtDirGate & gtDefines &
      "-d:softlinkProbeOnly=testlib_gated tests/tcheck_probe_only.nim"
    expectAnchor(gtDirGate, poAssertGated,
      "ground truth: testlib_gated assert present (now unconditional)", true)
    expectAnchor(gtDirGate, "#if (TESTLIB_VERSION >= 1) /* softlink verifyWhen */",
      "ground truth: testlib_gated's own verifyWhen gate text defeated", false)

    # (2) RFC-0003 §5.2(iv): the probed symbol's OWN vendored
    # {.prototype.} decl is suppressed in the VERIFY sub-mode under ground
    # truth — extending the pre-existing existence-mode-only suppression
    # (`isProbedExistence`) to `isProbedTarget`. testlib_add is
    # header+prototype, no gate; `poProtoDeclAdd` was PRESENT under the
    # IDENTICAL non-ground-truth M2 probe above (`runProbeOnlyChecks`) —
    # now absent, while the assert (checked against the header alone)
    # still fires.
    exec cBase & gtDirProto & gtDefines &
      "-d:softlinkProbeOnly=testlib_add tests/tcheck_probe_only.nim"
    expectAnchor(gtDirProto, poAssertAdd, "ground truth: testlib_add assert present", true)
    expectAnchor(gtDirProto, poProtoDeclAdd,
      "ground truth: testlib_add's own vendored prototype decl suppressed in verify probe", false)

    # (3) RFC-0002 §4.5's versionMacros visibility guard is skipped
    # entirely under ground truth (a probe TU evaluates no gate, so an
    # undefined macro can't corrupt classification there — RFC-0003 §4.1).
    exec cBase & gtDirGuard & gtDefines & "tests/tverify_synthesized_gate.nim"
    expectAnchor(gtDirGuard, "#ifndef TESTLIB_VERSION",
      "ground truth: versionMacros visibility guard skipped", false)

    # (4) Fast-path legality control: `softlinkProbeGroundTruth` +
    # `softlinkHarvestSession` with NO `softlinkProbeOnly` at all (the
    # whole-module compile RFC-0003 §4.3 describes) must compile clean,
    # not trip the misuse guard — `softlinkProbeOnly`'s absence is NOT the
    # misuse signal, `softlinkHarvestSession`'s absence is.
    exec cBase & gtDirFastPath & gtDefines & "tests/tcheck_probe_only.nim"

    # (5) `softlinkHarvestSession` ALONE (`softlinkProbeGroundTruth` false)
    # is legal AND inert (doc comment on the const, RFC-0003 §4.1's truth
    # table): testlib_gated's gate text must still be PRESENT — identical
    # to the M0 control's byte shape — proving this define alone changes
    # no emission.
    exec cBase & gtDirInert &
      " -d:softlinkHarvestSession -d:softlinkProbeOnly=testlib_gated tests/tcheck_probe_only.nim"
    expectAnchor(gtDirInert, "#if (TESTLIB_VERSION >= 1) /* softlink verifyWhen */",
      "softlinkHarvestSession alone: testlib_gated's gate text is untouched (inert)", true)

    for d in gtDirs:
      if dirExists(d): rmDir(d)

    # RFC-0003 §4.1 misuse rule: `softlinkProbeGroundTruth` without
    # `softlinkHarvestSession` is a loud macro error, never a silent probe.
    expectDiag(gtNoSessionCheck, "groundTruth without harvestSession", gtNoSessionAnchor)

  # RFC-0002 §6, slice C3a: the dual-header compile test —
  # tests/tverify_gated_drift.nim compiled TWICE, once against each of
  # tests/testlib.h's two `#if TESTLIB_VERSION >= 2` branches for
  # `testlib_drifted`. Distinct --nimcache dirs per invocation, same
  # isolation precedent as `probeOnlyDirs` above: a `-D` flag changes no
  # Nim-emitted C, so a shared nimcache risks Nim's content-hashed cache
  # reusing the first invocation's object file and the second invocation
  # "passing" without recompiling anything under the new header shape at
  # all. Both invocations are REAL compiles (no --compileOnly, unlike
  # `runProbeOnlyChecks` above) — the point is that gcc's own
  # `_Static_assert`/call-based checking actually runs against each
  # branch's real declaration; see the fixture's own doc comment for the
  # hand-verified RED evidence (a deliberately wrong signature under a
  # true gate fails the C compile) this shape is built to catch.
  const gatedDriftDir1 = "tests/nimcache_gated_drift_v1"
  const gatedDriftDir2 = "tests/nimcache_gated_drift_v2"
  const gatedDriftExe = "tests/tverify_gated_drift"

  proc runGatedDriftChecks() =
    # Default (TESTLIB_VERSION=1, testlib.h's own `#ifndef` default): the
    # fixture's first `verifyProcs` block (`TESTLIB_VERSION < 2`) is TRUE
    # and genuinely type-checks against the header's `int *`-param
    # declaration; the second block's gate is FALSE, its declaration
    # absent from this build. `--passC:-DTESTLIB_VERSION=2` (the second
    # invocation's `extraFlag2`) is the reverse — the second block's gate
    # opens against the header's now-`double *`-param declaration; the
    # first block's gate closes.
    runDualNimcacheCompile(gatedDriftDir1, gatedDriftDir2,
      " --path:src --passC:-I. ", "--passC:-DTESTLIB_VERSION=2 ",
      "tests/tverify_gated_drift.nim", gatedDriftExe)

  # RFC-0002 §5/§6, slice E2: the SYNTHESIZED-gate sibling of
  # `runGatedDriftChecks` above — same dual-compile, distinct-nimcache
  # isolation, but `tests/tverify_synthesized_gate.nim`'s gate is never
  # hand-written: `versionMacros("TESTLIB_VERSION")` + `{.until: "2".}`
  # synthesizes it. Proves a SYNTHESIZED gate opens (TESTLIB_VERSION=1: the
  # real `int *`-param declaration genuinely type-checks) and closes
  # (TESTLIB_VERSION=2: the declaration is absent, compiles clean, nothing
  # checked) against real headers — see the fixture's own doc comment for
  # the hand-verified RED evidence (a deliberately wrong `ptr cdouble`
  # under the TESTLIB_VERSION=1 true-gate branch fails the real gcc compile
  # with "incompatible pointer type", proving the synthesized gate's TRUE
  # branch checks real, present content, not merely compiles vacuously).
  const synthGateDir1 = "tests/nimcache_synth_gate_v1"
  const synthGateDir2 = "tests/nimcache_synth_gate_v2"
  const synthGateExe = "tests/tverify_synthesized_gate"

  proc runVersionMacrosGateChecks() =
    runDualNimcacheCompile(synthGateDir1, synthGateDir2,
      " --path:src --passC:-I. ", "--passC:-DTESTLIB_VERSION=2 ",
      "tests/tverify_synthesized_gate.nim", synthGateExe)

    # Code-review finding CR1-12 control: a versionMacros directive that IS
    # consumed by a synthesized gate must NOT trigger the "declared but
    # never used" hint — proves `checkVersionMacrosConsumed`'s detection
    # (via `p.synthesizedGateMacros`) correctly distinguishes "used" from
    # "unused" rather than firing unconditionally whenever the directive is
    # merely present. See tests/thint_versionmacros_unused.nim for the
    # positive (actually-unused) case this is the negative mirror of.
    const synthGateUnusedCheckDir = "tests/nimcache_synth_gate_unused_check"
    if dirExists(synthGateUnusedCheckDir): rmDir(synthGateUnusedCheckDir)
    expectManifestCompileOk("nim c --compileOnly --nimcache:" &
      synthGateUnusedCheckDir & " --path:src --passC:-I. " &
      "tests/tverify_synthesized_gate.nim", [], ["declared but never used"])
    if dirExists(synthGateUnusedCheckDir): rmDir(synthGateUnusedCheckDir)

    # RFC-0002 §4.5/§5/§6, slice E2: the negative guard check — a
    # `versionMacros` name NOT defined by any header this block includes
    # must fail the verify TU's REAL C compile with the `#ifndef`/`#error`
    # guard's exact wording (`softlink/verify.emitVersionMacroGuards`).
    # Deliberately NOT run through `--compileOnly` (unlike every
    # `mcBase`-driven check in `runManifestChecks` below): `--compileOnly`
    # only emits Nim's generated C and never invokes the C compiler at all,
    # so it could never observe a C-level `#error` — only a real `nim c`
    # actually runs gcc/clang against the generated TU. `expectDiag` is
    # exit-code-agnostic (it only asserts the needle appears in output),
    # which is fine here since the compile genuinely fails either way.
    const undefinedMacroDir = "tests/nimcache_versionmacros_undefined"
    if dirExists(undefinedMacroDir): rmDir(undefinedMacroDir)
    expectDiag("nim c --nimcache:" & undefinedMacroDir &
      " --path:src --passC:-I. tests/tfail_versionmacros_undefined_macro.nim",
      "versionMacros undefined-macro guard fires a real C #error",
      "versionMacros identifier 'TESTLIB_NO_SUCH_MACRO' is not defined by " &
      "this block's included headers")
    if dirExists(undefinedMacroDir): rmDir(undefinedMacroDir)

    # Code review CR1-8, cell 3: the C++ backend leg of the SAME guard.
    # `emitVersionMacroGuards` emits the `#ifndef`/`#error` text
    # unconditionally into the verify TU's shared include prologue — not
    # gated on which backend tier (C++ `decltype`+`is_same`, GCC/Clang
    # `__builtin_types_compatible_p`, MSVC `_Generic`) ends up checking the
    # signature itself — but until now only the `nim c` (GCC) leg above
    # ever compiled this fixture for real, so the guard's behavior under
    # the C++ backend/compiler (g++, not gcc) had no real-compiler
    # coverage at all. Own `--nimcache` dir, matching every other
    # dual-backend pattern in this file (e.g. `runGatedDriftChecks`'s own
    # C/C++ pair) — a shared nimcache across two different backends risks
    # a stale/vacuous pass exactly as those functions' own doc comments
    # warn.
    const undefinedMacroCppDir = "tests/nimcache_versionmacros_undefined_cpp"
    if dirExists(undefinedMacroCppDir): rmDir(undefinedMacroCppDir)
    expectDiag("nim cpp --nimcache:" & undefinedMacroCppDir &
      " --path:src --passC:-I. tests/tfail_versionmacros_undefined_macro.nim",
      "versionMacros undefined-macro guard fires a real C++ #error too",
      "versionMacros identifier 'TESTLIB_NO_SUCH_MACRO' is not defined by " &
      "this block's included headers")
    if dirExists(undefinedMacroCppDir): rmDir(undefinedMacroCppDir)

    # RFC-0002 §5/§6 Z3 extension: `versionMacros(..., header = "...")` —
    # the Z3 case itself. `tests/testlib_bare.h` (this fixture's proc
    # header) deliberately does NOT define or include TESTLIB_VERSION,
    # mirroring z3.h not including z3_version.h; `tests/
    # testlib_gates_version.h` (the named header) defines it independently.
    # Same dual-compile, distinct-nimcache-per-invocation proof as
    # `tests/tverify_synthesized_gate.nim` above: the synthesized gate
    # opens (TESTLIB_VERSION=1: the real `int *`-param declaration
    # genuinely type-checks — hand-verified RED evidence: temporarily
    # widening the fixture's param to `ptr cdouble` fails this exact
    # invocation with a real "expected 'int *' but argument is of type
    # 'double *'" gcc error) and closes (TESTLIB_VERSION=2: the declaration
    # is absent, compiles clean) against real headers — but ONLY because
    # `header = "tests/testlib_gates_version.h"` puts TESTLIB_VERSION in
    # scope at all; see `tests/tfail_versionmacros_header_missing.nim`
    # immediately below for the control proving that without it, the same
    # shape fails the `#ifndef`/`#error` visibility guard instead.
    const synthGateHeaderDir1 = "tests/nimcache_synth_gate_header_v1"
    const synthGateHeaderDir2 = "tests/nimcache_synth_gate_header_v2"
    const synthGateHeaderExe = "tests/tverify_synthesized_gate_header"
    runDualNimcacheCompile(synthGateHeaderDir1, synthGateHeaderDir2,
      " --path:src --passC:-I. ", "--passC:-DTESTLIB_VERSION=2 ",
      "tests/tverify_synthesized_gate_header.nim", synthGateHeaderExe)

    # The negative control: same proc/header shape, no `header =` at all —
    # tests/testlib_bare.h alone never puts TESTLIB_VERSION in scope, so
    # the `#ifndef`/`#error` guard must fire for real, exactly like
    # `tests/tfail_versionmacros_undefined_macro.nim` above (real C
    # `#error`, not a Nim macro-time error, hence no `--compileOnly`).
    const headerMissingDir = "tests/nimcache_versionmacros_header_missing"
    if dirExists(headerMissingDir): rmDir(headerMissingDir)
    expectDiag("nim c --nimcache:" & headerMissingDir &
      " --path:src --passC:-I. tests/tfail_versionmacros_header_missing.nim",
      "versionMacros(header=) negative control: guard fires without it",
      "versionMacros identifier 'TESTLIB_VERSION' is not defined by this " &
      "block's included headers")
    if dirExists(headerMissingDir): rmDir(headerMissingDir)

    # The angle-bracket form: `header = "<...>"` must emit `#include <...>`,
    # not `#include "..."` — proven by inspecting the generated C directly
    # (`expectInGenC`, the same technique the {.prototype.} A2/A6/A8 checks
    # below use), rather than a real compile: `--compileOnly` never invokes
    # the C compiler, so the angle-bracket path need not actually resolve
    # via `-I` for this assertion (the quoted-vs-angle #include TEXT is all
    # that's under test here; real resolution is already exercised by every
    # OTHER `-passC:-I.`-driven check in this file, which happens to use
    # the quoted form throughout).
    const headerAngleDir = "tests/nimcache_versionmacros_header_angle"
    if dirExists(headerAngleDir): rmDir(headerAngleDir)
    exec "nim c --compileOnly --nimcache:" & headerAngleDir &
      " --path:src tests/tcheck_versionmacros_header_angle.nim"
    expectInGenC(headerAngleDir, "#include <tests/testlib_gates_version.h>",
      "versionMacros(header = \"<...>\") emits an angle-bracket #include")
    rmDir(headerAngleDir)

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
    "testlib_vp_since", "testlib_abi_mismatch", "testlib_until",
    "testlib_until_unknown", "testlib_until_unknown_stamped",
    "testlib_until_covered"]

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

    # RFC-0002 §4.2/§6, slice B2: `checkUntil` wired into the same call site
    # as `checkSince` above (`softlink/directives.applyCompatManifest`'s
    # Check 6) — the dangerous over-claim direction (rule (a)): a declared
    # `until` later than the corpus's own recorded drift.
    expectManifestCompileFail(mcBase & "tests/tfail_manifest_until_contradiction.nim",
      ["corrected upper bound is until: \"2.0.0\""])

    # Finding R2-A: `checkUntil` rule (b)'s at-or-above-`until` scan now also
    # contradicts on a non-decisive (`fkUnknown`) corpus fact, not just a
    # re-verified one — see `src/softlink/manifest.nim`'s `checkUntil` doc
    # comment and this fixture's own header comment.
    #
    # RFC-0003 §2/§7 slice C1: this fixture's manifest carries NO
    # `harvesterVersion` (every tmpl.json committed before this field
    # existed lacks it, by construction) — a REAL, pre-existing "stale
    # manifest" shape, not a synthetic one built for this slice. Its
    # contradiction path is therefore also this project's end-to-end,
    # macro-expansion-level proof that the §2 breadcrumb actually reaches a
    # real `error()` call (`softlink/directives.applyCompatManifest`'s
    # Check 6b, which forwards `checkUntil`'s message VERBATIM — no
    # directives.nim code change was needed for this to work). The
    # `testlib_until_unknown_stamped` control immediately below proves the
    # mirror: the IDENTICAL contradiction, with `harvesterVersion` present,
    # carries NO breadcrumb — absence of the field is the sole trigger.
    expectManifestCompileFail(mcBase & "tests/tfail_manifest_until_unknown.nim",
      ["no decisive classification",
       "NOTE: this manifest predates softlink's ground-truth harvest fix"])

    expectManifestCompileFail(
      mcBase & "tests/tfail_manifest_until_unknown_stamped.nim",
      ["no decisive classification"],
      ["predates softlink's ground-truth harvest fix"])

    expectManifestCompileFail(mcBase & "tests/tfail_since_unparseable.nim",
      ["does not parse as a version"])

    expectManifestCompileFail(mcBase & "tests/tfail_until_unparseable.nim",
      ["does not parse as a version"])

    expectManifestCompileFail(mcBase & "tests/tfail_since_until_empty_interval.nim",
      ["is an empty interval"])

    # RFC-0002 §4.1/§6, slice A3: `until` requires corpus-trackability —
    # rejected alongside `noverify` (nothing to falsify the bound against)
    # and alongside a prototype-only proc with no `header` (a vendored
    # prototype verifies against a corpus-invariant declaration with no
    # per-version facts to harvest). `prototype` + `header` TOGETHER stays
    # accepted (cross-check mode) — positive control below.
    expectManifestCompileFail(mcBase & "tests/tfail_until_noverify.nim",
      ["{.until.} contradicts {.noverify.}"])

    expectManifestCompileFail(mcBase & "tests/tfail_until_prototype_only.nim",
      ["not corpus-trackable"])

    # RFC-0002 §4.1/§5/§6, slice D1: `until` requires `verifyWhen` —
    # unconditional, post-body-scan, no `compatManifest` involved at all
    # (mcBase's `--passC:-I.` is needed only because the fixture's proc
    # carries a real `{.header.}`).
    expectManifestCompileFail(mcBase & "tests/tfail_until_without_gate.nim",
      ["requires a {.verifyWhen.} gate"])

    expectManifestCompileOk(mcBase & "tests/tcheck_until_verifywhen_ok.nim", [], [])

    # RFC-0002 §5/§6, slice E1: `versionMacros(...)` directive parse +
    # validation — mirrors the `compatManifest`/`versionProbe` dup-guard and
    # malformed-shape checks above/below. Parsed and stored only in this
    # slice (no synthesis consumer yet — that's Stage E2).
    expectManifestCompileFail(mcBase & "tests/tfail_versionmacros_malformed.nim",
      ["is not a valid C identifier"])

    expectManifestCompileFail(mcBase & "tests/tfail_versionmacros_duplicate.nim",
      ["duplicate versionMacros directive"])

    # RFC-0002 §5/§6 Z3 extension: `versionMacros(..., header = "...")`'s
    # optional named argument — parse-level rejections only (macro-time
    # `error()`s, so `--compileOnly` is sufficient, same as the two checks
    # directly above). The feature's actual EFFECT (the named header
    # joining the verify TU's #include list, both quoted and angle-bracket)
    # is proven by `runVersionMacrosGateChecks` below — a real C compile is
    # needed there to observe the synthesized gate genuinely opening/
    # closing against the now-visible macro, which `--compileOnly` alone
    # cannot show.
    expectManifestCompileFail(mcBase & "tests/tfail_versionmacros_header_unknown_arg.nim",
      ["only supported named argument is 'header'"])

    expectManifestCompileFail(mcBase & "tests/tfail_versionmacros_header_not_string.nim",
      ["'header' argument must be a string literal"])

    expectManifestCompileFail(mcBase & "tests/tfail_versionmacros_header_empty.nim",
      ["'header' argument must be non-empty"])

    expectManifestCompileFail(mcBase & "tests/tfail_versionmacros_header_duplicate.nim",
      ["'header' argument was given more than once"])

    # RFC 0011 S0a item 1: `identBase(...)` directive parse + validation —
    # mirrors the `compatManifest`/`versionMacros` malformed-shape and
    # dup-guard checks above, plus a `verifyProcs`-rejection pin (design
    # guidance's "decide and pin behavior in verifyProcs blocks" call:
    # unrecognized there, falls into the ordinary body-shape error).
    expectManifestCompileFail(mcBase & "tests/tfail_identbase_duplicate.nim",
      ["duplicate identBase directive"])

    expectManifestCompileFail(mcBase & "tests/tfail_identbase_bad_type.nim",
      ["identBase requires exactly one string literal argument"])

    expectManifestCompileFail(mcBase & "tests/tfail_identbase_invalid_ident.nim",
      ["is not a valid Nim identifier"])

    expectManifestCompileFail(mcBase & "tests/tfail_identbase_empty.nim",
      ["identBase's argument must be non-empty"])

    expectManifestCompileFail(mcBase & "tests/tfail_identbase_verifyprocs.nim",
      ["verifyProcs body must contain only proc declarations"])

    # RFC 0011 S0a item 4: statement pass-through in `dynlib` bodies — the
    # one hard limit (a passed-through helper calling a binding declared
    # LATER in the same block is refused, same as two hand-written
    # top-level procs would be) and the `verifyProcs` asymmetry (pass-
    # through is a `dynlib`-only feature; `verifyProcs` keeps its
    # unrelaxed rule). See each fixture's own doc comment.
    expectManifestCompileFail(mcBase & "tests/tfail_passthrough_forward_ref.nim",
      ["undeclared identifier", "testlibForwardTarget"])

    expectManifestCompileFail(mcBase & "tests/tfail_passthrough_verifyprocs.nim",
      ["verifyProcs body must contain only proc declarations"])

    # RFC 0011 S0a item 6: the block-level `noverify: "reason"` directive —
    # parse/validation, duplicate-guard, and verifyProcs-rejection checks,
    # mirroring the `identBase` group directly above. The two positive
    # (position-independence) fixtures and the two contradiction-rule
    # negative fixtures below are its behavioral pins.
    expectManifestCompileFail(mcBase & "tests/tfail_noverify_block_duplicate.nim",
      ["duplicate block-level noverify directive"])

    expectManifestCompileFail(mcBase & "tests/tfail_noverify_block_bad_type.nim",
      ["block-level noverify requires exactly one string literal justification"])

    expectManifestCompileFail(mcBase & "tests/tfail_noverify_block_empty.nim",
      ["block-level noverify's justification must be non-empty"])

    expectManifestCompileFail(mcBase & "tests/tfail_noverify_block_verifyprocs.nim",
      ["verifyProcs body must contain only proc declarations"])

    # Position independence (the RFC's own red test: a block directive
    # placed AFTER the procs it defaults for must still work — the
    # must-specify-a-verification-source check defers to a post-body-scan
    # pass specifically so this compiles) plus the ordinary before-the-procs
    # case, and override/coexistence with a proc's own header/noverify.
    expectManifestCompileOk(mcBase & "tests/tcheck_noverify_block_before.nim", [], [])
    expectManifestCompileOk(mcBase & "tests/tcheck_noverify_block_after.nim", [], [])
    expectManifestCompileOk(mcBase & "tests/tcheck_noverify_block_override.nim", [], [])

    # Contradiction-rule pin: a proc carrying {.until.}/{.verifyWhen.} (no
    # header) inside a block with a block-level noverify default does NOT
    # inherit it — it keeps today's ordinary "must specify a header pragma"
    # error rather than a misattributed noverify contradiction. See
    # `applyNoVerifyDefault`'s doc comment (softlink/pragmas.nim).
    expectManifestCompileFail(mcBase & "tests/tfail_noverify_block_until_no_header.nim",
      ["must specify a header pragma"])

    expectManifestCompileFail(mcBase & "tests/tfail_noverify_block_verifywhen_no_header.nim",
      ["must specify a header pragma"])

    # RFC 0011 S0a item 3: the `symbol: "c_name"` rename pragma. The
    # positive path (a renamed proc loading/dispatching, two Nim procs
    # sharing one C symbol, `missing`/`lrSymbolNotFound.symbol` naming the
    # C symbol) is exercised end to end in test_softlink.nim's own "symbol
    # rename pragma" suite (needs a real load, so it belongs in the main
    # suite, not here); this group covers everything that's a pure
    # macro-expansion-time rejection, `--compileOnly`-checkable like every
    # other `mcBase` fixture in this proc.
    #
    # `importc`, bare and valued: softlink is not the FFI importer — the
    # rename axis is spelled `symbol:`, never `importc` (which would be a
    # false friend, borrowing a real Nim compiler pragma's name for an
    # unrelated axis). Both spellings fall through to the ordinary
    # unrecognized-pragma error, no special case.
    expectManifestCompileFail(mcBase & "tests/tfail_importc_bare.nim",
      ["dynlib does not support pragma 'importc'"])

    expectManifestCompileFail(mcBase & "tests/tfail_importc_valued.nim",
      ["dynlib does not support pragma 'importc'"])

    # `symbol:` argument validation — non-empty string literal, syntactically
    # valid C identifier.
    expectManifestCompileFail(mcBase & "tests/tfail_symbol_bad_type.nim",
      ["symbol pragma requires a non-empty C identifier string literal"])

    expectManifestCompileFail(mcBase & "tests/tfail_symbol_empty.nim",
      ["symbol pragma requires a non-empty C identifier string literal"])

    expectManifestCompileFail(mcBase & "tests/tfail_symbol_invalid_ident.nim",
      ["is not a valid C identifier"])

    # The `{.prototype.}` name-match rule keys on the EFFECTIVE C name
    # (`symbol:`'s value), not the Nim identifier — a prototype naming the
    # Nim alias instead of the real C symbol must fail its name-match
    # exactly like naming any other wrong C symbol would.
    expectManifestCompileFail(mcBase & "tests/tfail_symbol_prototype_name_mismatch.nim",
      ["does not match the proc's C name 'testlib_add'"])

    # Manifest/`checkSince`/`checkUntil` lookup keys on the C symbol, not
    # the Nim name, for a renamed proc — both directions (a genuine
    # contradiction fires; a satisfied claim is found, not reported "not in
    # compat manifest").
    expectManifestCompileFail(
      mcBase & "tests/tfail_manifest_symbol_rename_since_contradiction.nim",
      ["corrected lower bound is 2.0.0", "testlib_add"])

    expectManifestCompileFail(
      mcBase & "tests/tfail_manifest_symbol_rename_until_contradiction.nim",
      ["corrected upper bound is until: \"2.0.0\""])

    expectManifestCompileOk(
      mcBase & "tests/tcheck_manifest_symbol_rename_found.nim", [],
      ["not in compat manifest"])

    # RFC-0002 §5/§6, slice E2: gate-synthesis bound validation — both are
    # NIM macro-time errors (`error()`-raised inside `synthesizeVersionGates`
    # itself, from a `softlink/gates.GateResult` failure case), so
    # `--compileOnly` (never invoking the C compiler) is sufficient to catch
    # them, same as every other `mcBase` check in this proc. Contrast the
    # undefined-macro guard (`runVersionMacrosGateChecks`, above `task test`)
    # — a genuine C-level `#error`, which needs a real compile.
    expectManifestCompileFail(mcBase & "tests/tfail_versionmacros_alpha_bound.nim",
      ["the bound contains a non-numeric (alphabetic) run"])

    expectManifestCompileFail(mcBase & "tests/tfail_versionmacros_excess_components.nim",
      ["there is no C macro for the extra component(s)"])

    expectManifestCompileOk(mcBase & "tests/tcheck_manifest_mismatch_warning.nim",
      ["recorded a 'mismatch' interval"], [])

    # Check 7 bound-covered mismatch fix (nim-z3 report softlink-mismatch-
    # warning-issue.md; CHECK7-WARNING.handoff.md): a mismatch fully
    # explained by a declared, checkUntil-validated `{.until.}` bound must
    # downgrade to a HINT ("bound-covered mismatch"), NOT the unbounded-
    # drift warning above — `tests/manifests/testlib_until_covered.
    # compat.json` records `testlib_add` as verified below / mismatch at-
    # or-above its declared `until: "2.0.0"`.
    expectManifestCompileOk(mcBase & "tests/tcheck_manifest_mismatch_covered.nim",
      ["bound-covered mismatch"], ["recorded a 'mismatch' interval"])
    expectDiag(mcBase & "tests/tcheck_manifest_mismatch_covered.nim",
      "bound-covered mismatch hint (default)", "bound-covered mismatch", "Hint:")
    # Same strict-audit escalation convention Check 8's not-in-manifest
    # hint already uses (`-d:softlinkStrictVerify` above).
    expectDiag(mcBase & "-d:softlinkStrictVerify tests/tcheck_manifest_mismatch_covered.nim",
      "bound-covered mismatch warning (strict)", "bound-covered mismatch", "Warning:")

    # Partition proof: one covered (`testlib_add`, until-bounded) and one
    # uncovered (`testlib_noop`, unbounded) mismatched symbol in the SAME
    # directive — the warning must name only the uncovered symbol, the
    # hint only the covered one.
    expectManifestCompileOk(mcBase & "tests/tcheck_manifest_mismatch_mixed.nim",
      ["recorded a 'mismatch' interval: testlib_noop",
       "bound-covered mismatch", "testlib_add"], [])
    # Line-scoped partition proof: each diagnostic is one compiler output
    # line (softlink's `warning`/`hint` calls never embed a literal
    # newline in these messages) — split the captured output on newlines
    # and, per needle, isolate the ONE line containing it, then assert the
    # OTHER symbol's name is absent from that specific line. This is
    # strictly stronger than `expectManifestCompileOk`'s whole-output
    # `mustContain`/`mustNotContain` (which can't distinguish "present
    # somewhere" from "present in the wrong diagnostic").
    let mixedOutput = runCapture(mcBase & "tests/tcheck_manifest_mismatch_mixed.nim")
    var warningLine, hintLine = ""
    for ln in mixedOutput.splitLines():
      if "recorded a 'mismatch' interval" in ln: warningLine = ln
      if "bound-covered mismatch" in ln: hintLine = ln
    if warningLine.len == 0 or hintLine.len == 0:
      echo mixedOutput
      quit("softlink: partition proof: expected both a warning line and a " &
           "hint line in tcheck_manifest_mismatch_mixed.nim's output")
    if "testlib_add" in warningLine:
      echo mixedOutput
      quit("softlink: partition proof: the WARNING line named the covered " &
           "symbol 'testlib_add' — it must name only the uncovered one")
    if "testlib_noop" in hintLine:
      echo mixedOutput
      quit("softlink: partition proof: the HINT line named the uncovered " &
           "symbol 'testlib_noop' — it must name only the covered one")

    # RFC-0001 §9/§C.1/§C.4b: the version-probe static drift-call scan —
    # a probe directly calling a wrapper whose symbol carries any
    # `mismatch` interval in the attached manifest is a macro error
    # ("testlib_noop" is recorded `mismatch` across the whole corpus, same
    # fixture the mismatch-warning check directly above uses); a probe
    # calling a wrapper with NO mismatch interval (`testlib_add`, recorded
    # `verified`) compiles fine.
    expectManifestCompileFail(mcBase & "tests/tfail_probe_drift_call.nim",
      ["the version probe may only call symbols with no known drift ranges",
       # #10 (Option A): the diagnostic must explain that this check is NOT
       # lifted by the runtime-refusal escape hatches, and why.
       "deliberately NOT suppressed by refuse = false or -d:softlinkNoDriftRefusal"])

    # Code-review finding F3: the UFCS/dot-call form of the same direct-call
    # scan (`x.testlib_add(2)`, callee `DotExpr(x, testlib_add)`) must be
    # caught identically — a separate, dedicated manifest
    # (`testlib_probe_drift_ufcs`, marking the two-parameter `testlib_add`
    # itself as `mismatch`) keeps this fixture independent of the shared
    # `testlib.compat.json` used by the bare-ident check directly above and
    # by several unrelated fixtures.
    const ufcsBase = "testlib_probe_drift_ufcs"
    writeManifestFromTemplate(mdir & ufcsBase & ".tmpl.json", mdir & ufcsBase & ".compat.json")
    expectManifestCompileFail(mcBase & "tests/tfail_probe_drift_call_ufcs.nim",
      ["the version probe may only call symbols with no known drift ranges"])

    # Code-review finding R2-1: a PARENTHESIZED callee (`(testlib_add)(1, 2)`,
    # AST `Call(Par(Ident "testlib_add"), ...)`) must be caught identically —
    # `stmts[0]` is `nnkPar`, not a bare `nnkIdent` nor `nnkDotExpr`, so the
    # pre-fix unwrap/`calleeIdentName` returned "" for it and this bypassed
    # the scan entirely. Reuses the SAME materialized
    # `testlib_probe_drift_ufcs.compat.json` the UFCS check directly above
    # already set up (it records the two-parameter `testlib_add` as
    # `mismatch`, exactly what this fixture's paren-wrapped call needs).
    expectManifestCompileFail(mcBase & "tests/tfail_probe_drift_call_paren.nim",
      ["the version probe may only call symbols with no known drift ranges"])
    rmFile(mdir & ufcsBase & ".compat.json")

    expectManifestCompileOk(mcBase & "tests/tcheck_versionprobe_drift_free.nim", [], [])

    expectManifestCompileOk(mcBase & "tests/tcheck_manifest_not_in_manifest_hint.nim",
      ["not in compat manifest"], [])

    # RFC-0002 §4.4, code-review finding CR1-1: Check 8's not-in-manifest
    # hint now gets the same Hint/Warning strict-mode escalation the
    # `{.noverify.}`/drifted-but-required hints already have — reuses the
    # SAME fixture directly above (its manifest is already materialized by
    # this proc's own `writeManifestFromTemplate` loop).
    expectDiag(mcBase & "tests/tcheck_manifest_not_in_manifest_hint.nim",
      "not-in-manifest hint", "not in compat manifest", "Hint:")
    expectDiag(mcBase & "-d:softlinkStrictVerify tests/tcheck_manifest_not_in_manifest_hint.nim",
      "not-in-manifest warning (strict)", "not in compat manifest", "Warning:")

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

    # Finding #19.3 (code-review coverage gap): pin the exact wording of the
    # reentrancy guard's raised message (see
    # tests/tcheck_versionprobe_reentrancy_wording.nim's doc comment for why
    # a macro-expansion inspection, not a runtime getCurrentExceptionMsg
    # test, is the only way to observe this text — the raise is always
    # caught internally by the probe's own try/except).
    expectManifestCompileOk(
      "nim c --compileOnly --path:src --expandMacro:dynlib " &
        "tests/tcheck_versionprobe_reentrancy_wording.nim",
      ["loadFoo called reentrantly from its own versionProbe",
       "unloadFoo called reentrantly from its own versionProbe"], [])

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
  # so (unlike the two `expectCompileFailure` checks directly above, which
  # assert on exit code alone) this pair needs an `expectDiag` needle check
  # to pin the exact wording, same as every other softlink-diagnostic check
  # in this file.
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

  # Finding R2-6 regression check (see `runAdjacentPairEofRegressionCheck`'s
  # own doc comment) — pure Nim-side, no compiler invoked, so it runs once,
  # unconditionally, like `expectWrapperBeforeLoad` immediately above.
  runAdjacentPairEofRegressionCheck()

  # Findings R2-5 and #24(b)/(c)/(d) (code-review round 2): four standalone
  # `std/unittest` fixtures, none needing a built testlib/libmagic/libvern
  # (they only import `softlink/manifest` or `tools/harvest/harvest_cli`
  # directly), so — like `tests/tharvest_cli.nim` — they run once,
  # unconditionally, identically on every OS leg rather than being
  # duplicated into all three `when`/`elif`/`else` branches below.
  exec "nim c -r --path:src tests/tcov_manifest_bytecap.nim"
  exec "nim c -r --path:src tests/tcov_manifest_shape_guards.nim"
  exec "nim c -r --path:src tests/tcov_classify_absence_multi_pair.nim"
  exec "nim c -r --path:src tests/tcov_harvest_cli_help_ordering.nim"

  # Portable-diagnostics migration (Windows CI fix): every check below this
  # point through `runVersionProbeChecks()` used to be TRIPLED, once per
  # `when defined(windows)`/`elif defined(macosx)`/`else` branch, purely so
  # each OS leg could spell "does the compiler's output contain this
  # substring" its own way — `2>&1 | grep -Fq '...'` on POSIX,
  # `2>&1 | findstr /C:"..." >NUL` on Windows. That divergence is exactly
  # what broke Windows CI: `nimble`'s `exec` (gorgeEx-based) does not
  # shell-interpret redirects/pipes, so `nim` itself received `2>&1`, `|`,
  # `findstr`... as argv and rejected them ("arguments can only be given if
  # the '--run' option is selected"). `expectDiag`/`expectInGenC`/
  # `expectAdjacentPair` (the first two file-scope, defined near
  # `expectCompileFailure` above; the third nested just above, right after
  # `expectAnchor`) make the assertion itself OS-agnostic — plain Nim string
  # search over `gorgeEx`-captured output or over `readFile`d generated C —
  # so every one of these checks, all of them compile-only with no library
  # load and no PATH/LD_LIBRARY_PATH/DYLD_LIBRARY_PATH dependency, now runs
  # ONCE, shared, regardless of which OS `nimble test` happens to run on.
  # Only the library BUILD commands and the runtime `nim c -r`/`nim cpp -r`
  # test_softlink invocations (which genuinely need per-OS PATH/env wiring)
  # remain inside the `when`/`elif`/`else` branches below.
  expectDiag(dupFailCheck, "#14 duplicate dynlib block",
    "collides with an earlier dynlib block")
  expectDiag(gateFailCheck, "verifyWhen true-gate signature mismatch", gateFailAnchor)
  expectDiag(contraFailCheck, "verifyWhen+noverify contradiction", contraFailAnchor)
  expectDiag(protoContraFailCheck, "prototype+noverify contradiction", protoContraFailAnchor)
  # Finding #19.9: fpret/variadic diagnostic wording pins.
  expectDiag(protoVariadicFailCheck, "prototype must not be variadic", protoVariadicFailAnchor)
  expectDiag(protoFnptrReturnFailCheck, "prototype fn-ptr-return rejection",
    protoFnptrReturnFailAnchor)
  expectDiag(protoMismatchFailCheck, "prototype-only signature mismatch", protoMismatchFailAnchor)
  expectCompileFailure(protoConflictCCheck)
  expectCompileFailure(protoConflictCppCheck)
  # RFC-0001 slice A8: verifyProcs parity analogs of the A3/A4 negative
  # fixtures directly above.
  expectDiag(vpProtoMismatchFailCheck, "verifyProcs prototype-only signature mismatch",
    vpProtoMismatchFailAnchor)
  expectCompileFailure(vpProtoConflictCCheck)
  expectCompileFailure(vpProtoConflictCppCheck)
  # Code-review finding F4: {.optional.} rejection in verifyProcs, pinned to
  # its exact diagnostic wording.
  expectDiag(vpOptionalFailCheck, "verifyProcs rejects optional", vpOptionalFailAnchor)
  expectDiag(hintCheck, "noverify hint", "not header-verified", "Hint:")
  expectDiag(warnCheck, "noverify warning (strict)", "not header-verified", "Warning:")
  expectDiag(reasonHintCheck, "noverify reason hint",
    "private symbol, no public header at any version", "Hint:", "(no justification)")
  expectDiag(reasonWarnCheck, "noverify reason warning (strict)",
    "private symbol, no public header at any version", "Warning:", "(no justification)")
  expectDiag(noverifyBlockHintCheck, "block-level noverify collapsed hint",
    "3 symbols not header-verified", "2 symbols, block-level reason: \"no public header for these\"",
    "foo_own — \"its own, separate reason\"", "Hint:")
  expectDiag(noverifyBlockWarnCheck, "block-level noverify collapsed warning (strict)",
    "3 symbols not header-verified", "2 symbols, block-level reason: \"no public header for these\"",
    "foo_own — \"its own, separate reason\"", "Warning:")
  expectDiag(untilRequiredHintCheck, "until required-symbol hint",
    "drifted-but-required", "did you mean {.optional.}?", "Hint:")
  expectDiag(untilRequiredWarnCheck, "until required-symbol warning (strict)",
    "drifted-but-required", "did you mean {.optional.}?", "Warning:")
  expectDiag(nonBuiltinHintCheck, "prototype non-builtin identifier hint",
    "may need `header:` to resolve", "Hint:")
  expectDiag(nonBuiltinWarnCheck, "prototype non-builtin identifier warning (strict)",
    "may need `header:` to resolve", "Warning:")
  # RFC-0001 slice A8: verifyProcs parity analog of the A6 non-builtin hint
  # check directly above.
  expectDiag(vpNonBuiltinHintCheck, "verifyProcs prototype non-builtin hint",
    "may need `header:` to resolve", "Hint:")
  expectDiag(vpNonBuiltinWarnCheck, "verifyProcs prototype non-builtin warning (strict)",
    "may need `header:` to resolve", "Warning:")
  expectDiag(versionMacrosUnusedHintCheck, "versionMacros unused hint",
    "declared but never used", "Hint:")
  # Flip side of every OTHER strict-mode check above: those assert
  # escalation TO a Warning; this asserts the DELIBERATE ABSENCE of one —
  # the hint text is present, but never as a Warning, confirming
  # `checkVersionMacrosConsumed` really is exempt from the
  # -d:softlinkStrictVerify escalation every other trust-point hint gets.
  expectManifestCompileOk(versionMacrosUnusedStrictCheck,
    ["declared but never used", "Hint:"],
    ["Warning: softlink: dynlib: versionMacros"])

  if dirExists(protoEmitDir): rmDir(protoEmitDir)
  exec protoEmitCheck
  expectInGenC(protoEmitDir, "extern int testlib_protoonly(void);",
    "A2: prototype-only proc emits a real extern decl")
  # RFC-0001 slice A8: verifyProcs parity analog of A2's dynlib
  # prototype-only emission proof directly above — see `vpProtoOnlyDecl`'s
  # doc comment for why this is unambiguous.
  expectInGenC(protoEmitDir, vpProtoOnlyDecl,
    "A8: verifyProcs prototype-only proc emits a real extern decl")
  expectAdjacentPair(protoEmitDir, protoGateTrueAnchor, protoGateTrueDecl,
    "A5 true-gate (dynlib): declaration adjacent to its gate")
  expectAdjacentPair(protoEmitDir, protoGateFalseAnchor, protoGateFalseDecl,
    "A5 false-gate (dynlib): declaration adjacent to its gate")
  expectAdjacentPair(protoEmitDir, protoGateTrueAnchor, vpProtoGateTrueDecl,
    "A8 true-gate (verifyProcs): declaration adjacent to its gate")
  expectAdjacentPair(protoEmitDir, protoGateFalseAnchor, vpProtoGateFalseDecl,
    "A8 false-gate (verifyProcs): declaration adjacent to its gate")
  rmDir(protoEmitDir)

  if dirExists(protoOnlyDir): rmDir(protoOnlyDir)
  exec protoOnlyCheck
  expectNoEmptyInclude(protoOnlyDir)
  expectInGenC(protoOnlyDir, protoOnlyDecl,
    "A6: prototype-only block (no header) still emits its extern decl")
  rmDir(protoOnlyDir)

  runDumpProbesCheck()

  # RFC-0001 §4 B.2: define-gated probe modes.
  expectDiag(probeMismatchVerifyFailCheck, "verify-mode probe still surfaces a mismatch",
    poAssertAdd)
  exec probeMismatchExistenceSuccessCheck
  expectCompileFailure(probeAbsentCCheck)
  expectCompileFailure(probeAbsentCppCheck)
  expectDiag(probeNoTargetUnsetCheck, "probeExistence with no target (unset)",
    probeNoTargetAnchor)
  expectDiag(probeNoTargetSentinelCheck, "probeExistence with no target (sentinel)",
    probeNoTargetAnchor)

  runProbeOnlyChecks()
  runGroundTruthChecks()
  runGatedDriftChecks()
  runVersionMacrosGateChecks()
  runCorpusChecks()
  runManifestChecks()
  runVersionProbeChecks()

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
    runCompatReportManifestChecks("DYLD_LIBRARY_PATH=./tests nim c -r --path:src --passC:-I.")
    runDriftRequiredChecks("DYLD_LIBRARY_PATH=./tests nim c -r --path:src --passC:-I.")
    runDegradationChecks("DYLD_LIBRARY_PATH=./tests nim c -r --path:src --passC:-I.")
    # RFC-0003 slice B2c (round-2 blocking item): the harvester check, real
    # clang compiles, `clangHarvestOptions()` selected via `clangLeg = true`
    # (see `runHarvesterCheck`'s own doc comment) — the macOS/clang leg
    # this was previously never wired into.
    runHarvesterCheck(clangLeg = true)
  else:
    exec "gcc -shared -fPIC -o tests/libtestlib.so tests/testlib.c"
    exec "gcc -shared -fPIC -o tests/libmagic.so tests/testlib.c"
    # Versioned soname with NO bare libvern.so — forces the major fallback.
    exec "gcc -shared -fPIC -o tests/libvern.so.3 tests/testlib.c"
    exec "LD_LIBRARY_PATH=./tests nim c -r --path:src --passC:-I. tests/test_softlink.nim"
    exec "LD_LIBRARY_PATH=./tests nim cpp -r --path:src --passC:-I. tests/test_softlink.nim"
    # RFC-0001 slice A4, optional extra confidence (gcc/clang-gated only —
    # never on the Windows/MSVC or macOS/clang legs): also inspect the
    # compiler's own wording for the redeclaration conflict. Deliberately
    # NOT required for the check to pass (the exit-code assertion above
    # already is the required, portable check) — this is a supplementary
    # sanity check on the one CI leg most likely to catch a wording
    # regression in this specific gcc version, kept out of the required
    # path since gcc's exact phrasing ("conflicting types for ...") is not
    # a stable cross-version/cross-compiler contract the way softlink's own
    # diagnostic strings are.
    expectDiag(protoConflictCCheck, "gcc wording sanity (supplementary, not required)",
      "conflicting types for")
    # RFC-0001 slice A8: same optional gcc-gated wording sanity check, for
    # the verifyProcs conflict fixture.
    expectDiag(vpProtoConflictCCheck, "gcc wording sanity (supplementary, not required)",
      "conflicting types for")
    runCompatReportManifestChecks("LD_LIBRARY_PATH=./tests nim c -r --path:src --passC:-I.")
    runDriftRequiredChecks("LD_LIBRARY_PATH=./tests nim c -r --path:src --passC:-I.")
    runDegradationChecks("LD_LIBRARY_PATH=./tests nim c -r --path:src --passC:-I.")
    runHarvesterCheck()
    runGoldenVerifyApparatusCheck()

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

  # Finding #24(a) (code-review round 2 coverage gap): `task test`'s
  # `probeAbsentCCheck`/`probeAbsentCppCheck` (RFC-0001 §4 B.2 — an
  # existence probe of a symbol the header does NOT declare must FAIL) are
  # exit-code-only checks, same mold as the four `expectCompileFailure`
  # calls directly above -- a raw "undeclared identifier" compiler
  # diagnostic, not softlink's own string -- yet they were never wired into
  # this task, unlike the A4 prototype-conflict pair. Same fixture
  # (tests/tfail_probe_existence_absent.nim) and defines as `task test`'s
  # own consts, `--cc:vcc`/`/I.`/`/std:clatest` swapped in for gcc/`-I.`.
  expectCompileFailure("nim c" & vccFlags &
    "-d:softlinkProbeOnly=testlib_totally_absent -d:softlinkProbeExistence " &
    "tests/tfail_probe_existence_absent.nim")
  expectCompileFailure("nim cpp" & vccFlags &
    "-d:softlinkProbeOnly=testlib_totally_absent -d:softlinkProbeExistence " &
    "tests/tfail_probe_existence_absent.nim")

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

  # RFC-0003 §5.3/§7 slice B3: the `/std:clatest` VARIANT of the check
  # immediately above — under the C23 gate the verification tier is LIVE
  # (unlike the default-mode check above, where the whole tier is dead),
  # but MSVC treats a pointer-parameter-only mismatch as warning C4133 by
  # default and understands none of the GCC/Clang `-Werror=` diagnostics
  # pins, so the fourth calibration symbol (`calib_param_drifted`, slice
  # B3) still classifies `fkVerified` there and calibration still refuses —
  # for a different reason than the sibling default-mode check. Together
  # the two prove MSVC harvest refuses in EVERY flag configuration this
  # project ships an opts literal for (RFC-0003 §5.3). Same exec mechanism
  # as the line above; see `tests/tharvest_msvc_calibration_refusal_
  # clatest.nim`'s own doc comment for the full rationale and why it is
  # structurally identical to the proven sibling test.
  exec "nim c -r --path:src tests/tharvest_msvc_calibration_refusal_clatest.nim"

  # RFC-0002 §6, slice C3a: the dual-header gated-drift fixture
  # (tests/tverify_gated_drift.nim), vcc-flavored — `task test`'s
  # `runGatedDriftChecks` already exercises the C++ `decltype`+`is_same`
  # and GCC/Clang `__builtin_types_compatible_p`+`__typeof__` tiers; the
  # MSVC leg does not run `task test` at all (see this task's own opening
  # comment), so the third (`_Generic`+`__typeof__`) tier gets NO coverage
  # of a TRUE `{.verifyWhen.}` gate branch type-checking against a real,
  # present declaration unless it's added here too. Two REAL compiles
  # (successful — `expectCompileFailure` doesn't apply), same distinct-
  # --nimcache-per-invocation isolation `runGatedDriftChecks` uses (a `/D`
  # flag changes no Nim-emitted C, so a shared nimcache risks a vacuous
  # pass exactly as documented there), `/D` swapped in for `-D` to match
  # cl.exe's define syntax (`vccFlags` above already swaps `/I.`/
  # `/std:clatest` in for gcc's `-I.`).
  const vccGatedDriftDir1 = "tests/nimcache_gated_drift_vcc_v1"
  const vccGatedDriftDir2 = "tests/nimcache_gated_drift_vcc_v2"
  runDualNimcacheCompile(vccGatedDriftDir1, vccGatedDriftDir2, vccFlags,
    "--passC:/DTESTLIB_VERSION=2 ", "tests/tverify_gated_drift.nim",
    "tests/tverify_gated_drift.exe")

  # RFC-0002 §5/§6, slice E2: the SYNTHESIZED-gate sibling of the
  # dual-compile just above (`tests/tverify_synthesized_gate.nim`,
  # `task test`'s own `runVersionMacrosGateChecks` exercises the C++/GCC
  # tiers) — same MSVC-leg-only third-tier coverage rationale, same
  # distinct-per-invocation --nimcache isolation.
  const vccSynthGateDir1 = "tests/nimcache_synth_gate_vcc_v1"
  const vccSynthGateDir2 = "tests/nimcache_synth_gate_vcc_v2"
  runDualNimcacheCompile(vccSynthGateDir1, vccSynthGateDir2, vccFlags,
    "--passC:/DTESTLIB_VERSION=2 ", "tests/tverify_synthesized_gate.nim",
    "tests/tverify_synthesized_gate.exe")

  # RFC-0002 §5/§6 Z3 extension: the vcc-leg sibling of the dual-compile
  # just above, for `versionMacros(..., header = "...")`'s own synthesized-
  # gate fixture (`tests/tverify_synthesized_gate_header.nim`,
  # `task test`'s own `runVersionMacrosGateChecks` exercises the C++/GCC
  # tiers) — same MSVC-leg-only third-tier coverage rationale, same
  # distinct-per-invocation --nimcache isolation, matching the E2 precedent
  # immediately above exactly.
  const vccSynthGateHeaderDir1 = "tests/nimcache_synth_gate_header_vcc_v1"
  const vccSynthGateHeaderDir2 = "tests/nimcache_synth_gate_header_vcc_v2"
  runDualNimcacheCompile(vccSynthGateHeaderDir1, vccSynthGateHeaderDir2, vccFlags,
    "--passC:/DTESTLIB_VERSION=2 ", "tests/tverify_synthesized_gate_header.nim",
    "tests/tverify_synthesized_gate_header.exe")

  # Code review CR1-8, cell 3: the vcc-leg sibling of `task test`'s own
  # `runVersionMacrosGateChecks` undefined-macro `#ifndef`/`#error` guard
  # check (GCC and, as of this same finding, C++ tiers) —
  # `tests/tfail_versionmacros_undefined_macro.nim`'s guard fires a real C
  # preprocessor `#error`, genuinely observable as a nonzero exit under
  # MSVC too. Per this task's own opening comment, softlink-authored-
  # string greps stay Linux/gcc-only (MSVC diagnostic/preprocessor text
  # quoting can differ enough to be flaky) — so, exactly like the four
  # `expectCompileFailure` checks and the probe-existence-absent pair
  # above, this is pattern-only (exit-code only), no needle.
  expectCompileFailure("nim c" & vccFlags &
    "tests/tfail_versionmacros_undefined_macro.nim")

  # RFC-0002 §5/§6 Z3 extension: the vcc-leg sibling of the same guard
  # check, for the `header =` feature's own negative control
  # (`tests/tfail_versionmacros_header_missing.nim`) — same pattern-only
  # (exit-code-only) rationale as immediately above.
  expectCompileFailure("nim c" & vccFlags &
    "tests/tfail_versionmacros_header_missing.nim")
