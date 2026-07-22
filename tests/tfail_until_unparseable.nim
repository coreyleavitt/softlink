## RFC-0002 §4.1/§6, slice A1: `{.until: "...".}` must `parseVersion`
## successfully (`softlink/versions`) — an exclusive upper bound that can't
## even be compared is worse than none. Mirrors `tfail_since_unparseable.nim`
## exactly: no `compatManifest` directive is needed for this check; the
## pragma is validated at parse time, independent of whether a manifest is
## attached. Run by the nimble test task, which expects compilation to fail
## with "does not parse as a version".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  proc testlib_add(a: cint, b: cint): cint {.cdecl, until: "...", header: "tests/testlib.h".}
