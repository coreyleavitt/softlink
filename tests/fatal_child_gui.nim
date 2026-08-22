## RFC 0011 S0b, work item (ii)(d): the Windows GUI-subsystem leg of the
## fatal subsystem's subprocess pins.
##
## *** ENVIRONMENT REQUIREMENT — READ BEFORE RUNNING ANYWHERE ELSE ***
## This fixture is compiled WITHOUT `-d:softlinkNoFatalDialog` ON PURPOSE
## and is therefore SAFE TO RUN ONLY where the process's window station is
## NON-VISIBLE (a service session, a container, session 0 — this project's
## own Windows test container). On a REAL interactive desktop — including a
## GitHub-hosted Windows CI runner's own autologon session, which runs an
## interactive, VISIBLE window station exactly like a human's desktop — this
## fixture pops a genuine, un-clickable `MessageBoxW` and hangs forever. That
## is not a hypothetical: it happened twice during this feature's
## development, in two different ways:
##   1. Running this exact fixture the FIRST time (in this project's own
##      Windows container, whose window station is non-visible) exposed that
##      `GetConsoleWindow() == NULL` alone was being treated as "show the
##      dialog" — wrong, since a non-visible window station also has no
##      console, and `MessageBoxW` never returns there either. Fixed by
##      adding the window-station-visibility check
##      (`winWindowStationIsVisible`, `softlink/fatal.nim`).
##   2. AFTER that fix, `nimble test` (the CROSS-PLATFORM gate, which this
##      fixture is NOT part of — see below) still hung on a real GitHub
##      Windows CI runner, because that runner's window station IS visible
##      (an interactive autologon session) — indistinguishable, by any
##      environment check this module can make, from a genuine human
##      desktop. That incident is why `tests/tfatal.nim`'s in-process suite
##      no longer touches real sink I/O at all, and why every subprocess
##      child `tests/tfatal.nim` compiles (via `compileChild`) now forces
##      `-d:softlinkNoFatalDialog` unconditionally. THIS fixture is the one
##      deliberate exception, precisely because it exists to prove the
##      window-station gate itself works — which requires the dialog leg to
##      be genuinely compiled in.
##
## Consequently: this fixture must NEVER be added to `task test` (the
## cross-platform gate `nimble test` runs on every CI matrix leg, including
## real interactive-desktop Windows runners) — it is compiled and run ONLY
## by `task testWindows` (softlink.nimble), which this project's own runbook
## always drives against the container image
## `ghcr.io/coreyleavitt/nim:2.2.10-mingw` (a non-visible window station by
## construction), never against a bare/interactive Windows host.
##
## Compiled with `--app:gui` (no automatically-allocated console —
## `GetConsoleWindow()` returns NULL). The whole point of this fixture is
## proving that even with the `MessageBoxW` leg fully compiled IN, the
## process still terminates promptly in a non-interactive context, because
## `winWindowStationIsVisible()` is false there — NOT because the dialog leg
## was compiled out. The build-wide override itself (`-d:softlinkNoFatalDialog`
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
