## RFC-0001 §4 B.2: `-d:softlinkProbeExistence` set without
## `-d:softlinkProbeOnly=<CName>` naming a real symbol is a meaningless
## probe configuration and must be a clear macro-expansion-time error, not
## a silent compile as some other mode. Run by the nimble test task under
## TWO define combinations against this SAME fixture:
##   - `-d:softlinkProbeExistence` alone (softlinkProbeOnly unset/"")
##   - `-d:softlinkProbeExistence -d:softlinkProbeOnly=-` (the sentinel,
##     which selects "no symbol", not a real one)
## Both must fail with softlink's own diagnostic (grepped, like every other
## macro-error fixture in this suite — not `expectCompileFailure`, since
## this IS softlink's own fixed string, unlike a C-compiler diagnostic).
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "libtestlib.so":
  proc testlib_noop() {.cdecl, header: "tests/testlib.h".}
