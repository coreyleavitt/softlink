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
  cpmVerified     ## "2.0.0" — before either mismatch interval begins
  cpmMismatch     ## "4.0.0" — in-corpus, inside both testlib_gated's and
                  ## testlib_magic's mismatch intervals — refusal would fire
                  ## here if enabled; `refuse = false` must suppress it
  cpmOutOfCorpus  ## RFC-0002 §4.4/§6, slice C4b: "9.9.9" — not literally
                  ## harvested, and decisively at-or-above testlib_magic's
                  ## own DECLARED `until` ("4.0.0", added alongside this
                  ## mode) — the declared-bound refusal fragment (the
                  ## `atOutOfCorpus` site) would ALSO fire here if enabled;
                  ## `refuse = false` must suppress this path too, not just
                  ## the attested-mismatch one `cpmMismatch` exercises.
  cpmAttestedAbsentBound ## RFC-0002 §4.4, code-review finding CR1-1: "3.0.0"
                  ## — an ATTESTED (in-corpus) probe, at-or-above
                  ## testlib_noop's own declared `until` ("3.0.0").
                  ## testlib_noop is bound REQUIRED and is deliberately
                  ## ABSENT from this file's manifest (see
                  ## testlib_refuse_false.tmpl.json's `symbols`) — the exact
                  ## CR1-1 shape — but `refuse = false` on this block's own
                  ## `compatManifest` directive means NEITHER candidate list
                  ## (old or CR1-1's new manifest-absent subset) is ever
                  ## populated, so this proves the escape hatch suppresses
                  ## the new attested-site emission too, not just the two
                  ## pre-existing sites.

var corpusProbeMode = cpmVerified

dynlib "testlib":
  compatManifest("manifests/testlib_refuse_false.compat.json", refuse = false)
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
  # RFC-0002 §4.4/§6, slice C4c: `since`/`until` added here (matching the
  # manifest's own mismatch onset, "4.0.0", same fixture convention as
  # `testlib_magic` below) — closes the required-flavor gap in THIS file's
  # `refuse = false` coverage: without a declared bound, testlib_gated
  # (REQUIRED) was never a declared-bound-refusal candidate at all, so
  # `cpmOutOfCorpus` couldn't prove `refuse = false` also suppresses C4c's
  # required-symbol unwind (only the ATTESTED path, at `cpmMismatch`, was
  # exercised for this symbol before).
  # RFC-0002 §4.1/§5/§6, slice D1: `until` requires `verifyWhen` — gated on
  # `TESTLIB_VERSION < 99`, trivially true under the header's real default
  # `TESTLIB_VERSION == 1`, so verification stays LIVE; unrelated to this
  # file's own "4.0.0"-shaped `since`/`until` bound.
  proc testlib_gated(): cint {.cdecl, header: "tests/testlib.h",
    since: "1.0.0", until: "4.0.0", verifyWhen: "TESTLIB_VERSION < 99".}
  # RFC-0002 §4.4/§6, slice C4b: `since`/`until` added here (matching the
  # manifest's own mismatch onset, "4.0.0", by fixture convention like
  # every other bounded-symbol fixture in this suite) — needed so
  # `cpmOutOfCorpus` has a declared bound to test the escape hatch
  # against; `refuse = false` must suppress refusal derived from this
  # bound exactly as it suppresses the attested-fact-derived kind.
  # RFC-0002 §4.1/§5/§6, slice D1: same D1 gate as testlib_gated above.
  proc testlib_magic(): cint {.cdecl, optional, header: "tests/testlib.h",
    since: "1.0.0", until: "4.0.0", verifyWhen: "TESTLIB_VERSION < 99".}
  proc testlib_future(): cint {.cdecl, optional, header: "tests/testlib.h".}
  # RFC-0002 §4.4, code-review finding CR1-1: testlib_noop — REQUIRED,
  # bounded, and deliberately ABSENT from this file's manifest (unlike
  # testlib_gated/testlib_magic above, both listed there). Always present
  # in libtestlib.so, so only the CR1-1 attested-path declared-bound check
  # (or its absence) determines whether it dispatches at `cpmAttestedAbsentBound`.
  proc testlib_noop() {.cdecl, header: "tests/testlib.h",
    since: "1.0.0", until: "3.0.0", verifyWhen: "TESTLIB_VERSION < 99".}
  versionProbe:
    case corpusProbeMode
    of cpmVerified: "2.0.0"
    of cpmMismatch: "4.0.0"
    of cpmOutOfCorpus: "9.9.9"
    of cpmAttestedAbsentBound: "3.0.0"

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

  # RFC-0002 §4.4/§6, slice C4b/C4c: the declared-bound refusal fragment
  # (the `atOutOfCorpus` site) would ALSO fire here for BOTH bounded
  # symbols — testlib_magic (OPTIONAL, C4b) and testlib_gated (REQUIRED,
  # C4c: this would unwind the WHOLE load) — since both declare `until:
  # "4.0.0"`, decisively below "9.9.9", if refusal were enabled.
  # `refuse = false` must suppress it for EITHER pragma kind, exactly like
  # it suppresses the attested-mismatch kind above.
  test "out-of-corpus, probe above the declared until: refuse = false suppresses declared-bound refusal for both required and optional":
    corpusProbeMode = cpmOutOfCorpus
    unloadTestlib()
    let r = loadTestlib()
    check r.kind == lrOkPartial
    check r.missing == @["testlib_future"]
    check "testlib_magic" notin r.missing

    check testlibLoaded()
    check testlib_gated() == 21         # required, declared-bound-eligible, still callable
    check testlib_magicAvailable()
    check testlib_magic() == 42

    let c = testlibCompat()
    check c.attestation == atOutOfCorpus
    check c.runtimeVersion == "9.9.9"
    check not c.missingReasons.anyIt(it.reason == mrDriftRefused)
    check not c.probeNotComparable

  # RFC-0002 §4.4, code-review finding CR1-1: the ATTESTED-path declared-
  # bound refusal for a manifest-absent bounded proc (testlib_noop, added
  # above) must ALSO be suppressed by `refuse = false` — the escape hatch
  # gates candidate-list POPULATION itself (`driftRefusalEnabled`), so the
  # CR1-1 fix's manifest-absent subset is empty here by construction, same
  # as the two pre-existing sites.
  test "attested probe at-or-above a manifest-absent bounded proc's declared until: refuse = false suppresses the CR1-1 attested-site check too":
    corpusProbeMode = cpmAttestedAbsentBound
    unloadTestlib()
    let r = loadTestlib()
    check r.kind == lrOkPartial
    check r.missing == @["testlib_future"]
    check testlibLoaded()
    testlib_noop()
    let c = testlibCompat()
    check c.attestation == atAttested
    check c.runtimeVersion == "3.0.0"
    check not c.missingReasons.anyIt(it.reason == mrDriftRefused)
