## Direct unit tests for `softlink/loader.loadLibPatternDetailed` — RFC 0011
## S0a item 5. Exercises the per-candidate loader loop directly (no `dynlib`
## macro involved — that integration is covered separately in
## `tests/test_softlink.nim`'s "osLoaderDetail" suite), against real fixture
## `.so` files built by `nimble test`'s Linux branch just before this file
## runs (see `softlink.nimble`).
##
## Compile/run: LD_LIBRARY_PATH=./tests nim c -r --path:src tests/tloader_detail.nim

import std/[unittest, strutils]
import softlink/loader

suite "loadLibPatternDetailed — absent library (story a)":
  test "every candidate is named, each with a non-empty OS error":
    let (handle, attempts) = loadLibPatternDetailed("libtotally_absent_xyz.so(.9|.8|.7)")
    check handle.isNil
    check attempts.len == 3
    check attempts[0].candidate == "libtotally_absent_xyz.so.9"
    check attempts[1].candidate == "libtotally_absent_xyz.so.8"
    check attempts[2].candidate == "libtotally_absent_xyz.so.7"
    for a in attempts:
      check a.osError.len > 0

suite "loadLibPatternDetailed — present but not a valid shared object (story b)":
  test "detail contains dlerror's actual complaint, not a generic absence message":
    # tests/libgarbage.so is a plain text file (built by softlink.nimble's
    # Linux branch just before this suite runs) — present on disk, but not
    # an ELF shared object.
    let (handle, attempts) = loadLibPatternDetailed("libgarbage.so")
    check handle.isNil
    check attempts.len == 1
    check attempts[0].candidate == "libgarbage.so"
    # Measured (see this item's report): dlerror() says
    # "<resolved-path>: file too short" for a non-ELF file — a diagnostic
    # about the FILE's content, distinguishable from "could not find it".
    check "libgarbage.so" in attempts[0].osError
    check "file too short" in attempts[0].osError

suite "loadLibPatternDetailed — present target, missing transitive dependency (story c)":
  test "detail names the missing dependency, not the target itself":
    # tests/libhasdep.so is a real, valid ELF shared object linked against
    # tests/libstubdep.so at build time; softlink.nimble's Linux branch
    # deletes libstubdep.so afterward, leaving libhasdep.so's DT_NEEDED
    # entry unresolvable.
    let (handle, attempts) = loadLibPatternDetailed("libhasdep.so")
    check handle.isNil
    check attempts.len == 1
    check attempts[0].candidate == "libhasdep.so"
    # Measured: dlerror() on Linux names the MISSING DEPENDENCY
    # ("libstubdep.so"), not the library that was actually requested
    # ("libhasdep.so") — this is exactly the property the RFC's Windows
    # measurement leg (story f/g) finds Windows does NOT give for free.
    check "libstubdep.so" in attempts[0].osError

suite "loadLibPatternDetailed — candidate ordering and success unchanged (story d)":
  test "a multi-candidate pattern succeeding on a later candidate returns lrOk semantics: no leaked failure detail":
    # libvern.so.3 exists; the bare libvern.so and every higher-numbered
    # major candidate this pattern tries first do not (see
    # softlink.nimble's Linux branch and test_softlink.nim's own "dynlib
    # magic — runtime-only versioned soname" suite for the non-detailed
    # version of this same fixture).
    let (handle, attempts) = loadLibPatternDetailed("libvern.so(|.7|.6|.5|.4|.3|.2|.1)")
    check not handle.isNil
    check attempts.len == 0
    unloadLib(handle)
