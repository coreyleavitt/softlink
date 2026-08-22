## RFC 0011 S0a item 6: the unverified-symbols audit hint collapses every
## block-defaulted proc into ONE summary line ("N symbols, block-level
## reason: ...") instead of one line each — the whole point of the
## block-level directive is to stop a many-declaration consumer from
## repeating the identical justification string verbatim per proc. A proc
## with its OWN explicit {.noverify: "...".} keeps its individual line,
## unaffected: `foo_a`/`foo_b` inherit the block default and collapse;
## `foo_own` carries its own justification and stays listed by name. Run
## by the nimble test task, which compiles this file and greps the
## compiler output for the collapsed line and the individual line —
## plainly and with -d:softlinkStrictVerify.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "libnvblockfoo.so":
  noverify: "no public header for these"
  proc foo_a(): cint {.cdecl.}
  proc foo_b(): cint {.cdecl.}
  proc foo_own(): cint {.cdecl, noverify: "its own, separate reason".}
