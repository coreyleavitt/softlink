## RFC-0002 §4.1/§5/§6, slice D1: `{.until.}` REQUIRES `{.verifyWhen.}` —
## unconditionally, manifest or no manifest. Without a gate, verification
## unconditionally asserts the DECLARED signature against whatever header is
## installed, which is wrong once a header new enough to have already
## drifted past `until` is installed (RFC-0002 §5's whole rationale for the
## compile-time gate). No `compatManifest` is attached here — D1 fires from
## the pragma alone, independent of any manifest cross-check (that's
## `checkUntil`/Check 6b's separate, manifest-gated job). Run by the nimble
## test task, which expects compilation to fail with "requires a
## {.verifyWhen.} gate".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  proc testlib_add(a: cint, b: cint): cint
    {.cdecl, until: "99.0.0", header: "tests/testlib.h".}
