## RFC-0001 §B.5/§C.2, slice B6a: `{.since: "...".}` must `parseVersion`
## successfully (`softlink/versions`) — a lower bound that can't even be
## compared is worse than none. No `compatManifest` directive is needed
## for this check; the pragma is validated at parse time, independent of
## whether a manifest is attached. Run by the nimble test task, which
## expects compilation to fail with "does not parse as a version".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "libtestlib.so":
  proc testlib_add(a: cint, b: cint): cint {.cdecl, since: "...", header: "tests/testlib.h".}
