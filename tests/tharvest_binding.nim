## RFC-0001 SS4 B.2/B.3 slice B3: the harvester's integration-test binding
## fixture. Bound against `tests/corpus`'s `corpuslib_*` symbols (slice
## B3a; see tests/corpus/README.md for the full classification narrative),
## NOT the suite's own `tests/testlib.h` — distinct symbol names mean an
## accidental cross-resolution between the two corpora could never
## silently mask a bug.
##
## `header: "testlib.h"` is deliberately BARE (no `tests/` prefix): the
## harvester prepends each corpus version directory via the toolchain's
## include-dir flag, and each `tests/corpus/<version>/` snapshot contains
## exactly one file also named `testlib.h` — the bare name is what lets the
## prepended `-I`/`/I` actually SHADOW anything else on the include path
## (see tests/corpus/README.md).
##
## Four procs, one per corpus fixture symbol plus one proving the
## `{.prototype.}`-only skip path (RFC-0001 SS4 B.2: corpus-invariant,
## never probed):
##   - `corpuslib_stable`    pinned to its TRUE, unchanging signature.
##   - `corpuslib_changed`   pinned to its 1.0.0 signature on purpose — the
##     2.0.0 header changes the return type (only — see
##     tests/corpus/README.md for why the drift is return-type-only).
##   - `corpuslib_added`     pinned to its 2.0.0 signature — 1.0.0's header
##     never declares it at all.
##   - `corpuslib_protoonly` prototype-only (no `header`): the harvester
##     must skip it, never probe it against any corpus version.
##
## NOT compiled by the regular `nimble test` suite — this is B3's own
## integration fixture, driven by tests/tharvest.nim via a
## `-d:softlinkDumpProbes=<dir>` dump exactly like a real harvest would be.
import softlink

dynlib "libcorpuslib.so":
  proc corpuslib_stable(a: cint, b: cint): cint {.cdecl, header: "testlib.h".}
  proc corpuslib_changed(a: cint): cint {.cdecl, header: "testlib.h".}
  proc corpuslib_added(x: cint): cint {.cdecl, header: "testlib.h".}
  proc corpuslib_protoonly(): cint
    {.cdecl, prototype: "int corpuslib_protoonly(void)".}
