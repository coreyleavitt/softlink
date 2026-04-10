## Tests for softlink macro.
##
## Tests against system math/C libraries (Linux) and a custom test library (all platforms).
## Build the test library before running (see nimble test task).

import std/[unittest, math, strutils]
import softlink

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
    check r.missing == @["testlib_future"]

  test "testlib: availability check for optional symbols":
    check loadTestlib().kind in {lrOk, lrOkPartial}
    check not testlib_futureAvailable()

  test "testlib: calling missing optional raises SoftlinkError":
    check loadTestlib().kind in {lrOk, lrOkPartial}
    expect SoftlinkError:
      discard testlib_future()

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
    check r2.missing == @["testlib_future"]

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
