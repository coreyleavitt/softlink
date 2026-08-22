## Windows-only measurement leg for RFC 0011 S0a item 5 (loader-error detail
## on `lrLibNotFound`) — stories (f) and (g).
##
## Builds `victim.dll` (linked against `missing_dep.dll` at build time,
## which is then deleted) and measures two things against the REAL Win32
## loader, per the RFC's "measure-don't-assert" obligation:
##
##   1. Whether `LoadLibraryA` returns the SAME error code
##      (`ERROR_MOD_NOT_FOUND`, 126) for a present-target/missing-dependency
##      DLL and for a truly-absent DLL — Windows' documented "does not name
##      the missing dependency" ambiguity (dlerror() on Linux does not have
##      this problem — see `tests/tloader_detail.nim` story (c)).
##   2. Whether a `LoadLibraryExA(path, 0, DONT_RESOLVE_DLL_REFERENCES)`
##      preflight on the SAME path cheaply separates the two cases (it
##      skips import resolution, so it should succeed for a present target
##      regardless of its dependencies, and fail only when the target
##      itself is absent).
##
## Both are ALSO measured as unit-level facts via `softlink/loader`'s own
## public `loadLibPatternDetailed` (the production code path), pinning that
## `osLoaderDetail`'s rendered text actually carries the distinguishing
## annotation `softlink/loader.nim` adds when the preflight succeeds.
##
## Compile/run (see `task testWindows` in softlink.nimble for the full,
## repeatable fixture-build + run recipe — this file assumes
## `victim.dll` already exists in the CURRENT directory and
## `missing_dep.dll` does NOT):
##   nim c -r --path:src tests/tloader_windows.nim

when not defined(windows):
  {.hint: "tloader_windows: no-op stub — Windows-only (RFC 0011 S0a item 5 stories f/g)".}
else:
  import std/[unittest, strutils]
  import softlink/loader

  type HMODULE = pointer
  proc winLoadLibraryA(path: cstring): HMODULE
    {.importc: "LoadLibraryA", header: "<windows.h>", stdcall.}
  proc winLoadLibraryExA(path: cstring, hFile: pointer, flags: uint32): HMODULE
    {.importc: "LoadLibraryExA", header: "<windows.h>", stdcall.}
  proc winFreeLibrary(lib: HMODULE): cint
    {.importc: "FreeLibrary", header: "<windows.h>", stdcall.}
  proc winGetLastError(): uint32
    {.importc: "GetLastError", header: "<windows.h>", stdcall.}

  const
    kDontResolveDllReferences = 0x00000001'u32
    kErrorModNotFound = 126'u32

  suite "Windows measurement (story f): LoadLibrary error-code ambiguity":
    test "present-target/missing-dependency and truly-absent both yield ERROR_MOD_NOT_FOUND":
      let hVictim = winLoadLibraryA("victim.dll")
      let victimCode = winGetLastError()
      check hVictim.isNil
      if not hVictim.isNil: discard winFreeLibrary(hVictim)

      let hAbsent = winLoadLibraryA("totally_absent_xyz.dll")
      let absentCode = winGetLastError()
      check hAbsent.isNil
      if not hAbsent.isNil: discard winFreeLibrary(hAbsent)

      echo "MEASURED: victim.dll (present, missing dep) GetLastError=", victimCode
      echo "MEASURED: totally_absent_xyz.dll GetLastError=", absentCode
      # The ambiguity the RFC's caveat describes: same code, same message,
      # for two operationally different failures.
      check victimCode == kErrorModNotFound
      check absentCode == kErrorModNotFound
      check victimCode == absentCode

  suite "Windows measurement (story f): DONT_RESOLVE_DLL_REFERENCES preflight":
    test "the preflight succeeds for the present target and fails for the truly-absent one":
      let hVictimPreflight = winLoadLibraryExA("victim.dll", nil, kDontResolveDllReferences)
      let victimPreflightOk = not hVictimPreflight.isNil
      if victimPreflightOk: discard winFreeLibrary(hVictimPreflight)

      let hAbsentPreflight = winLoadLibraryExA("totally_absent_xyz.dll", nil, kDontResolveDllReferences)
      let absentPreflightOk = not hAbsentPreflight.isNil
      if absentPreflightOk: discard winFreeLibrary(hAbsentPreflight)

      echo "MEASURED: victim.dll DONT_RESOLVE_DLL_REFERENCES preflight succeeds=", victimPreflightOk
      echo "MEASURED: totally_absent_xyz.dll DONT_RESOLVE_DLL_REFERENCES preflight succeeds=", absentPreflightOk
      # This is the finding that justifies wiring the preflight into
      # softlink/loader.nim's Windows failure path: it separates the two
      # cases the plain error code (story above) cannot.
      check victimPreflightOk
      check not absentPreflightOk

  suite "story (g): the production loadLibPatternDetailed path carries the distinguishing annotation":
    test "present-target/missing-dependency detail is annotated; truly-absent is not":
      let (hVictim, victimAttempts) = loadLibPatternDetailed("victim.dll")
      check hVictim.isNil
      check victimAttempts.len == 1
      check victimAttempts[0].osErrorCode == kErrorModNotFound.int
      check "dependency is likely missing" in victimAttempts[0].osError

      let (hAbsent, absentAttempts) = loadLibPatternDetailed("totally_absent_xyz.dll")
      check hAbsent.isNil
      check absentAttempts.len == 1
      check absentAttempts[0].osErrorCode == kErrorModNotFound.int
      check "dependency is likely missing" notin absentAttempts[0].osError
