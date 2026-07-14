## Tests for softlink macro.
##
## Tests against system math/C libraries (Linux) and a custom test library (all platforms).
## Build the test library before running (see nimble test task).

import std/[unittest, math, strutils]
import softlink {.all.}

suite "deriveLibPattern — logical name → per-OS candidates":
  test "Linux → bare .so first, then descending single-component majors":
    check deriveLibPattern("z3", osLinux) == "libz3.so(|.7|.6|.5|.4|.3|.2|.1)"

  test "bare name on Windows → both lib-prefixed and bare .dll":
    check deriveLibPattern("z3", osWindows) == "(libz3|z3).dll"

  test "macOS → bare .dylib first, then descending majors":
    check deriveLibPattern("z3", osMacos) == "libz3(|.7|.6|.5|.4|.3|.2|.1).dylib"

  test "leading 'lib' is stripped so libz3 and z3 agree":
    check deriveLibPattern("libz3", osLinux) == deriveLibPattern("z3", osLinux)
    check deriveLibPattern("libz3", osWindows) == deriveLibPattern("z3", osWindows)

suite "isLogicalName — magic vs verbatim (escape hatch) routing":
  test "bare stems are logical → magic derivation":
    check isLogicalName("z3")
    check isLogicalName("libz3")
    check isLogicalName("mbedtls")

  test "explicit patterns are not logical → used verbatim":
    # Anything carrying an extension, alternation, or path separator is the
    # author's exact loadLibPattern string and must pass through untouched.
    check not isLogicalName("libz3.so(.4|)")
    check not isLogicalName("libtestlib.so")
    check not isLogicalName("libm.so(.6|)")
    check not isLogicalName("/opt/z3/lib/libz3.so")
    check not isLogicalName(r"C:\z3\libz3.dll")

suite "logical-name ident derivation is OS-invariant (C1 regression)":
  # The macro derives its load/unload/loaded proc names from libNameToIdent
  # applied to the *logical name*, never to the OS-expanded pattern. Feeding the
  # Windows-expanded pattern "(libz3|z3).dll" to libNameToIdent mangles it to
  # "Libz3z3" — which would generate loadLibz3z3 on Windows while Linux/macOS
  # generate loadZ3. Deriving from the logical name keeps idents identical
  # across every target by construction.
  test "logical name yields a stable, OS-independent base ident":
    check libNameToIdent("z3") == "Z3"
    check libNameToIdent("libz3") == "Z3"
  test "the OS-expanded Windows pattern is the trap the macro must avoid":
    check libNameToIdent(deriveLibPattern("z3", osWindows)) == "Libz3z3"
    check libNameToIdent("z3") != libNameToIdent(deriveLibPattern("z3", osWindows))

# System library tests — Linux only (library names produce consistent identifiers)
when defined(linux):
  dynlib "libm.so(.6|)":
    proc ceil(x: cdouble): cdouble {.cdecl, header: "math.h".}
    proc floor(x: cdouble): cdouble {.cdecl, header: "math.h".}
    proc sqrt(x: cdouble): cdouble {.cdecl, header: "math.h".}
    proc pow(base: cdouble, exp: cdouble): cdouble {.cdecl, header: "math.h".}
    proc round(x: cdouble): cdouble {.cdecl, header: "<math.h>".}  # angle-bracket syntax

  dynlib "libc.so(.6|)":
    proc srand(seed: cuint) {.cdecl, header: "stdlib.h".}
    proc rand(): cint {.cdecl, header: "stdlib.h".}


# Test library — cross-platform (built from tests/testlib.c)
when defined(windows):
  const TestLib = "testlib.dll"
elif defined(macosx):
  const TestLib = "libtestlib.dylib"
else:
  const TestLib = "libtestlib.so"

dynlib TestLib:
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
  proc testlib_noop() {.cdecl, header: "tests/testlib.h".}
  proc testlib_future(): cint {.cdecl, optional, header: "tests/testlib.h".}
  # Regression: #11 — const-qualified pointer returns must verify
  # against cstring without "signature mismatch" errors under any
  # backend. testlib_const_string returns `const char *`; binding
  # as `cstring` should be accepted.
  proc testlib_const_string(): cstring {.cdecl, header: "tests/testlib.h".}
  proc testlib_const_lookup(key: cint): cstring {.cdecl, header: "tests/testlib.h".}
  proc testlib_mutable_string(): cstring {.cdecl, header: "tests/testlib.h".}
  # Defect B regression (#14): testlib_unheralded is in the .so but NOT in
  # testlib.h. {.optional.} alone would still emit the header verification
  # and fail with an implicit-declaration error; {.noverify.} skips it (and
  # makes the header pragma unnecessary). Runtime resolution is unaffected.
  proc testlib_unheralded(): cint {.cdecl, optional, noverify.}
  # noverify symbol missing at runtime too — must degrade exactly like a
  # plain optional symbol (lands in `missing`, Available() false, raises).
  proc testlib_future_nv(): cint {.cdecl, optional, noverify.}

# verifyProcs: compile-time signature verification ONLY (no loading, no
# wrappers). Correct signatures must compile; the const-return case (#11)
# must also be accepted here, sharing dynlib's verification codegen.
verifyProcs:
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
  proc testlib_const_string(): cstring {.cdecl, header: "tests/testlib.h".}

suite "verifyProcs (static-binding header verification)":
  test "correct signatures pass compile-time verification":
    # Reaching here means the verifyProcs block above compiled — the
    # _Static_assert(s) held against the C header. No symbols were loaded.
    check true

suite "softlink":
  # System library tests — Linux only
  when defined(linux):
    test "loadM succeeds (libm always available)":
      check loadM().kind == lrOk
      check mLoaded()

    test "math functions work through bindings":
      check loadM().kind == lrOk
      check ceil(2.3) == 3.0
      check floor(2.7) == 2.0
      check sqrt(16.0) == 4.0
      check pow(2.0, 10.0) == 1024.0

    test "unload then reload works":
      check loadM().kind == lrOk
      unloadM()
      check not mLoaded()
      check loadM().kind == lrOk
      check ceil(1.1) == 2.0

    test "double load is idempotent":
      check loadM().kind == lrOk
      check loadM().kind == lrOk
      check ceil(1.1) == 2.0

    test "void proc dispatch works (no return type)":
      check loadC().kind == lrOk
      srand(42.cuint)
      let val = rand()
      srand(42.cuint)
      check rand() == val

    test "calling after unload raises SoftlinkError":
      check loadM().kind == lrOk
      check ceil(1.1) == 2.0
      unloadM()
      expect SoftlinkError:
        discard ceil(1.1)

    test "SoftlinkError contains symbol and library name":
      unloadM()
      try:
        discard ceil(1.1)
        fail()
      except SoftlinkError as e:
        check e.symbol == "ceil"
        check "ceil" in e.msg

    test "unload when not loaded is a no-op":
      unloadM()
      unloadM()
      check not mLoaded()

    test "optional: all-required lib returns lrOk not lrOkPartial":
      check loadM().kind == lrOk

  # Cross-platform tests using testlib
  test "testlib: required symbols work":
    let r = loadTestlib()
    check r.kind in {lrOk, lrOkPartial}
    check testlib_add(3.cint, 4.cint) == 7.cint

  test "testlib: void required symbol works":
    check loadTestlib().kind in {lrOk, lrOkPartial}
    testlib_noop()

  test "testlib: partial load returns lrOkPartial with missing optional":
    let r = loadTestlib()
    check r.kind == lrOkPartial
    check r.missing == @["testlib_future", "testlib_future_nv"]

  test "testlib: availability check for optional symbols":
    check loadTestlib().kind in {lrOk, lrOkPartial}
    check not testlib_futureAvailable()

  test "testlib: calling missing optional raises SoftlinkError":
    check loadTestlib().kind in {lrOk, lrOkPartial}
    expect SoftlinkError:
      discard testlib_future()

  # Defect B regression (#14): a symbol newer than the installed headers.
  # {.noverify.} skips the compile-time _Static_assert (and the #include of
  # its header) so the block compiles, while runtime resolution still works.
  # The negative side — {.optional.} WITHOUT {.noverify.} fails against a
  # header lacking the symbol — is a C-compile-time failure (implicit
  # declaration), not a Nim one, so it can't be pinned with compiles();
  # verified manually in Docker.
  test "noverify: symbol absent from header resolves at runtime (#14)":
    check loadTestlib().kind in {lrOk, lrOkPartial}
    check testlib_unheraldedAvailable()
    check testlib_unheralded() == 99.cint

  test "noverify: symbol missing at runtime degrades like optional (#14)":
    check loadTestlib().kind in {lrOk, lrOkPartial}
    check not testlib_future_nvAvailable()
    expect SoftlinkError:
      discard testlib_future_nv()

  # Regression: #11 — const-qualified pointer returns must bind to
  # cstring without a "signature mismatch vs testlib.h" error under
  # any backend. Before the fix, the GCC pathway compared
  # `const char *` to `char *` directly and rejected as incompatible.
  # The fix dereferences both sides so `__builtin_types_compatible_p`
  # sees `const char` vs `char` — top-level qualifiers ignored,
  # types match.
  test "testlib: const char* return binds to cstring (#11)":
    check loadTestlib().kind in {lrOk, lrOkPartial}
    check $testlib_const_string() == "hello from testlib"

  test "testlib: const char* return with arg (#11)":
    check loadTestlib().kind in {lrOk, lrOkPartial}
    check $testlib_const_lookup(0.cint) == "zero"
    check $testlib_const_lookup(2.cint) == "two"
    check $testlib_const_lookup(99.cint) == "out-of-range"

  test "testlib: non-const char* return still works (#11 regression baseline)":
    check loadTestlib().kind in {lrOk, lrOkPartial}
    check $testlib_mutable_string() == "mutable"

  test "testlib: unload nils function pointers":
    check loadTestlib().kind in {lrOk, lrOkPartial}
    unloadTestlib()
    expect SoftlinkError:
      discard testlib_add(1.cint, 2.cint)

  test "testlib: idempotent partial load":
    let r1 = loadTestlib()
    check r1.kind == lrOkPartial
    let r2 = loadTestlib()
    check r2.kind == lrOkPartial
    check r2.missing == @["testlib_future", "testlib_future_nv"]

  test "testlib: reload after unload preserves partial status":
    check loadTestlib().kind == lrOkPartial
    unloadTestlib()
    check not testlibLoaded()
    let r = loadTestlib()
    check r.kind == lrOkPartial

  test "testlib: unload then call raises SoftlinkError":
    check loadTestlib().kind in {lrOk, lrOkPartial}
    unloadTestlib()
    expect SoftlinkError:
      discard testlib_add(1.cint, 2.cint)

  test "testlib: SoftlinkError has library name":
    unloadTestlib()
    try:
      discard testlib_add(1.cint, 2.cint)
      fail()
    except SoftlinkError as e:
      check e.symbol == "testlib_add"
      check e.library == TestLib

  # Compile-time validation tests
  test "compile-time: rejects proc without calling convention":
    check not compiles(block:
      dynlib "libfoo.so":
        proc foo(x: cint): cint {.header: "math.h".}
    )

  test "compile-time: rejects unsupported pragma (varargs)":
    check not compiles(block:
      dynlib "libfoo.so":
        proc foo(x: cint): cint {.cdecl, varargs, header: "math.h".}
    )

  test "compile-time: rejects proc without header":
    check not compiles(block:
      dynlib "libfoo.so":
        proc foo(x: cint): cint {.cdecl.}
    )

  # Defect A regression (#14) — duplicate dynlib blocks for the same library —
  # cannot be tested with compiles() here: dynlib generates exported procs
  # (loadFoo*), which are only legal at top level, so ANY dynlib inside a
  # compiles(block:) fails for that unrelated reason. Instead the nimble test
  # task compiles tests/tfail_duplicate_dynlib.nim expecting the clear
  # "collides with an earlier dynlib block" error.

# Missing library — for lrLibNotFound test
dynlib "libdefinitely_not_real.so":
  proc testlib_notreal(): cint {.cdecl, header: "tests/testlib.h".}

# dyntype — compile-time struct layout verification
dyntype "tests/testlib_types.h":
  type TestlibPoint {.ctype: "testlib_point_t".} = object
    x: cint
    y: cint

  type TestlibTaggedValue {.ctype: "testlib_tagged_value_t".} = object
    value: cdouble
    flags: cint

  type TestlibRect {.ctype: "testlib_rect_t".} = object
    origin: TestlibPoint
    width: cint
    height: cint

  type TestlibPointExported* {.ctype: "testlib_point_t".} = object
    x: cint
    y: cint

suite "dyntype":
  test "verified type is defined and usable":
    var p: TestlibPoint
    p.x = 10
    p.y = 20
    check p.x == 10
    check p.y == 20

  test "multiple types verified in one block":
    var tv: TestlibTaggedValue
    tv.value = 3.14
    tv.flags = 42
    check tv.value == 3.14
    check tv.flags == 42

  test "nested struct verified":
    var r: TestlibRect
    r.origin.x = 1
    r.origin.y = 2
    r.width = 100
    r.height = 200
    check r.origin.x == 1
    check r.width == 100

  test "compile-time: rejects type without ctype":
    check not compiles(block:
      dyntype "tests/testlib_types.h":
        type BadType = object
          x: cint
    )

  test "compile-time: rejects non-type in body":
    check not compiles(block:
      dyntype "tests/testlib_types.h":
        proc foo() = discard
    )

  test "compile-time: rejects empty header":
    check not compiles(block:
      dyntype "":
        type BadType {.ctype: "foo_t".} = object
          x: cint
    )

  test "compile-time: rejects unsupported pragma on type":
    check not compiles(block:
      dyntype "tests/testlib_types.h":
        type BadType {.ctype: "testlib_point_t", deprecated.} = object
          x: cint
          y: cint
    )

  test "exported type verified":
    var p: TestlibPointExported
    p.x = 42
    check p.x == 42

  test "compile-time: rejects duplicate type name":
    check not compiles(block:
      dyntype "tests/testlib_types.h":
        type Dup {.ctype: "testlib_point_t".} = object
          x: cint
          y: cint
        type Dup {.ctype: "testlib_point_t".} = object
          x: cint
          y: cint
    )

  # NOTE: sizeof mismatch (e.g., wrong number of fields) is caught by
  # _Static_assert at C compile time, not Nim compile time. Can't test
  # with compiles(). Verified manually in Docker — see task #7.

suite "softlink — error paths":
  test "lrLibNotFound for missing library":
    check loadDefinitelyNotReal().kind == lrLibNotFound

when defined(linux):
  suite "softlink — angle-bracket includes":
    test "angle-bracket header syntax works":
      check loadM().kind == lrOk
      check round(2.7) == 3.0

  suite "softlink — effect tracking":
    test "wrapper procs have {.raises: [SoftlinkError].}":
      # This proc compiles only if ceil's raises list is [SoftlinkError],
      # not the conservative [Exception]
      proc usesCeil(): cdouble {.raises: [SoftlinkError].} =
        ceil(1.1)
      check loadM().kind == lrOk
      check usesCeil() == 2.0

  suite "softlink — callback pointers":
    test "xxxPtr returns typed function pointer for callback use":
      check loadM().kind == lrOk
      let fn = ceilPtr()
      check fn != nil
      # Call directly — no cast needed, already typed
      check fn(2.3) == 3.0

    test "xxxPtr returns nil when not loaded":
      unloadM()
      check ceilPtr() == nil

    test "xxxPtr type is compatible with matching proc params":
      # xxxPtr returns the proc type with {.cdecl, raises: [].}
      proc takesCallback(cb: proc(x: cdouble): cdouble {.cdecl, raises: [].}): cdouble {.raises: [].} =
        cb(1.1)
      check loadM().kind == lrOk
      check takesCallback(ceilPtr()) == 2.0


# End-to-end magic: a bare logical name must resolve to the real on-disk
# file via deriveLibPattern. testlib.c is compiled to libmagic.so (see the
# nimble test task); "magic" must resolve to it.
dynlib "magic":
  proc testlib_magic(): cint {.cdecl, header: "tests/testlib.h".}

suite "dynlib magic — bare logical name resolves and loads":
  test "dynlib \"magic\" resolves to libmagic.so and calls its symbol":
    check loadMagic().kind == lrOk
    check testlib_magic() == 42


# Runtime-only single-component soname: libvern.so.3 exists but NO bare
# libvern.so (the Debian `libz3.so.4` situation). Magic must fall back to a
# versioned major candidate. Linux-only — ELF soname convention.
# (Multi-component sonames like openSUSE's libz3.so.4.15 are out of scope for
# magic resolution — see deriveLibPattern's doc; they use the escape hatch.)
when defined(linux):
  dynlib "vern":
    proc testlib_versioned(): cint {.cdecl, header: "tests/testlib.h".}

  suite "dynlib magic — runtime-only versioned soname":
    test "resolves libvern.so.3 with no bare libvern.so present":
      check loadVern().kind == lrOk
      check testlib_versioned() == 7
