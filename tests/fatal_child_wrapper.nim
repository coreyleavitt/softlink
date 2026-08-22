## RFC 0011 S0b, work item (i)(g): the subprocess child fixture behind
## `tests/tfatal.nim`'s pin of the trusted wrapper's nil-pointer branch,
## end to end through REAL wrapper-codegen (`src/softlink.nim`'s
## `trustedWrappers` branch), not `softlink/fatal` in isolation
## (`tests/fatal_child_basic.nim` already covers that). Deliberately never
## calls `loadTestlib()` — the block's function pointers stay nil — so
## calling the trusted wrapper hits its nil branch, which must call
## `softlinkFatal` with the SAME "not loaded" diagnostic text
## `raiseNotLoaded` would have put in a raised `SoftlinkError.msg` for an
## untrusted wrapper, naming both the C symbol and the library pattern.
##
## Needs `tests/testlib.h` at COMPILE time only (header verification) —
## `libtestlib.so`/`.dylib`/`.dll` itself is never touched at runtime,
## since `loadTestlib()` is never called; compiled with `--passC:-I.` from
## the repo root, same as every other `mcBase`-style fixture in this repo.
##
## Compiled WITHOUT `-d:softlinkTesting` — production `softlinkFatal` — and
## WITH `-d:softlinkNoFatalDialog` (`tests/tfatal.nim`'s `compileChild`
## adds it unconditionally, for every child it builds; see that proc's own
## doc comment for why). NOT run directly by `nimble test`; `tests/
## tfatal.nim` compiles and runs this as a subprocess and inspects its
## captured stderr and exit code.
import std/exitprocs
import softlink

when defined(windows):
  const TestLib = "testlib.dll"
elif defined(macosx):
  const TestLib = "libtestlib.dylib"
else:
  const TestLib = "libtestlib.so"

dynlib TestLib:
  trustedWrappers: "fatal_child_wrapper.nim fixture — deliberately never loaded"
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}

addExitProc(proc() = echo "SENTINEL_EXITPROC_RAN")
echo "child: about to call trusted wrapper without loading first"
discard testlib_add(2, 3)
echo "child: UNREACHABLE"
