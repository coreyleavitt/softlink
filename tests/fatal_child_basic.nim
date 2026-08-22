## RFC 0011 S0b, work item (ii)(a): the subprocess child fixture behind
## `tests/tfatal.nim`'s "diagnostic on stderr, sentinel absent, nonzero
## exit, no exit procs run" pin. Registers a `std/exitprocs.addExitProc`
## handler that prints a sentinel to STDOUT (so the parent can assert its
## ABSENCE without confusing it with the diagnostic, which `softlinkFatal`
## writes to STDERR), then calls `softlinkFatal` directly — no `dynlib`
## block, no wrapper codegen, just the fatal subsystem itself in isolation
## (work item (i)'s wrapper-codegen branch gets its OWN dedicated fixture,
## `tests/fatal_child_wrapper.nim`, since that exercises different
## machinery). Compiled WITHOUT `-d:softlinkTesting` — this is production
## `softlinkFatal`, the same one a real trusted wrapper's nil branch calls
## — and WITH `-d:softlinkNoFatalDialog` (`tests/tfatal.nim`'s
## `compileChild` adds it unconditionally): this fixture runs as part of
## the cross-platform `nimble test` gate, which includes real interactive-
## desktop Windows CI runners, so it must be provably unable to open a
## dialog regardless of environment — see `compileChild`'s own doc comment
## for the incident that made this non-negotiable.
##
## NOT run directly by `nimble test`; `tests/tfatal.nim` compiles and runs
## this as a subprocess and inspects its captured streams + exit code.
import std/exitprocs
import softlink/fatal

const sentinel = "SENTINEL_EXITPROC_RAN"
const diagnostic = "child fatal message naming a fictitious symbol foo_bar_baz"

addExitProc(proc() = echo sentinel)
echo "child: about to call softlinkFatal"
softlinkFatal(diagnostic)
echo "child: UNREACHABLE"
