## RFC 0011 S0a item 4, deliverable 3: statement pass-through is a `dynlib`-
## only feature. `verifyProcs` exists solely to verify header signatures —
## no loading, no wrappers, no runtime footprint, nothing a `type`/`const`
## section or a helper proc could usefully attach to — so `collectVProcs`
## keeps its narrower, unrelaxed "every statement must be a proc
## declaration" rule (`isCompatManifestCall`/`isVersionMacrosCall`
## directives excepted, same as always). Run by the nimble test task, which
## expects compilation to fail with "verifyProcs body must contain only
## proc declarations".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

verifyProcs:
  type Foo = distinct cint
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
