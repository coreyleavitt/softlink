## RFC-0001 §C.3, slice C4c — TDD suite items 1-4 and 6: drift refusal for a
## REQUIRED symbol. Unlike `tests/tcompat_report_manifest.nim` (C4b's
## module, which binds `testlib_gated` OPTIONAL), this file binds the same
## underlying `libtestlib.so` symbol REQUIRED, in its own module — the
## duplicate-block guard (#14) is per-module-scope, not global, so this is
## legal (see that file's own doc comment for the same reasoning).
##
## `tests/manifests/testlib_drift_required.tmpl.json` gives `testlib_gated`
## the identical fact shape C4b's own fixture uses for the same symbol
## (`verified` through "4.0.0", `mismatch` from "4.0.0" onward) — the ONLY
## difference this slice's behavior depends on is that the proc is bound
## REQUIRED here, so a hit unwinds the WHOLE load (library unloaded, handle
## nil, `lrSymbolNotFound`) rather than re-nilling one pointer.
##
## Item 6 (`-d:softlinkNoDriftRefusal`, the build-wide downstream-consumer
## override): this SAME file is compiled and run a SECOND time by the
## nimble task with that define set. `driftRefusalOverridden` below is a
## compile-time-folded `const` (not a `when`, so both runs share one test
## body) that flips the one assertion whose outcome the define changes —
## every other test in this file is unaffected by the define (their probe
## modes never land inside `testlib_gated`'s mismatch interval in a way
## refusal would otherwise touch), so they run byte-identically under both
## invocations.
import std/[unittest, sequtils, strutils]
import softlink

const driftRefusalOverridden = defined(softlinkNoDriftRefusal)
  ## RFC-0001 §C.3: "downstream consumer... the build-wide
  ## -d:softlinkNoDriftRefusal" escape hatch. Folded to a plain compile-time
  ## bool (not gating a `when` block) so the SAME test source expresses
  ## "refusal fires" vs. "refusal is overridden" as one conditional value,
  ## proven byte-identical to `defined()` at macro-expansion time inside
  ## `dynlib` itself — see `src/softlink.nim`'s `softlinkNoDriftRefusal`
  ## const doc comment for why macro-time `defined()` reliably sees this
  ## build-wide define (same single-compiler-invocation reasoning already
  ## established by `softlinkStrictVerify`/`softlinkProbeOnly`/
  ## `softlinkProbeExistence`).

type CorpusProbeMode = enum
  cpmVerified     ## "2.0.0" — testlib_gated verified here, no drift
  cpmMismatch     ## "4.0.0" — in-corpus, testlib_gated's mismatch interval
                  ## covers here: REQUIRED refusal fires (unless overridden)
  cpmMismatchAbove ## "5.0.0" — RFC-0002 §6, slice C3b: a SECOND in-corpus
                  ## (attested) point, still inside testlib_gated's
                  ## unbounded mismatch interval, strictly above its
                  ## declared `until` ("4.0.0"). Proves the attested
                  ## refusal mechanism (keyed on the manifest's OWN
                  ## `fkMismatch` fact, per §4.4) fires identically here as
                  ## at cpmMismatch — it is NOT re-deriving anything from
                  ## the declared bound.
  cpmOutOfCorpus  ## "9.9.9" — not literally harvested, so the ATTESTED
                  ## mechanism (keyed on the manifest's `fkMismatch` fact)
                  ## never runs here (RFC-0001 §C.3 policy) — but
                  ## testlib_gated's own DECLARED bound (`until: "4.0.0"`)
                  ## is decisively below "9.9.9", so RFC-0002 §4.4's
                  ## declared-bound refusal (slice C4c, required flavor)
                  ## fires instead and unwinds the whole load
  cpmAttestedAbsentBoundHit ## "3.0.0" — RFC-0002 §4.4, code-review finding
                  ## CR1-1: an ATTESTED (literally harvested) corpus point,
                  ## at-or-above testlib_noop's own declared `until`
                  ## ("3.0.0") — testlib_noop is absent from this file's
                  ## manifest entirely, so `checkUntil` never validated it
                  ## and the attested-mismatch loop (keyed on manifest
                  ## facts) has nothing to key off; only the CR1-1 fix's
                  ## declared-bound check on manifest-ABSENT procs can
                  ## refuse it here. testlib_gated's own manifest-fact
                  ## mismatch interval doesn't start until "4.0.0", so it
                  ## stays safe at this probe (no interference).
  cpmAttestedAbsentBoundOk ## "1.0.0" — control: same manifest-absent
                  ## testlib_noop, probed INSIDE its declared window
                  ## (`[1.0.0, 3.0.0)`) — must load normally.
  cpmOutOfCorpusBelowSince ## "0.5.0" — code review CR1-8/cell 1(a): the
                  ## MANIFEST-ATTACHED `atOutOfCorpus` site's BELOW-`since`
                  ## shape. Not literally harvested (the corpus only lists
                  ## "1.0.0".."5.0.0"), and decisively BELOW testlib_gated's
                  ## own declared `since` ("1.0.0") — the mirror image of
                  ## `cpmOutOfCorpus` above (which hits the same proc's
                  ## `until` leg instead). testlib_gated is declared before
                  ## testlib_noop (also since/until-bounded, required), so
                  ## "first hit wins" required-then-declaration-order still
                  ## lands on testlib_gated here, exactly like the
                  ## above-until case — this proves the since leg refuses
                  ## identically to the until leg at this shared call site,
                  ## not merely that SOME candidate refuses.
  cpmOutOfCorpusTie ## "3.0.0-rc1" — code review CR1-8/cell 1(b): the
                  ## MANIFEST-ATTACHED `atOutOfCorpus` site's boundary-TIE
                  ## shape (the `evaluateBoundRefusal`/`compareToBound`
                  ## "numeric prefix ties the bound, alpha tail present ->
                  ## not comparable, never refuse" case). Not literally
                  ## harvested (the corpus lists the bare "3.0.0", never
                  ## "3.0.0-rc1"), so this is out-of-corpus; its numeric
                  ## prefix ties testlib_noop's declared `until` ("3.0.0")
                  ## exactly. Every OTHER bound in this block (testlib_gated's
                  ## `since`/`until`) decides decisively at "3.0.0" (neither
                  ## ties), so this probe isolates the tie to testlib_noop's
                  ## `until` leg alone — the load must proceed normally with
                  ## `probeNotComparable == true`, mirroring
                  ## `tests/test_softlink.nim`'s `pmTieUntil` case for the
                  ## manifest-LESS `atNoManifest` site.

var corpusProbeMode = cpmVerified

dynlib "testlib":
  compatManifest "manifests/testlib_drift_required.compat.json"
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
  # testlib_gated: REQUIRED here (a separate module from C4b's own binding,
  # which binds the identical underlying .so symbol `optional`) — RFC-0001
  # §C.3/§9 slice C4c: present in libtestlib.so, but the manifest records a
  # mismatch interval starting at "4.0.0" — a hit must unwind the WHOLE
  # load (library unloaded, handle nil), not merely re-nil one pointer.
  # RFC-0002 §4.4/§6, slice C3b: `since`/`until` added here — a `[since,
  # until)`-bounded declaration coexisting with an ATTESTED-refusal
  # fixture. `until: "4.0.0"` matches the manifest's own drift onset
  # EXACTLY (its `mismatch` fact begins at "4.0.0" too) and `since:
  # "1.0.0"` matches the corpus's earliest point — so `checkUntil`
  # (rule c: the window must contain a `fkVerified` fact) and `checkSince`
  # both PASS at compile time; this is the "manifest agrees with the
  # declared bound" case §6 asks for, not a contradiction fixture (that's
  # `tfail_manifest_until_contradiction.nim`'s job). Per §4.4, the ATTESTED
  # path (this whole file) is keyed SOLELY on the manifest's `fkMismatch`
  # fact, never on this declared bound — the bound's presence here proves
  # that coexistence compiles and changes nothing at runtime; see the two
  # `cpmMismatch*` tests below for the "still keyed on the manifest fact,
  # not the declared interval" assertion.
  # RFC-0002 §4.1/§5/§6, slice D1: `until` requires `verifyWhen` — gated on
  # `TESTLIB_VERSION < 99`, trivially true under the real header's default
  # `TESTLIB_VERSION == 1`, so verification here stays LIVE and this
  # file's `since`/`until` bounds still carry through unchanged; the gate
  # is unrelated to the "4.0.0"-shaped semver bound this file exercises
  # (that axis is `since`/`until` + the manifest, not the C macro).
  proc testlib_gated(): cint {.cdecl, header: "tests/testlib.h",
    since: "1.0.0", until: "4.0.0", verifyWhen: "TESTLIB_VERSION < 99".}
  # RFC-0002 §4.4/§6, slice C4b: testlib_magic — OPTIONAL (unlike
  # testlib_gated above, which stays REQUIRED — its declared-bound
  # refusal is C4c's territory, exercised by the `cpmOutOfCorpus` suite
  # below) and bound with its OWN declared interval,
  # `since: "1.0.0", until: "4.0.0"`.
  # Present in libtestlib.so (see tests/testlib.c) and carries the SAME
  # `verified`/`mismatch` fact shape as testlib_gated above (see the
  # .tmpl.json) — added purely to exercise item 6
  # (`-d:softlinkNoDriftRefusal`) for the OPTIONAL declared-bound refusal
  # mechanism (C4b) at the `atOutOfCorpus` site, reusing this file's
  # ALREADY double-compiled harness (`driftRefusalOverridden`) rather than
  # growing a second one (see tests/tcompat_report_manifest.nim's own doc
  # comment for why that file isn't ALSO double-compiled). This fixture
  # used to carry an `unknown` fact from "4.0.0" onward instead — Finding
  # R2-A: `checkUntil` rule (b) now requires a DECISIVE fact at or above a
  # declared `until` (verified contradicts, mismatch/absent agree, unknown
  # now ALSO contradicts — an unclassified corpus version can't discharge
  # the attested-path exemption's premise that this proc validated the
  # whole declared-invalid window), so a manifest entry that never says
  # anything decisive there no longer compiles. Its own attested-path
  # `mismatch` fact never actually surfaces in THIS file's assertions —
  # every attested probe at or above "4.0.0" also lands inside
  # testlib_gated's identical mismatch interval, and testlib_gated
  # (declared first, REQUIRED) already unwinds the whole load first
  # (first-hit-wins), so testlib_magic's own attested drift-refusal path
  # is never independently observed here.
  # RFC-0002 §4.1/§5/§6, slice D1: same D1 gate as testlib_gated above.
  proc testlib_magic(): cint {.cdecl, optional, header: "tests/testlib.h",
    since: "1.0.0", until: "4.0.0", verifyWhen: "TESTLIB_VERSION < 99".}
  # RFC-0002 §4.4, code-review finding CR1-1: testlib_noop — REQUIRED,
  # bounded, and deliberately ABSENT from this file's own manifest (see
  # `tests/manifests/testlib_drift_required.tmpl.json`'s `symbols`: only
  # testlib_add, testlib_gated, testlib_magic are listed). Always present
  # in libtestlib.so (tests/testlib.c), so nothing but the declared-bound
  # refusal check can stop it dispatching. Before the CR1-1 fix, the
  # ATTESTED path (`attestedStmts`) never called `declaredBoundRefusalStmts`
  # at all — `checkUntil`/`checkSince` (softlink/manifest) vacuous-pass on
  # a symbol absent from the manifest, so this proc got ZERO declared-bound
  # enforcement even at an in-corpus (attested) probe at-or-above its
  # declared `until`, and dispatched silently (the RED case the two new
  # `cpmAttestedAbsentBound*` probe modes above exercise).
  proc testlib_noop() {.cdecl, header: "tests/testlib.h",
    since: "1.0.0", until: "3.0.0", verifyWhen: "TESTLIB_VERSION < 99".}
  versionProbe:
    case corpusProbeMode
    of cpmVerified: "2.0.0"
    of cpmMismatch: "4.0.0"
    of cpmMismatchAbove: "5.0.0"
    of cpmOutOfCorpus: "9.9.9"
    of cpmAttestedAbsentBoundHit: "3.0.0"
    of cpmAttestedAbsentBoundOk: "1.0.0"
    of cpmOutOfCorpusBelowSince: "0.5.0"
    of cpmOutOfCorpusTie: "3.0.0-rc1"

suite "Drift refusal (RFC-0001 C4c) — required symbols":
  test "mismatch probe mode: required refusal unwinds the load; report carries the drift story":
    corpusProbeMode = cpmMismatch
    unloadTestlib()
    let r = loadTestlib()
    if driftRefusalOverridden:
      # Item 6: -d:softlinkNoDriftRefusal disables the refusal build-wide —
      # the load succeeds and the symbol is callable exactly as if no
      # mismatch fact existed.
      check r.kind == lrOk
      check testlibLoaded()
      check testlib_gated() == 21
    else:
      check r.kind == lrSymbolNotFound
      check r.symbol == "testlib_gated"
      check not testlibLoaded()
      let c = testlibCompat()
      check c.attestation == atAttested
      check c.runtimeVersion == "4.0.0"
      check c.missingReasons.anyIt(it.symbol == "testlib_gated" and it.reason == mrDriftRefused)
      # RFC-0002 §4.9, slice C2: attested-mismatch leg -- the manifest's
      # own `firstMismatchInterval` ("4.0.0", unbounded), same fact shape
      # C4b's own fixture uses for this symbol -- NOT a declared bound
      # (testlib_gated carries no `since`/`until` pragma here either).
      check c.missingReasons.filterIt(it.symbol == "testlib_gated")[0].interval ==
        VersionInterval(lo: "4.0.0", hi: "")
      var caught: SoftlinkError
      try:
        discard testlib_gated()
        fail()
      except SoftlinkError as e:
        caught = e
      check caught != nil
      check "testlib_gated" in caught.msg
      check ">=4.0.0" in caught.msg
      check "refus" in caught.msg

  test "RFC-0002 C3b: attested probe strictly ABOVE testlib_gated's declared until -> same required refusal":
    corpusProbeMode = cpmMismatchAbove
    unloadTestlib()
    let r = loadTestlib()
    if driftRefusalOverridden:
      check r.kind == lrOk
      check testlibLoaded()
      check testlib_gated() == 21
    else:
      check r.kind == lrSymbolNotFound
      check r.symbol == "testlib_gated"
      check not testlibLoaded()
      let c = testlibCompat()
      check c.attestation == atAttested
      check c.runtimeVersion == "5.0.0"
      check c.missingReasons.anyIt(it.symbol == "testlib_gated" and it.reason == mrDriftRefused)
      # RFC-0002 §4.9/§4.4: the ATTESTED-MISMATCH leg still sources the
      # manifest's own `firstMismatchInterval` ("4.0.0", unbounded) — NOT
      # testlib_gated's newly-declared bound (`since: "1.0.0", until:
      # "4.0.0"`, added below). The two happen to describe the same drift
      # onset here (by fixture design, per C3b), but this assertion proves
      # the attested mechanism is still keyed on the manifest fact, not on
      # the declared interval — exactly §4.4's "no change... a separate
      # declared-bound check would be redundant here" claim.
      check c.missingReasons.filterIt(it.symbol == "testlib_gated")[0].interval ==
        VersionInterval(lo: "4.0.0", hi: "")

  test "lrOk implies safe: verified probe mode -> callable, no drift entries":
    corpusProbeMode = cpmVerified
    unloadTestlib()
    let r = loadTestlib()
    check r.kind == lrOk
    check testlibLoaded()
    check testlib_gated() == 21
    let c = testlibCompat()
    check c.attestation == atAttested
    check not c.missingReasons.anyIt(it.reason == mrDriftRefused)

  # RFC-0002 §4.4/§6, slice C4c: `testlib_gated` (REQUIRED, declared
  # `since: "1.0.0", until: "4.0.0"`) is out-of-corpus at "9.9.9",
  # decisively at-or-above its declared `until` — the required declared-
  # bound refusal fragment now unwinds the WHOLE load, checked BEFORE
  # `testlib_magic`'s own optional check (required-then-declaration-order,
  # "first hit wins") — so `testlib_magic`'s own refusal never gets a
  # chance to fire; it is simply never evaluated, same as every other
  # pointer in this block, which all get reset nil by the unwind.
  test "out-of-corpus probe mode: testlib_gated (required, bounded) unwinds the whole load per RFC-0002 C4c, unless overridden; testlib_magic (optional) never separately evaluated":
    corpusProbeMode = cpmOutOfCorpus
    unloadTestlib()
    let r = loadTestlib()
    if driftRefusalOverridden:
      check r.kind == lrOk
      check testlibLoaded()
      check testlib_gated() == 21
      check testlib_magicAvailable()
      check testlib_magic() == 42
      let c = testlibCompat()
      check c.attestation == atOutOfCorpus
      check c.runtimeVersion == "9.9.9"
      check not c.missingReasons.anyIt(it.reason == mrDriftRefused)
    else:
      check r.kind == lrSymbolNotFound
      check r.symbol == "testlib_gated"
      check not testlibLoaded()
      let c = testlibCompat()
      check c.attestation == atOutOfCorpus
      check c.runtimeVersion == "9.9.9"
      # §4.4: `atOutOfCorpus` folds in the block's own C3 partition, but
      # this block has no genuinely-absent optional symbol at "9.9.9" (no
      # manifest facts cover testlib_magic outside its own mismatch-free
      # `unknown` interval) — so the only entry is this refusal's own.
      check c.missingReasons.anyIt(it.symbol == "testlib_gated" and it.reason == mrDriftRefused)
      check c.missingReasons.filterIt(it.symbol == "testlib_gated")[0].interval ==
        VersionInterval(lo: "1.0.0", hi: "4.0.0")
      var caught: SoftlinkError
      try:
        discard testlib_gated()
        fail()
      except SoftlinkError as e:
        caught = e
      check caught != nil
      check "testlib_gated" in caught.msg
      check ">=1.0.0" in caught.msg
      check "<4.0.0" in caught.msg
      check "refus" in caught.msg

  # Code review CR1-8, cell 1(a): the SAME manifest-attached `atOutOfCorpus`
  # site as the test directly above, but hitting testlib_gated's `since`
  # leg instead of its `until` leg — decisively BELOW "1.0.0", not literally
  # harvested (the corpus lists only "1.0.0".."5.0.0"). Must refuse exactly
  # like the above-until case: same required symbol, same unwind shape,
  # only the direction of the crossed bound differs.
  test "out-of-corpus probe mode, below since: testlib_gated (required, bounded) unwinds the whole load, unless overridden":
    corpusProbeMode = cpmOutOfCorpusBelowSince
    unloadTestlib()
    let r = loadTestlib()
    if driftRefusalOverridden:
      check r.kind == lrOk
      check testlibLoaded()
      check testlib_gated() == 21
      let c = testlibCompat()
      check c.attestation == atOutOfCorpus
      check c.runtimeVersion == "0.5.0"
      check not c.missingReasons.anyIt(it.reason == mrDriftRefused)
    else:
      check r.kind == lrSymbolNotFound
      check r.symbol == "testlib_gated"
      check not testlibLoaded()
      let c = testlibCompat()
      check c.attestation == atOutOfCorpus
      check c.runtimeVersion == "0.5.0"
      check c.missingReasons.anyIt(it.symbol == "testlib_gated" and it.reason == mrDriftRefused)
      check c.missingReasons.filterIt(it.symbol == "testlib_gated")[0].interval ==
        VersionInterval(lo: "1.0.0", hi: "4.0.0")
      var caught: SoftlinkError
      try:
        discard testlib_gated()
        fail()
      except SoftlinkError as e:
        caught = e
      check caught != nil
      check "testlib_gated" in caught.msg
      check ">=1.0.0" in caught.msg
      check "<4.0.0" in caught.msg
      check "refus" in caught.msg

  # Code review CR1-8, cell 1(b): the manifest-attached `atOutOfCorpus`
  # site's boundary-TIE shape — a probe whose numeric prefix ties a
  # declared bound exactly but carries an alpha tail (here, testlib_noop's
  # `until`, "3.0.0"). `evaluateBoundRefusal`'s underlying `compareToBound`
  # must decline to decide (this is a real ambiguity: is a "-rc1" build
  # before or at its own release?), so NEITHER testlib_gated NOR
  # testlib_noop is refused and the load proceeds normally, with
  # `probeNotComparable` surfacing the ambiguity instead of silently
  # picking a side.
  #
  # This DOES need the `driftRefusalOverridden` branch, unlike a first
  # glance at "nothing here would have been refused anyway" might suggest:
  # `-d:softlinkNoDriftRefusal` gates `declaredBoundRequiredCandidates`/
  # `declaredBoundOptionalCandidates` down to EMPTY (src/softlink.nim,
  # `if hasProbe and driftRefusalEnabled`) — the whole declared-bound
  # mechanism, `probeNotComparable`'s ONLY source, is then never even
  # invoked, so the override run must see `probeNotComparable == false`,
  # not `true`.
  test "out-of-corpus probe mode, boundary tie with an alpha tail: loads normally; probeNotComparable reflects whether the mechanism ran":
    corpusProbeMode = cpmOutOfCorpusTie
    unloadTestlib()
    let r = loadTestlib()
    check r.kind == lrOk
    check testlibLoaded()
    check testlib_gated() == 21
    testlib_noop()
    check testlib_magicAvailable()
    check testlib_magic() == 42
    let c = testlibCompat()
    check c.attestation == atOutOfCorpus
    check c.runtimeVersion == "3.0.0-rc1"
    check not c.missingReasons.anyIt(it.reason == mrDriftRefused)
    if driftRefusalOverridden:
      check not c.probeNotComparable
    else:
      check c.probeNotComparable

  test "unload after a refused load resets the report to atProbeNotRun; reload at a verified version restores usability":
    if not driftRefusalOverridden:
      corpusProbeMode = cpmMismatch
      unloadTestlib()
      discard loadTestlib()
      check not testlibLoaded()
      unloadTestlib()
      let zero = testlibCompat()
      # RFC-0001 §C.2, finding #11: this block DOES declare a versionProbe
      # (above), so its post-unload state is the TRANSIENT `atProbeNotRun`
      # (a reload will run the probe again) — never the permanent-
      # structural `atNoProbe`, which would wrongly claim this block has no
      # probe at all.
      check zero.attestation == atProbeNotRun
      check zero.missingReasons.len == 0
      corpusProbeMode = cpmVerified
      let r = loadTestlib()
      check r.kind == lrOk
      check testlib_gated() == 21
      check not testlibCompat().missingReasons.anyIt(it.reason == mrDriftRefused)

# RFC-0002 §4.4, code-review finding CR1-1: the ATTESTED-path declared-bound
# refusal gap for a bounded proc ABSENT from the attached manifest —
# `testlib_noop` above (required, since "1.0.0" until "3.0.0", never listed
# in this file's own manifest). Before the fix, `attestedStmts` refused only
# off manifest `fkMismatch` facts, so a manifest-absent bounded proc got no
# enforcement at all here, even at an in-corpus probe past its declared
# `until` — this suite pins the fix: the required flavor unwinds the whole
# load exactly like the pre-existing `atOutOfCorpus`/`atNoManifest` sites'
# required unwind, and a manifest-PRESENT bounded proc (testlib_gated,
# tested elsewhere in this same file) is unaffected — its exemption on the
# attested path is preserved, since `checkUntil` already validated it.
suite "Drift refusal (RFC-0002 CR1-1) — manifest-absent bounded proc, attested path":
  test "attested in-corpus probe at-or-above declared until, symbol absent from manifest -> whole load unwinds":
    corpusProbeMode = cpmAttestedAbsentBoundHit
    unloadTestlib()
    let r = loadTestlib()
    if driftRefusalOverridden:
      check r.kind == lrOk
      check testlibLoaded()
      testlib_noop()
    else:
      check r.kind == lrSymbolNotFound
      check r.symbol == "testlib_noop"
      check not testlibLoaded()
      let c = testlibCompat()
      check c.attestation == atAttested
      check c.runtimeVersion == "3.0.0"
      check c.missingReasons.anyIt(it.symbol == "testlib_noop" and it.reason == mrDriftRefused)
      check c.missingReasons.filterIt(it.symbol == "testlib_noop")[0].interval ==
        VersionInterval(lo: "1.0.0", hi: "3.0.0")
      var caught: SoftlinkError
      try:
        testlib_noop()
        fail()
      except SoftlinkError as e:
        caught = e
      check caught != nil
      check "testlib_noop" in caught.msg
      check ">=1.0.0" in caught.msg
      check "<3.0.0" in caught.msg
      check "refus" in caught.msg

  test "attested in-corpus probe inside the declared window, symbol absent from manifest -> loads normally (control)":
    corpusProbeMode = cpmAttestedAbsentBoundOk
    unloadTestlib()
    let r = loadTestlib()
    check r.kind == lrOk
    check testlibLoaded()
    testlib_noop()
    let c = testlibCompat()
    check c.attestation == atAttested
    check c.runtimeVersion == "1.0.0"
    check not c.missingReasons.anyIt(it.symbol == "testlib_noop")
