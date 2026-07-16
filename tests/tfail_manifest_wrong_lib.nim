## RFC-0001 §B.3/§B.5, slice B6a: `manifest.lib` must equal this block's
## own `toLowerAscii(baseName)` — wrong-file paste protection.
## `tests/manifests/testlib_wronglib.compat.json` has `"lib":
## "notthislib"`, but this block's library is "libtestlib.so" (base
## "testlib"). Run by the nimble test task, which expects compilation to
## fail with "is for library 'notthislib'".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "libtestlib.so":
  compatManifest "manifests/testlib_wronglib.compat.json"
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
