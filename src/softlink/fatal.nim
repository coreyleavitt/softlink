## `softlink/fatal` — RFC 0011 S0b, work item (ii): the fatal-termination
## subsystem behind trusted-wrapper mode (`{.trustedWrappers.}`, `softlink/
## directives`/`src/softlink.nim`'s wrapper-codegen branch, work item (i)).
##
## A trusted wrapper's nil-pointer branch cannot `raise` — the whole point
## of `{.trustedWrappers.}` is a wrapper genuinely `{.raises: [].}`, checked
## by Nim's effect system, not merely documented — so it calls `softlinkFatal`
## instead. `softlinkFatal` writes the full diagnostic story to every sink
## this module owns, then terminates the process immediately, WITHOUT
## running Nim's registered exit procedures (`std/exitprocs.addExitProc`):
## the fatal can fire from inside a foreign C call frame (e.g. a GTK signal
## emission calling back into a trusted wrapper), and running arbitrary
## Nim exit-proc code there — which may itself re-enter the very C library
## whose stack frame is on top of it — would be a second hazard stacked on
## the first. This deliberately mirrors the OS loader's own termination
## semantics for an unresolvable symbol (abrupt, no unwind), while supplying
## the diagnostic detail the raw loader never gives.
##
## Every sink below is RAW OS-level I/O — C `fputs`/`fflush` against the C
## `stderr` stream (via a tiny `{.emit.}`-injected helper, never Nim's
## `system.stderr` object, whose `write`/`writeLine` carry a declared
## `IOError` effect), and on Windows, `OutputDebugStringA` and `MessageBoxW`
## declared directly via `importc` (no `std/winlean`/`std/dynlib` involved).
## A sink implemented through ANY exception-typed Nim I/O would force this
## module into exactly the swallowed-exception-or-internal-cast compromise
## `{.trustedWrappers.}` exists to eliminate: `softlinkFatal` itself, and
## every proc it calls, must be genuinely `{.raises: [].}` all the way down
## — checked by the compiler at every one of these call sites, not merely
## asserted in a comment.
##
## Termination is `_Exit` (C99, `<stdlib.h>`) — NOT `system.quit`, whose own
## documented behavior is to run every proc registered via
## `std/exitprocs.addExitProc` before the process actually exits (exactly
## the hazard this module exists to avoid). `_Exit` bypasses that chain
## entirely: it is a foreign C function Nim's `quit` wrapper never touches,
## so no Nim-level exit-proc bookkeeping runs on the way out.
##
## Reentrancy: `MessageBoxW` pumps a nested Win32 message loop for the
## calling thread for as long as the dialog is open, which can dispatch
## into still-live GTK (or other foreign-library) trampolines and reach a
## SECOND `softlinkFatal` call while the first is still on the stack. An
## atomic compare-and-swap guard (`std/atomics`, this module's only
## dependency beyond raw FFI) ensures only the FIRST caller — thread or
## reentrant call — ever performs diagnostic work; every other caller,
## concurrent or reentrant, skips straight past it. Critically, a losing
## caller does NOT independently call `_Exit` itself: `_Exit` tears down
## the WHOLE process (every thread) immediately and unconditionally, so if
## a losing thread's own `_Exit` won the race to actually run, it could
## kill the process before the WINNING thread's diagnostic write ever
## reaches stderr — silently defeating the entire point of this module. A
## losing caller instead blocks forever (a tight OS-level sleep loop, no
## Nim call surface, no allocation) and lets the winner's own `_Exit`
## eventually tear the process — including the blocked loser thread — down
## once its diagnostic work is complete. This is the one property that
## makes "the diagnostic appears exactly once, and always reaches stderr
## before the process dies" true even under genuine concurrent entry from
## two threads (RFC 0011 S0b's own stated requirement — softlink is a
## general-purpose library, so the guard must hold thread-to-thread, not
## merely reentrantly on one thread the way an oyamel-style UI-thread-only
## invariant would allow).
##
## `-d:softlinkNoFatalDialog` suppresses the `MessageBoxW` leg only — stderr
## and `OutputDebugString` are unaffected — same switch family as
## `-d:softlinkNoDriftRefusal` (`src/softlink.nim`): softlink is
## general-purpose, and a headless Windows service that opts into trusted-
## wrapper mode must not inherit a blocking modal dialog on a background
## thread with nobody to click it.

import std/atomics

{.emit: """/*INCLUDESECTION*/
#include <stdio.h>
#include <stdlib.h>
#if defined(_WIN32)
#include <windows.h>
#else
#include <unistd.h>
#endif

/* RFC 0011 S0b: raw C I/O for the stderr sink -- deliberately NOT routed
 * through Nim's system.stderr (a File whose write/writeLine carry a
 * declared IOError effect that would poison softlinkFatal's own
 * raises: []). fputs/fflush against the C library's own stderr
 * global/macro, resolved by the C compiler in the ordinary way -- taking
 * stderr's address from Nim-visible code is the fragile path some libc
 * implementations don't support; using it directly in a plain C function
 * body, as here, always works. NOTE: no backtick characters anywhere in
 * this emitted string -- Nim's emit pragma treats a backtick-delimited
 * span as a request to interpolate a Nim expression, even inside what
 * reads like a plain C comment, so a stray backtick here breaks the Nim
 * compiler itself (confirmed empirically), not merely the C compile. */
static void softlink_fatal_write_stderr(const char* msg) {
  fputs(msg, stderr);
  fflush(stderr);
}

/* RFC 0011 S0b: the CAS loser's terminal state -- see this module's own
 * top-of-file doc comment for why a losing thread must never call _Exit
 * itself (a race it could win, killing the process before the WINNING
 * thread's diagnostic write ever reaches stderr). Spins forever at low
 * frequency; the winner's own _Exit(1) tears the whole process --
 * including this blocked thread -- down once its diagnostic work
 * completes. No Nim call surface here at all (no allocation, no
 * exception table), so this is trivially outside anything the Nim effect
 * system needs to reason about. */
static void softlink_fatal_block_forever(void) {
  for (;;) {
#if defined(_WIN32)
    Sleep(1000);
#else
    sleep(1);
#endif
  }
}
""".}

proc cWriteStderr(msg: cstring) {.importc: "softlink_fatal_write_stderr", nodecl, raises: [].}
proc cBlockForever() {.importc: "softlink_fatal_block_forever", nodecl, raises: [], noreturn.}
proc cExit(code: cint) {.importc: "_Exit", header: "<stdlib.h>", raises: [], noreturn.}

when defined(windows):
  import std/widestrs

  proc winOutputDebugStringA(s: cstring) {.importc: "OutputDebugStringA",
    header: "<windows.h>", stdcall, raises: [].}
  proc winGetConsoleWindow(): pointer {.importc: "GetConsoleWindow",
    header: "<windows.h>", stdcall, raises: [].}
  when not defined(softlinkNoFatalDialog):
    proc winMessageBoxW(hwnd: pointer, text, caption: WideCString,
      utype: uint32): cint {.importc: "MessageBoxW", header: "<windows.h>",
      stdcall, raises: [].}
    const
      mbIconError = 0x00000010'u32
      mbOk = 0x00000000'u32
      mbSystemModal = 0x00001000'u32
        ## RFC 0011 S0b: `MB_SYSTEMMODAL`, not the plain-modal default — a
        ## fatal firing from an arbitrary foreign C frame (a GTK signal
        ## trampoline, not necessarily the UI thread, and not necessarily
        ## with a well-formed owner window) has no `hwnd` to be modal
        ## AGAINST; system-modal is the one flag guaranteeing the dialog
        ## stays topmost and grabs input regardless of what other windows
        ## this process (or its foreign libraries) currently own. Dialog
        ## modality is called out in the RFC as "a softlink-side detail
        ## decided under its own review" — this is that decision.

    # RFC 0011 S0b, post-ship hardening: `GetConsoleWindow() == NULL` alone
    # is NOT sufficient to conclude "this is an interactive GUI app with
    # nobody watching stderr" — it is ALSO true for a plain CONSOLE-
    # subsystem process running with no interactive window station at all
    # (a Windows Server Core container, a service session, session 0):
    # there, `GetConsoleWindow()` returns NULL not because the app is a GUI
    # app, but because there is no console to attach in the first place.
    # Confirmed the hard way: a console-subsystem `nim c -r` test child run
    # inside this project's own Windows test container hit exactly this —
    # `GetConsoleWindow()` NULL routed it into `MessageBoxW`, which never
    # returns on a non-visible window station (no desktop to paint the
    # dialog on), wedging the process forever. That is not merely a test-
    # harness inconvenience: the identical thing would happen to a real
    # headless Windows SERVICE that adopted `trustedWrappers` without
    # remembering `-d:softlinkNoFatalDialog` — a dialog nobody can ever see
    # blocking termination is strictly worse than no dialog at all, and
    # directly contradicts this module's own reason to exist ("terminate
    # immediately"). The additional, NECESSARY check:
    # `GetProcessWindowStation()` + `GetUserObjectInformationW(...,
    # UOI_FLAGS, ...)`'s `WSF_VISIBLE` bit — set only for an interactive
    # window station (a real desktop session), clear for a service/
    # container/session-0 one. The dialog now fires only when BOTH no
    # console is attached AND the window station is genuinely visible —
    # true GUI-app-on-a-real-desktop is the only case `MessageBoxW` was
    # ever meant to serve here.
    type UserObjectFlags = object
      fInherit: int32   # BOOL
      fReserved: int32  # BOOL
      dwFlags: uint32
    proc winGetProcessWindowStation(): pointer
      {.importc: "GetProcessWindowStation", header: "<windows.h>", stdcall, raises: [].}
    proc winGetUserObjectInformationW(hObj: pointer, nIndex: cint,
      pvInfo: pointer, nLength: culong, lpnLengthNeeded: ptr culong): int32
      {.importc: "GetUserObjectInformationW", header: "<windows.h>", stdcall, raises: [].}
      ## `DWORD`/`LPDWORD` are `unsigned long`/`unsigned long*` in the real
      ## Win32 header (LLP64: `long` stays 32-bit on 64-bit Windows, but is
      ## a DIFFERENT C type than `unsigned int` — Nim's `culong`, not
      ## `uint32`, is what actually matches; confirmed the hard way, a
      ## `uint32`-pointer 5th argument fails with `-Wincompatible-pointer-
      ## types` under mingw gcc, "expected 'LPDWORD' {aka 'long unsigned
      ## int *'} but argument is of type 'NU32 *'").
    const
      uoiFlags = 1'i32
      wsfVisible = 0x0001'u32

    proc winWindowStationIsVisible(): bool {.raises: [].} =
      ## `false` (never show the dialog) on ANY failure path — the
      ## process's own window station handle is nil, or the
      ## `GetUserObjectInformationW` query itself fails — deliberately
      ## fail-SAFE toward "skip the dialog": the cost of wrongly skipping a
      ## legitimate interactive dialog (the diagnostic is still on stderr
      ## and OutputDebugString either way) is trivial next to the cost of
      ## wrongly showing one that can never return, which is exactly the
      ## production hang this check exists to prevent.
      let hStation = winGetProcessWindowStation()
      if hStation.isNil: return false
      var flags: UserObjectFlags
      var needed: culong
      let ok = winGetUserObjectInformationW(hStation, uoiFlags, addr flags,
        culong(sizeof(flags)), addr needed)
      if ok == 0: return false
      (flags.dwFlags and wsfVisible) != 0'u32

var softlinkFatalGuard: Atomic[bool]
  ## RFC 0011 S0b item (ii)(b): the reentrancy guard. `false` (the zero
  ## value) means "no fatal in progress yet" — a fresh process, or (under
  ## `-d:softlinkTesting`) a guard explicitly reset between test cases via
  ## `resetFatalGuardForTest`. Exactly one `compareExchange(expected, true)`
  ## call across the process's entire lifetime observes `expected` still
  ## `false` and thus performs diagnostic work (`fatalCore`'s `result =
  ## true` path); every other call, on any thread, observes `true` and
  ## short-circuits.

proc fatalCore(diagnostic: string): bool {.raises: [].} =
  ## The CAS-guarded diagnostic-work step, shared by `softlinkFatal` (the
  ## real, always-terminates entry point) and, under `-d:softlinkTesting`
  ## only, `softlinkFatalTestEntry` (same production code path, minus the
  ## terminating tail — see that proc's own doc comment for why this
  ## split is the test seam rather than a substitutable hook inside
  ## `softlinkFatal` itself).
  ##
  ## Returns `true` iff THIS call is the one that performed the diagnostic
  ## work (the CAS's winner); `false` means an earlier call — possibly
  ## still in flight on another thread — already claimed the guard, and
  ## this call did nothing.
  var expected = false
  result = softlinkFatalGuard.compareExchange(expected, true)
  if not result:
    return
  cWriteStderr(cstring(diagnostic & "\n"))
  when defined(windows):
    winOutputDebugStringA(cstring(diagnostic))
    when not defined(softlinkNoFatalDialog):
      if winGetConsoleWindow().isNil and winWindowStationIsVisible():
        # RFC 0011 S0b: `MessageBoxW` only when BOTH (a) the process has no
        # attached console (`GetConsoleWindow() == NULL` — a GUI-subsystem
        # process, user32 present even when GTK is not, where stderr has
        # no reader a human will ever see) AND (b) the window station is
        # genuinely interactive/visible (`winWindowStationIsVisible`,
        # above — NOT true in a service/container/session-0 context, where
        # (a) alone is also true but there is no desktop to show a dialog
        # on at all). A console-subsystem process already has the
        # diagnostic on a visible stderr; popping a modal dialog on top of
        # that would be redundant, and would block a process a script or
        # CI runner is watching for a plain exit code. A non-visible
        # window station has NEITHER a console NOR a desktop — condition
        # (a) alone would wrongly route it here, where `MessageBoxW` never
        # returns (confirmed empirically, see `winWindowStationIsVisible`'s
        # own doc comment) — condition (b) is what closes that gap.
        discard winMessageBoxW(nil, newWideCString(diagnostic),
          newWideCString("softlink: fatal error"),
          mbIconError or mbOk or mbSystemModal)

proc softlinkFatal*(diagnostic: string) {.noreturn, raises: [].} =
  ## RFC 0011 S0b: the trusted wrapper's nil-pointer branch calls this
  ## instead of raising `SoftlinkError` — see this module's own top-of-file
  ## doc comment for the full rationale (foreign-C-frame safety, sink list,
  ## termination semantics, and the CAS reentrancy guard).
  ##
  ## `diagnostic` is the SAME text `raiseNotLoaded`/`raiseDriftRefused`
  ## (`src/softlink.nim`) would have put in a raised `SoftlinkError.msg` —
  ## the not-loaded message naming the symbol and library, or the full
  ## drift story where one was recorded (RFC 0011 S0b work item (i)'s own
  ## codegen branch builds this string; this proc has no opinion on its
  ## content beyond writing it verbatim to every sink).
  if fatalCore(diagnostic):
    cExit(1)
  else:
    # This call lost the CAS race — some other call (possibly still
    # in-flight on another thread right now) already claimed the guard and
    # is doing the real diagnostic work. Block rather than independently
    # exiting: see this module's top-of-file doc comment for why an
    # independent `_Exit` here could win the race to tear the process down
    # before the WINNER's diagnostic write ever reaches stderr. The
    # winner's own `cExit(1)` above eventually terminates this blocked
    # thread along with the rest of the process.
    cBlockForever()

when defined(softlinkTesting):
  proc softlinkFatalTestEntry*(diagnostic: string): bool {.raises: [].} =
    ## Test-only seam (RFC 0011 S0b item (ii)(b)) — compiled in ONLY under
    ## `-d:softlinkTesting`, so `softlinkFatal` itself is textually and
    ## behaviorally IDENTICAL in every production build regardless of
    ## whether this proc exists; nothing here substitutes, wraps, or
    ## conditionally branches around anything `softlinkFatal` does.
    ##
    ## Calls the SAME `fatalCore` production code `softlinkFatal` calls —
    ## the CAS guard and every diagnostic sink run for real — and returns
    ## its `firstEntry` result instead of terminating the process, so an
    ## in-process `std/unittest` suite can drive the guard (including
    ## genuine concurrent entry from multiple real OS threads) and observe
    ## the outcome directly, rather than only ever seeing it via a
    ## subprocess's exit code and captured stderr.
    fatalCore(diagnostic)

  proc resetFatalGuardForTest*() {.raises: [].} =
    ## Test-only: force the guard back to its pristine (`false`) state
    ## within the SAME process. The guard is a genuine module-level
    ## singleton by design — it must survive across every real call site
    ## for the lifetime of a real process — so an in-process suite that
    ## wants to exercise "first entry" more than once per process needs an
    ## explicit reset between cases; a real trusted-wrapper deployment
    ## never calls this (or even sees it: it does not exist outside
    ## `-d:softlinkTesting` builds).
    softlinkFatalGuard.store(false)
