## Tests for softlink macro.
##
## Tests against libm, libc, and libdl (always available on POSIX systems).
## This validates the macro generates correct bindings without needing
## any special library installed.

import std/[unittest, math, dynlib, strutils]
import softlink

# Bind to libm — available everywhere on Linux (part of libc/musl)
dynlib "libm.so(.6|)":
  proc ceil(x: cdouble): cdouble {.cdecl.}
  proc floor(x: cdouble): cdouble {.cdecl.}
  proc sqrt(x: cdouble): cdouble {.cdecl.}
  proc pow(base: cdouble, exp: cdouble): cdouble {.cdecl.}

# Bind to libc for void-returning functions
dynlib "libc.so(.6|)":
  proc srand(seed: cuint) {.cdecl.}
  proc rand(): cint {.cdecl.}

# Bind to a real library (libdl) with a nonexistent symbol — tests all-or-nothing
dynlib "libdl.so(.2|)":
  proc not_a_real_symbol(x: cdouble): cdouble {.cdecl.}

# Bind to libpthread with required + optional symbols
dynlib "libpthread.so(.0|)":
  proc pthread_self(): culong {.cdecl.}                       # required (exists)
  proc not_real_v2(x: cint): cint {.cdecl, optional.}        # optional (doesn't exist)
  proc also_not_real(): cint {.cdecl, optional.}              # optional (doesn't exist)

# Bind to a library that definitely doesn't exist
dynlib "libdefinitely_not_real.so":
  proc fake_function(x: cint): cint {.cdecl.}

suite "softlink":
  test "loadM succeeds (libm always available)":
    check loadM().kind == lrOk
    check mLoaded()

  test "math functions work through bindings":
    check loadM().kind == lrOk
    check ceil(2.3) == 3.0
    check floor(2.7) == 2.0
    check sqrt(16.0) == 4.0
    check pow(2.0, 10.0) == 1024.0

  test "missing library returns lrLibNotFound":
    check loadDefinitelyNotReal().kind == lrLibNotFound
    check not definitelynotrealLoaded()

  test "calling unloaded function raises SoftlinkError":
    check not definitelynotrealLoaded()
    expect SoftlinkError:
      discard fake_function(42)

  test "unload then reload works":
    check loadM().kind == lrOk
    unloadM()
    check not mLoaded()
    check loadM().kind == lrOk
    check ceil(1.1) == 2.0

  test "double load is idempotent":
    check loadM().kind == lrOk
    check loadM().kind == lrOk  # already loaded, still lrOk
    check ceil(1.1) == 2.0

  test "void proc dispatch works (no return type)":
    check loadC().kind == lrOk
    srand(42.cuint)  # should not crash — void return
    let val = rand()
    srand(42.cuint)  # same seed
    check rand() == val  # deterministic

  test "SoftlinkError contains symbol and library name":
    check not definitelynotrealLoaded()
    try:
      discard fake_function(42)
      fail()  # should not reach here
    except SoftlinkError as e:
      check e.symbol == "fake_function"
      check e.library == "libdefinitely_not_real.so"
      check "fake_function" in e.msg
      check "libdefinitely_not_real.so" in e.msg

  test "unload when not loaded is a no-op":
    check not definitelynotrealLoaded()
    unloadDefinitelyNotReal()  # should not crash
    check not definitelynotrealLoaded()

  test "missing symbol in real library returns lrSymbolNotFound":
    let r = loadDl()
    check r.kind == lrSymbolNotFound
    check r.symbol == "not_a_real_symbol"
    check not dlLoaded()

  test "calling after unload raises SoftlinkError":
    check loadM().kind == lrOk
    check ceil(1.1) == 2.0  # works while loaded
    unloadM()
    expect SoftlinkError:
      discard ceil(1.1)  # should raise after unload

  test "optional: partial load returns lrOkPartial with missing symbols":
    let r = loadPthread()
    check r.kind == lrOkPartial
    check r.missing == @["not_real_v2", "also_not_real"]
    check pthreadLoaded()

  test "optional: required symbols work after partial load":
    check loadPthread().kind in {lrOk, lrOkPartial}
    discard pthread_self()  # required symbol works

  test "optional: availability check returns false for missing":
    check loadPthread().kind in {lrOk, lrOkPartial}
    check not not_real_v2Available()
    check not also_not_realAvailable()

  test "optional: calling missing optional symbol raises SoftlinkError":
    check loadPthread().kind in {lrOk, lrOkPartial}
    expect SoftlinkError:
      discard not_real_v2(42)

  test "optional: all-required lib returns lrOk not lrOkPartial":
    check loadM().kind == lrOk  # libm has no optional symbols

  test "compile-time: rejects proc without calling convention":
    check not compiles(block:
      dynlib "libfoo.so":
        proc foo(x: cint): cint
    )

  test "compile-time: rejects unsupported pragma (varargs)":
    check not compiles(block:
      dynlib "libfoo.so":
        proc foo(x: cint): cint {.cdecl, varargs.}
    )
