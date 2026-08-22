## RFC 0011 S0b, work item (ii)(d): the Windows GUI-subsystem leg of the
## fatal subsystem's subprocess pins — AND the regression pin for the
## window-station wedge discovered running this exact leg the first time
## (see `softlink/fatal.nim`'s `winWindowStationIsVisible` doc comment for
## the full incident writeup).
##
## Compiled with `--app:gui` (no automatically-allocated console —
## `GetConsoleWindow()` returns NULL) and DELIBERATELY WITHOUT
## `-d:softlinkNoFatalDialog`: the whole point of this fixture, post-fix, is
## proving that even with the `MessageBoxW` leg fully compiled IN, the
## process still terminates promptly in a non-interactive context (a
## Windows Server Core / container / session-0 window station), because
## `winWindowStationIsVisible()` is false there — NOT because the dialog
## leg was compiled out. Before the fix, `GetConsoleWindow() == NULL` alone
## routed here into `MessageBoxW`, which never returns on a non-visible
## window station (no desktop to paint the dialog on) — this fixture wedged
## the FIRST real run of `task testWindows` for exactly that reason.
##
## Windows-only; compiled and run by `task testWindows` (softlink.nimble),
## which passes `--app:gui` only (no `-d:softlinkNoFatalDialog` — see
## above). The build-wide override itself (`-d:softlinkNoFatalDialog`
## compiling the `MessageBoxW` leg out of the generated C entirely,
## independent of any runtime window-station check) is pinned separately by
## `task testWindows`'s own compile-time C-inspection check.
##
## Standard-handle redirection (stdout/stderr piped by the parent via
## `CreateProcess`'s `STARTUPINFO`) works identically regardless of
## subsystem — GUI-subsystem only changes whether Windows auto-allocates a
## VISIBLE console window, not whether inherited/redirected stdio handles
## work — so the parent can still assert on captured stderr content here,
## same as the console-subsystem legs; only `OutputDebugString`'s own
## content is unassertable without a debugger attached (noted, not pinned,
## per the RFC's own allowance for this leg).
import softlink/fatal

echo "gui child: about to call softlinkFatal"
softlinkFatal("gui-subsystem fatal diagnostic")
echo "gui child: UNREACHABLE"
