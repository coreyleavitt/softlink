## softlink/loader — RFC 0011 S0a item 5: per-candidate library loading with
## OS loader-error capture.
##
## `std/dynlib.loadLibPattern` expands a `(a|b)`-alternation pattern into
## concrete candidate names and tries each with `loadLib`, discarding
## whichever OS diagnostic a failing candidate produced along the way — by
## the time `loadLibPattern` returns `nil`, "library absent" and "library
## found but failed to load" (wrong architecture, missing transitive
## dependency) are indistinguishable to the caller. This module takes over
## the per-candidate loop so that diagnostic is captured at the point of
## failure — the only point it CAN be captured: `dlerror()` is cleared by
## the next `dl*` call, and `GetLastError()` by the next Win32 call, so
## recovering it after `loadLibPattern` already returned is not an option.
##
## Deliberately reuses `std/dynlib.libCandidates` (exported by the stdlib)
## rather than reimplementing pattern expansion, so the candidate set this
## module tries can never drift from what `loadLibPattern` itself would have
## tried — same alternation/version-suffix expansion, same first-hit-wins
## ordering.

import std/dynlib as stdDynlib

export stdDynlib.LibHandle, stdDynlib.unloadLib

type
  CandidateAttempt* = object
    ## One failed attempt to load a concrete (post pattern-expansion)
    ## candidate name.
    candidate*: string
      ## The concrete on-disk name tried, e.g. `"libfoo.so.2"`.
    osError*: string
      ## The OS loader's own diagnostic for this attempt: `dlerror()` text
      ## on POSIX (names the missing transitive dependency when that's the
      ## cause — see the module doc), or `FormatMessage`-rendered
      ## `GetLastError()` text on Windows.
    osErrorCode*: int
      ## `GetLastError()` value on Windows; always 0 on POSIX (`dlerror()`
      ## carries no stable numeric code).

when defined(posix) and not defined(nintendoswitch):
  import std/posix

  proc loadOneDetailed(path: string, globalSymbols: bool):
      tuple[handle: LibHandle, osError: string, osErrorCode: int] =
    let flags = if globalSymbols: posix.RTLD_NOW or posix.RTLD_GLOBAL
                else: posix.RTLD_NOW
    let h = posix.dlopen(path.cstring, flags)
    if h.isNil:
      let e = posix.dlerror()
      (LibHandle(nil), (if e.isNil: "" else: $e), 0)
    else:
      (LibHandle(h), "", 0)

elif defined(windows):
  # ANSI (`*A`) Win32 entry points, matching `std/dynlib`'s own choice of
  # `LoadLibraryA` for `loadLib` on this target — no wide-string handling
  # needed, and no behavior change vs. what `loadLibPattern` already did.
  type HMODULE = pointer

  proc winLoadLibraryA(path: cstring): HMODULE
    {.importc: "LoadLibraryA", header: "<windows.h>", stdcall.}
  proc winLoadLibraryExA(path: cstring, hFile: pointer, flags: uint32): HMODULE
    {.importc: "LoadLibraryExA", header: "<windows.h>", stdcall.}
  proc winFreeLibrary(lib: HMODULE): cint
    {.importc: "FreeLibrary", header: "<windows.h>", stdcall.}
  proc winGetLastError(): uint32
    {.importc: "GetLastError", header: "<windows.h>", stdcall.}
  proc winFormatMessageA(flags: uint32, source: pointer, messageId: uint32,
                          languageId: uint32, buffer: cstring, size: uint32,
                          args: pointer): uint32
    {.importc: "FormatMessageA", header: "<windows.h>", stdcall.}

  const
    kFormatMessageFromSystem = 0x00001000'u32
    kFormatMessageIgnoreInserts = 0x00000200'u32
    # RFC 0011 S0a item 5, story (f)/(g) — MEASURED (see the item's report):
    # plain `LoadLibraryA` returns `ERROR_MOD_NOT_FOUND` (126) BOTH for a
    # truly-absent target and for a present target whose transitive
    # dependency is missing — Windows does not distinguish the two in the
    # ordinary failure path. Loading the SAME path with
    # `LoadLibraryExA(path, 0, DONT_RESOLVE_DLL_REFERENCES)` skips import
    # resolution entirely: measured to SUCCEED for the present-target
    # case and FAIL for the truly-absent case, so it cheaply separates
    # them. `dlerror()` on Linux already names the missing dependency
    # directly (see the POSIX branch above) — this preflight is the
    # Windows-only compensation for the asymmetry the RFC calls out.
    kDontResolveDllReferences = 0x00000001'u32
    kErrorModNotFound = 126'u32
      ## The MEASURED code both the truly-absent and the
      ## present-but-missing-dependency cases produce — the only code the
      ## preflight above is worth spending a second Win32 call to
      ## disambiguate.

  proc formatWinError(code: uint32): string =
    ## Renders a `GetLastError()` code via `FormatMessageA` into the
    ## OS-localized diagnostic string, trimming the trailing CRLF
    ## `FormatMessage` appends. Falls back to the bare numeric code if
    ## `FormatMessage` itself can't render it (unregistered code).
    var buf = newString(512)
    let n = winFormatMessageA(kFormatMessageFromSystem or kFormatMessageIgnoreInserts,
                               nil, code, 0, cast[cstring](addr buf[0]),
                               buf.len.uint32, nil)
    if n == 0:
      "Windows error " & $code
    else:
      buf.setLen(n.int)
      while buf.len > 0 and buf[^1] in {'\r', '\n'}:
        buf.setLen(buf.len - 1)
      buf

  proc dontResolveDllReferencesPreflightSaysTargetExists(path: string): bool =
    ## Runs the `DONT_RESOLVE_DLL_REFERENCES` preflight described above and
    ## immediately releases the handle — this call never keeps the library
    ## mapped; it only answers "does the target file itself resolve,
    ## independent of its imports?". A handle from this flag combination
    ## must never be treated as a normal, fully-loaded library (per the
    ## Win32 docs), so it is freed here rather than returned to any caller.
    let h = winLoadLibraryExA(path.cstring, nil, kDontResolveDllReferences)
    result = not h.isNil
    if result: discard winFreeLibrary(h)

  proc loadOneDetailed(path: string, globalSymbols: bool):
      tuple[handle: LibHandle, osError: string, osErrorCode: int] =
    # Win32 `LoadLibrary` has no global/local symbol-visibility knob
    # analogous to POSIX `RTLD_GLOBAL` — accepted for signature parity with
    # the POSIX branch only.
    discard globalSymbols
    let h = winLoadLibraryA(path.cstring)
    if h.isNil:
      let code = winGetLastError()
      var msg = formatWinError(code)
      # RFC 0011 S0a item 5, story (f)/(g): the preflight cannot fire for
      # every failure — only when it usefully adds information beyond what
      # `msg` already says. It's silent (no annotation) when it can't tell
      # us anything the plain error didn't already: a failure code other
      # than the one MEASURED to be ambiguous, or a preflight failure that
      # merely reproduces the original one.
      if code == kErrorModNotFound and dontResolveDllReferencesPreflightSaysTargetExists(path):
        msg.add(" (the file exists and opens independently of its imports " &
                "— a dependency is likely missing, not the library itself)")
      (LibHandle(nil), msg, code.int)
    else:
      (LibHandle(h), "", 0)

else:
  {.error: "softlink/loader: no per-candidate loader implementation for this target".}

proc loadLibPatternDetailed*(pattern: string, globalSymbols = false):
    tuple[handle: LibHandle, attempts: seq[CandidateAttempt]] =
  ## Loads a library matching `pattern`, exactly like `loadLibPattern`
  ## (same candidate expansion, same first-hit-wins ordering) but returns
  ## the OS loader's own diagnostic for every candidate that failed.
  ##
  ## On success, `attempts` is empty: the load succeeded, so an earlier
  ## candidate's failure (when the winning candidate wasn't the first tried)
  ## carries no information a caller needs — see RFC 0011 S0a item 5, story
  ## (d).
  var candidates: seq[string]
  stdDynlib.libCandidates(pattern, candidates)
  var attempts: seq[CandidateAttempt]
  for c in candidates:
    let (handle, err, code) = loadOneDetailed(c, globalSymbols)
    if not handle.isNil:
      return (handle, newSeq[CandidateAttempt](0))
    attempts.add(CandidateAttempt(candidate: c, osError: err, osErrorCode: code))
  (LibHandle(nil), attempts)
