## RFC 0011 S0b, work item (ii)(b): the subprocess child fixture behind
## `tests/tfatal.nim`'s "the diagnostic appears exactly once when the fatal
## path is entered twice" pin — two real OS threads racing into
## `softlinkFatal` concurrently. The in-process suite (same test file, under
## `-d:softlinkTesting`) already exercises the CAS guard's exactly-one-
## winner property directly via `softlinkFatalTestEntry`; this fixture pins
## the END-TO-END behavior a real deployment would see: the process
## terminates exactly once, with exactly one diagnostic on stderr, never
## zero (a hang) and never two (both threads doing full diagnostic work).
##
## Compiled WITHOUT `-d:softlinkTesting` — production `softlinkFatal` on
## both threads. NOT run directly by `nimble test`; `tests/tfatal.nim`
## compiles and runs this as a subprocess and inspects its captured stderr
## (counting occurrences of each diagnostic) and exit code.
import softlink/fatal

proc worker1() {.thread.} =
  softlinkFatal("RACE_DIAGNOSTIC_ONE")

proc worker2() {.thread.} =
  softlinkFatal("RACE_DIAGNOSTIC_TWO")

var t1, t2: Thread[void]
createThread(t1, worker1)
createThread(t2, worker2)
joinThreads(t1, t2)
echo "UNREACHABLE: both threads returned from softlinkFatal without the process terminating"
