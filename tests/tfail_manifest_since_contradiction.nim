## RFC-0001 §B.5/§C.2, slice B6a: `{.since: "x.y.z".}` claims a symbol
## exists from that version onward — a lower bound only. `tests/
## manifests/testlib_since.compat.json` records `testlib_add` as
## `absent` through 2.0.0 (exclusive) and `verified` from 2.0.0 onward;
## claiming `since: "1.0.0"` contradicts that (the header says it isn't
## there yet at 1.0.0). This is a hard error with NO escape hatch, and
## the message must include the corrected bound (2.0.0). Run by the
## nimble test task, which expects compilation to fail with "corrected
## lower bound is 2.0.0".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "libtestlib.so":
  compatManifest "manifests/testlib_since.compat.json"
  proc testlib_add(a: cint, b: cint): cint {.cdecl, since: "1.0.0", header: "tests/testlib.h".}
