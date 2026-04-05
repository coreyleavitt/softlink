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
