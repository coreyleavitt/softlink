# Package
version       = "0.7.0"
author        = "Corey Leavitt"
description   = "Type-safe optional dynamic library bindings for Nim"
license       = "Apache-2.0"
srcDir        = "src"

# Dependencies
requires "nim >= 2.0.0"

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
    let (output, code) = gorgeEx(cmd)
    if code == 0:
      echo output
      quit("softlink: RFC-0001 slice A4 expected a compile FAILURE (header " &
           "vs. prototype conflict on testlib_add) but the compile " &
           "SUCCEEDED: " & cmd)

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
  if dirExists(protoEmitDir): rmDir(protoEmitDir)
  if dirExists(protoOnlyDir): rmDir(protoOnlyDir)
  when defined(windows):
    exec "gcc -shared -o tests/testlib.dll tests/testlib.c"
    exec "gcc -shared -o tests/libmagic.dll tests/testlib.c"
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
    exec hintCheck & " 2>&1 | findstr /C:\"not header-verified\" | findstr /C:\"Hint:\" >NUL"
    exec warnCheck & " 2>&1 | findstr /C:\"not header-verified\" | findstr /C:\"Warning:\" >NUL"
    exec reasonHintCheck & " 2>&1 | findstr /C:\"private symbol, no public header at any version\" | findstr /C:\"Hint:\" >NUL"
    exec reasonHintCheck & " 2>&1 | findstr /C:\"(no justification)\" >NUL"
    exec reasonWarnCheck & " 2>&1 | findstr /C:\"private symbol, no public header at any version\" | findstr /C:\"Warning:\" >NUL"
    exec reasonWarnCheck & " 2>&1 | findstr /C:\"(no justification)\" >NUL"
    exec nonBuiltinHintCheck & " 2>&1 | findstr /C:\"may need `header:` to resolve\" | findstr /C:\"Hint:\" >NUL"
    exec nonBuiltinWarnCheck & " 2>&1 | findstr /C:\"may need `header:` to resolve\" | findstr /C:\"Warning:\" >NUL"
    exec protoEmitCheck
    exec "findstr /s /m /c:\"extern int testlib_protoonly(void);\" " &
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
    rmDir(protoEmitDir)
    exec protoOnlyCheck
    expectNoEmptyInclude("type " & protoOnlyDir & "\\*.c")
    exec "findstr /s /m /c:\"" & protoOnlyDecl & "\" " &
      protoOnlyDir & "\\*.c >NUL"
    rmDir(protoOnlyDir)
  elif defined(macosx):
    exec "cc -shared -fPIC -o tests/libtestlib.dylib tests/testlib.c"
    exec "cc -shared -fPIC -o tests/libmagic.dylib tests/testlib.c"
    exec "nim c -r --path:src --passC:-I. tests/test_softlink.nim"
    exec "nim cpp -r --path:src --passC:-I. tests/test_softlink.nim"
    exec dupFailCheck & " 2>&1 | grep -q 'collides with an earlier dynlib block'"
    exec gateFailCheck & " 2>&1 | grep -q 'signature mismatch'"
    exec contraFailCheck & " 2>&1 | grep -q 'contradicts'"
    exec protoContraFailCheck & " 2>&1 | grep -q 'contradicts'"
    exec protoMismatchFailCheck & " 2>&1 | grep -q 'signature mismatch'"
    expectCompileFailure(protoConflictCCheck)
    expectCompileFailure(protoConflictCppCheck)
    exec hintCheck & " 2>&1 | grep 'not header-verified' | grep -q 'Hint:'"
    exec warnCheck & " 2>&1 | grep 'not header-verified' | grep -q 'Warning:'"
    exec reasonHintCheck & " 2>&1 | grep 'private symbol, no public header at any version' | grep -q 'Hint:'"
    exec reasonHintCheck & " 2>&1 | grep -q '(no justification)'"
    exec reasonWarnCheck & " 2>&1 | grep 'private symbol, no public header at any version' | grep -q 'Warning:'"
    exec reasonWarnCheck & " 2>&1 | grep -q '(no justification)'"
    exec nonBuiltinHintCheck & " 2>&1 | grep 'may need `header:` to resolve' | grep -q 'Hint:'"
    exec nonBuiltinWarnCheck & " 2>&1 | grep 'may need `header:` to resolve' | grep -q 'Warning:'"
    exec protoEmitCheck
    exec "grep -rq 'extern int testlib_protoonly(void);' " & protoEmitDir
    exec protoGateTrueCheck
    exec protoGateFalseCheck
    rmDir(protoEmitDir)
    exec protoOnlyCheck
    expectNoEmptyInclude("cat " & protoOnlyDir & "/*.c")
    exec "grep -rq '" & protoOnlyDecl & "' " & protoOnlyDir
    rmDir(protoOnlyDir)
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
    exec hintCheck & " 2>&1 | grep 'not header-verified' | grep -q 'Hint:'"
    exec warnCheck & " 2>&1 | grep 'not header-verified' | grep -q 'Warning:'"
    exec reasonHintCheck & " 2>&1 | grep 'private symbol, no public header at any version' | grep -q 'Hint:'"
    exec reasonHintCheck & " 2>&1 | grep -q '(no justification)'"
    exec reasonWarnCheck & " 2>&1 | grep 'private symbol, no public header at any version' | grep -q 'Warning:'"
    exec reasonWarnCheck & " 2>&1 | grep -q '(no justification)'"
    exec nonBuiltinHintCheck & " 2>&1 | grep 'may need `header:` to resolve' | grep -q 'Hint:'"
    exec nonBuiltinWarnCheck & " 2>&1 | grep 'may need `header:` to resolve' | grep -q 'Warning:'"
    exec protoEmitCheck
    exec "grep -rq 'extern int testlib_protoonly(void);' " & protoEmitDir
    exec protoGateTrueCheck
    exec protoGateFalseCheck
    rmDir(protoEmitDir)
    exec protoOnlyCheck
    expectNoEmptyInclude("cat " & protoOnlyDir & "/*.c")
    exec "grep -rq '" & protoOnlyDecl & "' " & protoOnlyDir
    rmDir(protoOnlyDir)
