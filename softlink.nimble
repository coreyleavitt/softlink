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
  const dupFailCheck = "nim c --path:src tests/tfail_duplicate_dynlib.nim"
  const gateFailCheck = "nim c --path:src --passC:-I. tests/tfail_verifywhen_mismatch.nim"
  const contraFailCheck = "nim c --path:src tests/tfail_verifywhen_noverify.nim"
  const protoContraFailCheck = "nim c --path:src tests/tfail_prototype_noverify.nim"
  const protoMismatchFailCheck = "nim c --path:src --passC:-I. tests/tfail_prototype_mismatch.nim"
  # (--compileOnly: the diagnostics fire at macro expansion, so skipping the
  # C compile+link keeps the check fast and leaves no stray binary behind.)
  const hintCheck = "nim c --compileOnly --path:src tests/thint_noverify.nim"
  const warnCheck = "nim c --compileOnly --path:src -d:softlinkStrictVerify tests/thint_noverify.nim"
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
  if dirExists(protoEmitDir): rmDir(protoEmitDir)
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
    exec hintCheck & " 2>&1 | findstr /C:\"not header-verified\" | findstr /C:\"Hint:\" >NUL"
    exec warnCheck & " 2>&1 | findstr /C:\"not header-verified\" | findstr /C:\"Warning:\" >NUL"
    exec protoEmitCheck
    exec "findstr /s /m /c:\"extern int testlib_protoonly(void);\" " &
      protoEmitDir & "\\*.c >NUL"
    rmDir(protoEmitDir)
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
    exec hintCheck & " 2>&1 | grep 'not header-verified' | grep -q 'Hint:'"
    exec warnCheck & " 2>&1 | grep 'not header-verified' | grep -q 'Warning:'"
    exec protoEmitCheck
    exec "grep -rq 'extern int testlib_protoonly(void);' " & protoEmitDir
    rmDir(protoEmitDir)
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
    exec hintCheck & " 2>&1 | grep 'not header-verified' | grep -q 'Hint:'"
    exec warnCheck & " 2>&1 | grep 'not header-verified' | grep -q 'Warning:'"
    exec protoEmitCheck
    exec "grep -rq 'extern int testlib_protoonly(void);' " & protoEmitDir
    rmDir(protoEmitDir)
