## RFC-0001 §C.3, slice C4c — TDD suite item 5: `compatManifest(..., refuse
## = false)` — the binding-author escape hatch (RFC §C.3: "a library the
## author knows is locally patched"). Report-only mode: BOTH the required
## unwind (C4c) and the optional re-nil (C4b) must be disabled for this
## block — proving the `refuse` gate threads into C4b's existing mechanism
## too (its own implementer left this unimplemented deliberately; see the
## C4c slice brief).
##
## Its own module (separate `dynlib` block on the same underlying
## `libtestlib.so`, per the duplicate-block guard's per-module scoping) —
## `testlib_gated` bound REQUIRED (mirrors `tests/tcompat_drift_required.nim`)
## and `testlib_magic` bound OPTIONAL (a symbol genuinely present in
## `libtestlib.so`, see `tests/testlib.c`), both carrying a `mismatch` fact
## from "4.0.0" onward — proving refusal is suppressed for EITHER pragma
## kind. `testlib_future` (optional, genuinely never implemented) stays in
## the mix so a real `lrOkPartial` for honest absence remains observable
## and distinguishable from drift refusal (which never fires here at all).
import std/[unittest, sequtils]
import softlink

type CorpusProbeMode = enum
  cpmVerified   ## "2.0.0" — before either mismatch interval begins
  cpmMismatch   ## "4.0.0" — in-corpus, inside both testlib_gated's and
                ## testlib_magic's mismatch intervals — refusal would fire
                ## here if enabled; `refuse = false` must suppress it

var corpusProbeMode = cpmVerified

dynlib "testlib":
  compatManifest("manifests/testlib_refuse_false.compat.json", refuse = false)
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
  proc testlib_gated(): cint {.cdecl, header: "tests/testlib.h".}
  proc testlib_magic(): cint {.cdecl, optional, header: "tests/testlib.h".}
  proc testlib_future(): cint {.cdecl, optional, header: "tests/testlib.h".}
  versionProbe:
    case corpusProbeMode
    of cpmVerified: "2.0.0"
    of cpmMismatch: "4.0.0"

suite "Drift refusal disabled per-block (RFC-0001 C4c) — compatManifest(refuse = false)":
  test "mismatch probe mode: neither the required nor the optional drifted symbol is refused":
    corpusProbeMode = cpmMismatch
    unloadTestlib()
    let r = loadTestlib()
    # Only the genuinely-absent optional symbol (testlib_future) may appear
    # missing — a drift-refused entry would ALSO make this lrOkPartial, so
    # the real assertion is on `missing`'s CONTENTS, not just the kind.
    check r.kind == lrOkPartial
    check r.missing == @["testlib_future"]
    check "testlib_gated" notin r.missing
    check "testlib_magic" notin r.missing

    check testlibLoaded()
    check testlib_gated() == 21          # required, drifted, still callable
    check testlib_magicAvailable()       # optional, drifted, still available
    check testlib_magic() == 42          # and still callable

    let c = testlibCompat()
    check c.attestation == atAttested
    check c.runtimeVersion == "4.0.0"
    check not c.missingReasons.anyIt(it.reason == mrDriftRefused)
