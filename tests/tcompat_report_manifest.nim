## RFC-0001 §9/§C.2, slice C2 — TDD suite item 4: `fooCompat()`'s runtime
## attestation against an ACTUALLY attached compat manifest, both branches
## (probed version inside vs. outside the manifest's harvested corpus).
## This needs a REAL load (not just a compile-time consumption check, which
## `tests/tcheck_manifest_*.nim` already cover via the nimble task's
## `--compileOnly` `runManifestChecks`), so it lives here as its own
## runtime module, compiled and RUN via `nim c -r` — exactly like
## `tests/test_softlink.nim` itself — rather than folded into that
## `--compileOnly` fixture family.
##
## RFC-0001 §C.2, slice C3 extends this file: the `{.since.}` + absence
## partition (`mrExpected`/`mrAnomalous`) against `testlib_future` (the
## standing never-implemented optional symbol, RFC-0001 §C2 handoff) and
## `testlib_future_nv` (a second, `{.noverify.}` never-implemented optional
## symbol added here purely to exercise the since-without-manifest-facts
## path — it carries no header facts in the manifest at all).
##
## RFC-0001 §C.3, slice C4b extends this file again: drift refusal for an
## OPTIONAL symbol that DOES resolve at runtime — `testlib_gated` (present
## in libtestlib.so, see tests/testlib.c/h; bound `optional` HERE only —
## its OWN separate dynlib block elsewhere in the suite binds it
## required). The fixture manifest gives it `verified` through "4.0.0"
## then `mismatch` from "4.0.0" onward; `testlib_future`'s own facts grow
## a `mismatch` interval at "4.0.0" too (while it stays unimplemented,
## i.e. never resolves) — the "already-absent symbol whose facts ALSO
## carry a mismatch interval" no-double-count case. A new corpus point,
## "4.0.0" (`cpmMismatchInterval`), exercises both at once.
##
## RFC-0002 §4.3/§6, slice C1 extends this file again: the `until`-driven
## absence-classification demotion, against a new `testlib_dropped` symbol
## (`{.optional, since, until.}`, never implemented in testlib.c, like
## `testlib_future`) — see its own doc comment below and the "CompatReport
## (RFC-0002 C1)" suite.
##
## `tests/manifests/testlib_compat_report.tmpl.json` is materialized to its
## real, gitignored `*.compat.json` path by the nimble test task
## immediately before this file is compiled (the same `${ABI}` templating
## `tcheck_manifest_ok.nim` uses), and removed afterward.
##
## A SEPARATE `dynlib` block binding the same underlying `libtestlib.so` is
## legal here: the duplicate-block guard (#14) fires per-MODULE-scope, not
## globally — this file's own block does not collide with
## `tests/test_softlink.nim`'s (a different module, a different
## `softlinkHandleTestlib` var entirely).
##
## RFC-0002 §4.4/§6, slice C4b extends this file again: declared-bound
## refusal for OPTIONAL symbols at the `atOutOfCorpus` site — the
## `cpmOutOfCorpus` test below now ALSO asserts `testlib_gated` (bound
## `since`/`until` by slice C3b, see below) is refused, since "9.9.9" is
## decisively above its declared `until`. The `-d:softlinkNoDriftRefusal`
## escape hatch for THIS mechanism is instead exercised in
## `tests/tcompat_drift_required.nim` (already double-compiled with that
## define for C4c's own required-symbol coverage; a second `testlib_magic`
## proc, optional and bounded, added there reuses that existing harness
## rather than growing a second double-compile of this larger file).
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import std/[unittest, sequtils, strutils]
import softlink

type CorpusProbeMode = enum
  cpmAbsentInterval    ## "1.0.0" — testlib_future's headers do NOT declare it here
  cpmVerifiedInterval  ## "2.0.0" — testlib_future's headers DO declare it here (also: in-corpus)
  cpmUnknownInterval   ## "3.0.0" — testlib_future's facts are unknown here (also: in-corpus)
  cpmMismatchInterval  ## "4.0.0" — in-corpus: testlib_gated's headers record a MISMATCH here
                       ## (RFC-0001 §C.4b drift refusal) while testlib_future ALSO carries a
                       ## mismatch fact here (the "already-absent, no double-count" case)
  cpmMismatchAbove     ## "5.0.0" — RFC-0002 §6, slice C3b: a SECOND in-corpus (attested)
                       ## point, strictly above testlib_gated's declared `until` ("4.0.0",
                       ## added alongside this probe mode), still inside its unbounded
                       ## `mismatch` fact — the optional-symbol twin of
                       ## `tests/tcompat_drift_required.nim`'s own `cpmMismatchAbove`: proves
                       ## the attested refusal mechanism fires here purely off the manifest
                       ## fact, independent of the declared bound.
  cpmOutOfCorpus       ## "9.9.9" — parseable, not literally harvested; testlib_future falls in
                       ## its own "unknown" tail here, and testlib_gated's mismatch interval is
                       ## unbounded (covers "9.9.9" too) — the §C.4b "out-of-corpus is never
                       ## refused" policy test

var corpusProbeMode = cpmVerifiedInterval

dynlib "testlib":
  compatManifest "manifests/testlib_compat_report.compat.json"
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
  # testlib_future: declared in tests/testlib.h, never implemented in
  # tests/testlib.c — always in LoadResult.missing on lrOkPartial. Its
  # manifest facts (see the fixture) are absent/[1.0.0], verified/[2.0.0],
  # unknown/[3.0.0,4.0.0), mismatch/[4.0.0..5.0.0), unknown/[5.0.0..) —
  # the three C3 partition outcomes, PLUS (at "4.0.0") the C4b
  # no-double-count case: absent at runtime AND carrying a mismatch fact
  # at the probed version.
  proc testlib_future(): cint {.cdecl, optional, header: "tests/testlib.h".}
  # testlib_future_nv: ALSO never implemented, but {.noverify.} (no header
  # facts tracked in the manifest at all — RFC-0001 §C.2's "symbol not in
  # the manifest entirely" case) and carrying a {.since.} claim far ahead
  # of every probed version this file ever uses, so it isolates the
  # since-ALONE contribution to the partition (item 4 of the slice) from
  # testlib_future's own header-fact coverage.
  proc testlib_future_nv(): cint {.cdecl, optional, noverify, since: "9.5.0".}
  # testlib_gated: RFC-0001 §C.3/§C.4b — present in libtestlib.so (see
  # tests/testlib.c/h), bound `optional` HERE (a SEPARATE dynlib block
  # elsewhere in the suite binds the same underlying symbol required —
  # legal, different module). Its manifest facts are verified through
  # "4.0.0", then mismatch from "4.0.0" onward (unbounded) — a symbol
  # that DOES resolve at runtime but whose signature this manifest already
  # knows drifted starting at the probed corpus point.
  # RFC-0002 §4.4/§6, slice C3b: `since`/`until` added here too — the
  # optional-symbol twin of `tests/tcompat_drift_required.nim`'s own C3b
  # addition to its REQUIRED `testlib_gated`. `until: "4.0.0"` matches the
  # manifest's drift onset exactly and `since: "1.0.0"` matches the
  # corpus's earliest point, so `checkUntil`/`checkSince` both PASS at
  # compile time (manifest agrees with the declared bound). Per §4.4 the
  # ATTESTED path stays keyed solely on the manifest's own `fkMismatch`
  # fact — this bound changes nothing at runtime; see the two
  # `cpmMismatch*` tests in the "RFC-0001 C4b" suite below for the
  # fact-not-bound assertion.
  # RFC-0002 §4.1/§5/§6, slice D1: `until` requires `verifyWhen` — gated on
  # `TESTLIB_VERSION < 99`, trivially true under the header's real default
  # `TESTLIB_VERSION == 1`, so verification stays LIVE; unrelated to this
  # file's own "4.0.0"-shaped `since`/`until` bound.
  proc testlib_gated(): cint {.cdecl, optional, header: "tests/testlib.h",
    since: "1.0.0", until: "4.0.0", verifyWhen: "TESTLIB_VERSION < 99".}
  # testlib_dropped: RFC-0002 §4.3/§6, slice C1 — {.optional, since,
  # until.}, never implemented in testlib.c (like testlib_future above),
  # so always in `LoadResult.missing` regardless of probed version. The
  # fixture manifest's facts (see the .tmpl.json) place it `absent` below
  # `since` ("2.0.0"), `verified` across `[since, until)`, and `mismatch`
  # at-or-above `until` ("4.0.0") — reusing this file's existing
  # `CorpusProbeMode` probe points end-to-end (no new probe values
  # needed): "1.0.0" is below `since` (pre-existing absent-fact rule,
  # untouched by `until`); "2.0.0" is inside `[since, until)`
  # (pre-existing verified-fact rule, still anomalous — C1 doesn't fire
  # there); "4.0.0" is AT `until` exactly (the tracer: C1's demotion wins
  # over the `mismatch` fact recorded there, BEFORE the anomalous rule
  # gets a chance to run); "9.9.9" is ABOVE `until`.
  # RFC-0002 §4.1/§5/§6, slice D1: same D1 gate as testlib_gated above.
  proc testlib_dropped(): cint {.cdecl, optional, header: "tests/testlib.h",
    since: "2.0.0", until: "4.0.0", verifyWhen: "TESTLIB_VERSION < 99".}
  # RFC-0002 §4.4/§4.9, slice C4b: testlib_noop — optional but carries NO
  # `since`/`until` bound at all, always present in libtestlib.so. Exists
  # purely to prove the new declared-bound refusal fragment leaves an
  # UNBOUNDED optional symbol completely untouched at every probe mode,
  # including out-of-corpus — §4.4's mechanism is keyed on a DECLARED
  # bound; a symbol with none is never a candidate for it at all, so the
  # pre-C4b "out-of-corpus loads normally" behavior stands unchanged here.
  proc testlib_noop() {.cdecl, optional, header: "tests/testlib.h".}
  # RFC-0002 §4.4, code-review finding CR1-1: testlib_const_string — OPTIONAL,
  # bounded (`since: "1.0.0", until: "3.0.0"`), and deliberately ABSENT from
  # this file's manifest (see testlib_compat_report.tmpl.json's `symbols` —
  # only testlib_add/testlib_future/testlib_gated/testlib_dropped are
  # listed). Genuinely present in libtestlib.so (tests/testlib.c returns a
  # real string), so nothing but the declared-bound refusal check can stop
  # it resolving. Before the CR1-1 fix, the ATTESTED path never called
  # `declaredBoundRefusalStmts` for a manifest-absent symbol at all — this
  # proc would stay resolved and callable even past its declared `until` at
  # an in-corpus (attested) probe. `cpmUnknownInterval` ("3.0.0", at-or-
  # above its `until`) and `cpmAbsentInterval` ("1.0.0", inside its window)
  # are reused as-is below (both already attested/in-corpus probe points;
  # neither test's EXISTING assertions concern this symbol, so adding new,
  # separate `test` blocks against the same enum values is additive and
  # does not disturb them). `cpmOutOfCorpus` ("9.9.9") also crosses this
  # bound, but that is the PRE-EXISTING `atOutOfCorpus` declared-bound
  # mechanism (unconditional on manifest attachment already, unrelated to
  # this fix) — see that test's own updated comment below.
  proc testlib_const_string(): cstring {.cdecl, optional, header: "tests/testlib.h",
    since: "1.0.0", until: "3.0.0", verifyWhen: "TESTLIB_VERSION < 99".}
  versionProbe:
    case corpusProbeMode
    of cpmAbsentInterval: "1.0.0"
    of cpmVerifiedInterval: "2.0.0"
    of cpmUnknownInterval: "3.0.0"
    of cpmMismatchInterval: "4.0.0"
    of cpmMismatchAbove: "5.0.0"
    of cpmOutOfCorpus: "9.9.9"

suite "CompatReport (RFC-0001 C2) — manifest attached, in/out of corpus (item 4)":
  test "probed version inside the manifest's harvested corpus -> atAttested":
    corpusProbeMode = cpmVerifiedInterval
    unloadTestlib()
    let r = loadTestlib()
    check r.kind == lrOkPartial
    check "testlib_future" in r.missing
    check "testlib_future_nv" in r.missing
    let c = testlibCompat()
    check c.attestation == atAttested
    check c.runtimeVersion == "2.0.0"

  test "probed version outside the manifest's harvested corpus -> atOutOfCorpus":
    corpusProbeMode = cpmOutOfCorpus
    unloadTestlib()
    let r = loadTestlib()
    check r.kind == lrOkPartial
    let c = testlibCompat()
    check c.attestation == atOutOfCorpus
    check c.runtimeVersion == "9.9.9"
    # RFC-0001 §C.2/§C.3: "9.9.9" falls in testlib_future's own `unknown`
    # tail (lo: "3.0.0", unbounded) -- no partition entry, honest
    # ignorance. testlib_future_nv's since ("9.5.0") does not cover "9.9.9"
    # either (9.9.9 >= 9.5.0) -- no entry from since. Both missing
    # symbols, therefore, contribute nothing to the partition here.
    #
    # RFC-0002 §4.3, slice C1: testlib_dropped (added alongside this
    # file's own C1 suite below) DOES contribute here now -- "9.9.9" is
    # above its declared `until` ("4.0.0"), so it classifies `acExpected`
    # via the new demotion branch. This is the one place the two files'
    # shared `CorpusProbeMode` fixture couples C1's own suite to a
    # pre-existing assertion; see the "CompatReport (RFC-0002 C1)" suite
    # below for the isolated case.
    check c.missingReasons.anyIt(it.symbol == "testlib_dropped" and it.reason == mrExpected)
    # RFC-0002 §4.9/§6, slice C2: a classification entry's interval is the
    # proc's own DECLARED [since, until) -- here testlib_dropped's
    # "2.0.0"/"4.0.0" -- regardless of which side of `until` triggered
    # this particular demotion.
    check c.missingReasons.filterIt(it.symbol == "testlib_dropped")[0].interval ==
      VersionInterval(lo: "2.0.0", hi: "4.0.0")
    # RFC-0002 §4.4, slice C4b: testlib_gated carries a DECLARED bound
    # (since: "1.0.0", until: "4.0.0", added by slice C3b) -- "9.9.9" is
    # decisively at-or-above that `until`, so the declared-bound refusal
    # fragment now fires here even though this version is out-of-corpus
    # (no ATTESTED mismatch fact governs this branch at all -- §4.4's
    # whole point). This FLIPS the pre-C4b pinned expectation ("an
    # out-of-corpus version must load normally") for BOUNDED symbols only
    # -- see testlib_noop below for the unbounded case, still unchanged.
    #
    # RFC-0002 §4.4, code-review finding CR1-1: testlib_const_string
    # (added alongside CR1-1's fix, optional, bounded, manifest-absent) is
    # ALSO decisively at-or-above its own declared `until` ("3.0.0") here --
    # this is the PRE-EXISTING atOutOfCorpus declared-bound mechanism
    # (unconditional on manifest attachment, unaffected by the CR1-1 fix
    # itself), not a new behavior -- so the count grows from 2 to 3.
    check c.missingReasons.len == 3
    check "testlib_const_string" in r.missing
    check not testlib_const_stringAvailable()
    check c.missingReasons.anyIt(it.symbol == "testlib_const_string" and it.reason == mrDriftRefused)
    check c.missingReasons.filterIt(it.symbol == "testlib_const_string")[0].interval ==
      VersionInterval(lo: "1.0.0", hi: "3.0.0")
    check "testlib_gated" in r.missing
    check not testlib_gatedAvailable()
    check c.missingReasons.anyIt(it.symbol == "testlib_gated" and it.reason == mrDriftRefused)
    check c.missingReasons.filterIt(it.symbol == "testlib_gated")[0].interval ==
      VersionInterval(lo: "1.0.0", hi: "4.0.0")
    # A decisive comparison ("9.9.9" vs "4.0.0"): no boundary ambiguity.
    check not c.probeNotComparable
    # Only the ONE drifted pointer is re-nilled -- the load itself, and
    # every OTHER symbol, is unaffected (optional refusal, not required
    # unwind; that's C4c's territory).
    check testlibLoaded()
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
    # RFC-0002 §4.4, slice C4b: an UNBOUNDED optional symbol (testlib_noop,
    # no since/until at all) is never a declared-bound-refusal candidate --
    # it stays resolved and available here exactly as it always has.
    check testlib_noopAvailable()

# RFC-0001 §9/§C.2, slice C3: the absence partition itself —
# `mrExpected` vs `mrAnomalous` against header facts, and the `{.since.}`
# runtime contribution when a manifest is attached but the symbol's own
# facts don't cover the probed version.
suite "CompatReport (RFC-0001 C3) — absence partition":
  test "missing symbol, probed version in a declared/verified interval -> mrAnomalous":
    corpusProbeMode = cpmVerifiedInterval
    unloadTestlib()
    discard loadTestlib()
    let c = testlibCompat()
    check c.missingReasons.anyIt(it.symbol == "testlib_future" and it.reason == mrAnomalous)
    # RFC-0002 §4.9, slice C2: testlib_future carries no {.since/until.}
    # pragma at all -- the declared-interval leg (this is a classification
    # entry, not an attested-mismatch one) renders as the fully-open/empty
    # VersionInterval, `formatInterval`'s "any version" fallback -- NOT
    # the manifest's own header-fact interval (`computeMissingPartition`
    # never reads those, only the classification RESULT).
    check c.missingReasons.filterIt(it.symbol == "testlib_future")[0].interval ==
      VersionInterval(lo: "", hi: "")

  test "missing symbol, probed version in an absent interval -> mrExpected":
    corpusProbeMode = cpmAbsentInterval
    unloadTestlib()
    discard loadTestlib()
    let c = testlibCompat()
    check c.missingReasons.anyIt(it.symbol == "testlib_future" and it.reason == mrExpected)

  test "probed version unknown-classified for this symbol -> no entry (honest ignorance)":
    corpusProbeMode = cpmUnknownInterval
    unloadTestlib()
    let r = loadTestlib()
    check r.kind == lrOkPartial  # report otherwise populated: a real load happened
    let c = testlibCompat()
    check c.attestation == atAttested
    check c.runtimeVersion == "3.0.0"
    check not c.missingReasons.anyIt(it.symbol == "testlib_future")

  test "{.since.} alone contributes mrExpected when facts don't cover the probed version":
    corpusProbeMode = cpmVerifiedInterval  # "2.0.0" -- well short of since: "9.5.0"
    unloadTestlib()
    discard loadTestlib()
    let c = testlibCompat()
    check c.missingReasons.anyIt(it.symbol == "testlib_future_nv" and it.reason == mrExpected)
    # RFC-0002 §4.9, slice C2: `since`-only -- the interval's `hi` leg is
    # open (no declared `until`).
    check c.missingReasons.filterIt(it.symbol == "testlib_future_nv")[0].interval ==
      VersionInterval(lo: "9.5.0", hi: "")

  test "resolved symbols never appear in the partition":
    corpusProbeMode = cpmVerifiedInterval
    unloadTestlib()
    discard loadTestlib()
    let c = testlibCompat()
    check not c.missingReasons.anyIt(it.symbol == "testlib_add")

  test "partition is mutually exclusive: each missing symbol appears at most once":
    corpusProbeMode = cpmVerifiedInterval
    unloadTestlib()
    discard loadTestlib()
    let c = testlibCompat()
    var seen: seq[string] = @[]
    for entry in c.missingReasons:
      check entry.symbol notin seen
      seen.add entry.symbol

  test "unloadTestlib resets the partition to empty":
    corpusProbeMode = cpmVerifiedInterval
    unloadTestlib()
    discard loadTestlib()
    check testlibCompat().missingReasons.len > 0
    unloadTestlib()
    check testlibCompat().missingReasons.len == 0

# RFC-0002 §4.3/§6, slice C1: the `until`-driven demotion, end-to-end
# against `testlib_dropped` (declared `since: "2.0.0", until: "4.0.0"`,
# see its own doc comment above) — the four cases named in the slice: at
# `until` (tracer), above `until`, inside `[since, until)` (unchanged),
# and below `since` (also unchanged, and NOT via the new branch at all —
# proof that C1 doesn't disturb the pre-existing absent-fact rule).
suite "CompatReport (RFC-0002 C1) — until classification":
  test "probed version AT until exactly -> acExpected (tracer: wins over the mismatch fact recorded there, BEFORE the anomalous rule runs)":
    corpusProbeMode = cpmMismatchInterval  # "4.0.0" == testlib_dropped's declared until
    unloadTestlib()
    discard loadTestlib()
    let c = testlibCompat()
    check c.missingReasons.anyIt(it.symbol == "testlib_dropped" and it.reason == mrExpected)
    # RFC-0002 §4.9, slice C2: the DECLARED interval, independent of the
    # probed version that triggered this particular classification.
    check c.missingReasons.filterIt(it.symbol == "testlib_dropped")[0].interval ==
      VersionInterval(lo: "2.0.0", hi: "4.0.0")

  test "probed version ABOVE until -> acExpected":
    corpusProbeMode = cpmOutOfCorpus  # "9.9.9"
    unloadTestlib()
    discard loadTestlib()
    let c = testlibCompat()
    check c.missingReasons.anyIt(it.symbol == "testlib_dropped" and it.reason == mrExpected)
    check c.missingReasons.filterIt(it.symbol == "testlib_dropped")[0].interval ==
      VersionInterval(lo: "2.0.0", hi: "4.0.0")

  test "probed version inside [since, until) -> acAnomalous (unchanged: until hasn't fired yet)":
    corpusProbeMode = cpmVerifiedInterval  # "2.0.0"
    unloadTestlib()
    discard loadTestlib()
    let c = testlibCompat()
    check c.missingReasons.anyIt(it.symbol == "testlib_dropped" and it.reason == mrAnomalous)
    check c.missingReasons.filterIt(it.symbol == "testlib_dropped")[0].interval ==
      VersionInterval(lo: "2.0.0", hi: "4.0.0")

  test "probed version below since (and below until) -> acExpected via the pre-existing absent-fact rule, not the new until branch":
    corpusProbeMode = cpmAbsentInterval  # "1.0.0"
    unloadTestlib()
    discard loadTestlib()
    let c = testlibCompat()
    check c.missingReasons.anyIt(it.symbol == "testlib_dropped" and it.reason == mrExpected)
    check c.missingReasons.filterIt(it.symbol == "testlib_dropped")[0].interval ==
      VersionInterval(lo: "2.0.0", hi: "4.0.0")

# RFC-0001 §C.3, slice C4b: drift refusal for OPTIONAL symbols —
# `testlib_gated` resolves at runtime but the fixture manifest records a
# `mismatch` interval starting at "4.0.0"; `testlib_future` is already
# absent at runtime (never implemented) AND also grows a `mismatch` fact
# at "4.0.0", isolating the no-double-count guarantee.
suite "CompatReport (RFC-0001 C4b) — drift refusal, optional symbols":
  test "probed version inside a mismatch interval, in-corpus -> refused":
    corpusProbeMode = cpmMismatchInterval
    unloadTestlib()
    let r = loadTestlib()
    check r.kind == lrOkPartial
    check "testlib_gated" in r.missing
    check not testlib_gatedAvailable()
    let c = testlibCompat()
    check c.attestation == atAttested
    check c.missingReasons.anyIt(it.symbol == "testlib_gated" and it.reason == mrDriftRefused)
    # RFC-0002 §4.9, slice C2: the ATTESTED-MISMATCH leg -- the manifest's
    # own `firstMismatchInterval` ("4.0.0", unbounded), NOT testlib_gated's
    # declared bound (RFC-0002 §6, slice C3b added `since: "1.0.0", until:
    # "4.0.0"` above) -- the two happen to describe the same drift onset
    # here by fixture design, but this assertion proves the attested leg
    # is still sourced from the manifest fact, never the declared interval.
    check c.missingReasons.filterIt(it.symbol == "testlib_gated")[0].interval ==
      VersionInterval(lo: "4.0.0", hi: "")

  test "wrapper raises SoftlinkError naming the symbol, interval, and refusal":
    corpusProbeMode = cpmMismatchInterval
    unloadTestlib()
    discard loadTestlib()
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

  test "non-refusing mode (verified) -> resolved, available, callable, unchanged":
    corpusProbeMode = cpmVerifiedInterval
    unloadTestlib()
    let r = loadTestlib()
    check "testlib_gated" notin r.missing
    check testlib_gatedAvailable()
    check testlib_gated() == 21
    let c = testlibCompat()
    check not c.missingReasons.anyIt(it.symbol == "testlib_gated")

  test "RFC-0002 C3b: attested probe strictly ABOVE testlib_gated's declared until -> same optional refusal":
    corpusProbeMode = cpmMismatchAbove
    unloadTestlib()
    let r = loadTestlib()
    check r.kind == lrOkPartial
    check "testlib_gated" in r.missing
    check not testlib_gatedAvailable()
    let c = testlibCompat()
    check c.attestation == atAttested
    check c.runtimeVersion == "5.0.0"
    check c.missingReasons.anyIt(it.symbol == "testlib_gated" and it.reason == mrDriftRefused)
    # Same manifest-fact-not-declared-bound point as the required flavor's
    # own C3b addition in tests/tcompat_drift_required.nim.
    check c.missingReasons.filterIt(it.symbol == "testlib_gated")[0].interval ==
      VersionInterval(lo: "4.0.0", hi: "")

  test "no double-count: an already-absent symbol whose facts also carry " &
       "a mismatch interval at the probed version -> single mrAnomalous entry":
    corpusProbeMode = cpmMismatchInterval
    unloadTestlib()
    discard loadTestlib()
    let c = testlibCompat()
    let entries = c.missingReasons.filterIt(it.symbol == "testlib_future")
    check entries.len == 1
    check entries[0].reason == mrAnomalous

  test "unload resets drift state to atProbeNotRun; reload in a non-refusing mode restores usability":
    corpusProbeMode = cpmMismatchInterval
    unloadTestlib()
    discard loadTestlib()
    check not testlib_gatedAvailable()
    unloadTestlib()
    let zero = testlibCompat()
    # RFC-0001 §C.2, finding #11: this block declares a versionProbe
    # (above), so post-unload is the TRANSIENT `atProbeNotRun`, not the
    # permanent-structural `atNoProbe`.
    check zero.attestation == atProbeNotRun
    check zero.missingReasons.len == 0
    corpusProbeMode = cpmVerifiedInterval
    discard loadTestlib()
    check testlib_gatedAvailable()
    check testlib_gated() == 21
    check not testlibCompat().missingReasons.anyIt(it.symbol == "testlib_gated")

# RFC-0002 §4.4, code-review finding CR1-1: the ATTESTED-path declared-bound
# refusal gap for a bounded proc ABSENT from the attached manifest —
# `testlib_const_string` above (optional, since "1.0.0" until "3.0.0", never
# listed in this file's own manifest). Before the fix, the attested path
# refused only off manifest `fkMismatch` facts, so a manifest-absent bounded
# proc got no enforcement at all here, even at an in-corpus probe past its
# declared `until` — this suite pins the fix for the OPTIONAL flavor: the
# symbol is re-nilled and folded into `LoadResult.missing`/`missingReasons`
# exactly like the pre-existing `atOutOfCorpus`/`atNoManifest` sites' own
# optional re-nil, while the REST of the block (including manifest-PRESENT
# bounded procs like testlib_gated/testlib_dropped, tested elsewhere in this
# file) is unaffected — their exemption on the attested path is preserved.
suite "CompatReport (RFC-0002 CR1-1) — manifest-absent bounded proc, attested path":
  test "attested in-corpus probe at-or-above declared until, symbol absent from manifest -> refused, load proceeds":
    corpusProbeMode = cpmUnknownInterval  # "3.0.0" == testlib_const_string's declared until
    unloadTestlib()
    let r = loadTestlib()
    check r.kind == lrOkPartial
    check "testlib_const_string" in r.missing
    check not testlib_const_stringAvailable()
    let c = testlibCompat()
    check c.attestation == atAttested
    check c.runtimeVersion == "3.0.0"
    check c.missingReasons.anyIt(it.symbol == "testlib_const_string" and it.reason == mrDriftRefused)
    check c.missingReasons.filterIt(it.symbol == "testlib_const_string")[0].interval ==
      VersionInterval(lo: "1.0.0", hi: "3.0.0")
    # The load itself, and every OTHER symbol, is unaffected — only the ONE
    # bounded, manifest-absent pointer is re-nilled (optional refusal, not a
    # required unwind).
    check testlibLoaded()

  test "attested in-corpus probe inside the declared window, symbol absent from manifest -> resolved, available, callable (control)":
    corpusProbeMode = cpmAbsentInterval  # "1.0.0" -- inside [1.0.0, 3.0.0)
    unloadTestlib()
    let r = loadTestlib()
    check "testlib_const_string" notin r.missing
    check testlib_const_stringAvailable()
    discard testlib_const_string()
    let c = testlibCompat()
    check not c.missingReasons.anyIt(it.symbol == "testlib_const_string")

# Code-review finding (combo test): at the ATTESTED path, a single load's
# refusal/report data can be driven by three DIFFERENT sources at once:
#   (1) a manifest-PRESENT symbol whose own `fkMismatch` fact covers the
#       probed version (testlib_gated -- "mismatch" from "4.0.0" onward,
#       "RFC-0001 C4b" suite above);
#   (2) a bounded symbol ABSENT from the manifest, hit by the CR1-1
#       declared-bound refusal fragment (testlib_const_string -- declared
#       `until: "3.0.0"`, "RFC-0002 CR1-1" suite above, which only exercises
#       it at its OWN until, "3.0.0");
#   (3) an ordinary missing optional symbol, classified by the absence
#       partition through {.since.} alone, with NO mismatch-fact
#       entanglement whatsoever (testlib_future_nv -- {.noverify.}, so it
#       carries no header facts in the manifest at all; `since: "9.5.0"` is
#       well short of "4.0.0", the pre-existing "since alone" test above,
#       cpmVerifiedInterval="2.0.0" there, not this probed version).
#
# `cpmMismatchInterval` ("4.0.0") is the one probed version, already fixed
# by this file's OWN fixture shapes, at which ALL THREE independently fire
# — chosen deliberately over minting a new probe point, specifically to
# prove COMPOSITION using facts each already-passing test above already
# vouches for in isolation, rather than asserting something new about any
# one of them. testlib_future, ALSO missing at "4.0.0", is deliberately
# excluded from this test's source-3 pick: its own facts carry a `mismatch`
# entry at "4.0.0" too (the "no double-count" case, tested above), which
# entangles it with drift — testlib_future_nv isolates a genuinely
# drift-free absence instead, keeping the three sources here structurally
# distinct, not merely differently-named.
#
# Both refused symbols (1 and 2) are OPTIONAL, never required: a required
# hit unwinds the WHOLE load (RFC-0001 C4c), which would leave nothing for
# a composed report to be observed FROM. The optional flavor is chosen
# specifically so the load still SUCCEEDS (`lrOkPartial`) with all three
# contributions coexisting in one `CompatReport`/`LoadResult`.
suite "CompatReport (combo) — three simultaneous sources, one attested load":
  test "manifest-fact drift + CR1-1 declared-bound-absent refusal + ordinary since-absence, all at once":
    corpusProbeMode = cpmMismatchInterval  # "4.0.0", attested (in-corpus)
    unloadTestlib()
    let r = loadTestlib()
    check r.kind == lrOkPartial
    let c = testlibCompat()
    check c.attestation == atAttested
    check c.runtimeVersion == "4.0.0"

    # Source 1: manifest-attested drift (an `fkMismatch` fact) on a
    # manifest-PRESENT optional symbol -- refused off the manifest's own
    # `firstMismatchInterval`, unbounded from "4.0.0".
    check "testlib_gated" in r.missing
    check not testlib_gatedAvailable()
    check c.missingReasons.anyIt(it.symbol == "testlib_gated" and it.reason == mrDriftRefused)
    check c.missingReasons.filterIt(it.symbol == "testlib_gated")[0].interval ==
      VersionInterval(lo: "4.0.0", hi: "")

    # Source 2: CR1-1 declared-bound refusal on a bounded symbol ABSENT
    # from the manifest entirely -- the runtime probed version ("4.0.0")
    # is decisively at-or-above its own declared `until` ("3.0.0"); the
    # manifest has no fact to consult at all, only the declared bound.
    check "testlib_const_string" in r.missing
    check not testlib_const_stringAvailable()
    check c.missingReasons.anyIt(it.symbol == "testlib_const_string" and it.reason == mrDriftRefused)
    check c.missingReasons.filterIt(it.symbol == "testlib_const_string")[0].interval ==
      VersionInterval(lo: "1.0.0", hi: "3.0.0")

    # Source 3: an ordinary missing optional symbol, classified purely via
    # {.since.} with zero header facts ({.noverify.}) and zero mismatch
    # entanglement -- genuine absence, not drift.
    check "testlib_future_nv" in r.missing
    check c.missingReasons.anyIt(it.symbol == "testlib_future_nv" and it.reason == mrExpected)
    check c.missingReasons.filterIt(it.symbol == "testlib_future_nv")[0].interval ==
      VersionInterval(lo: "9.5.0", hi: "")

    # None of the three contributions masks another: each symbol's entry
    # is independently present, and the partition stays mutually exclusive
    # (one entry per symbol) even with all three mechanisms firing in the
    # same load.
    var seen: seq[string] = @[]
    for entry in c.missingReasons:
      check entry.symbol notin seen
      seen.add entry.symbol
    check "testlib_gated" in seen
    check "testlib_const_string" in seen
    check "testlib_future_nv" in seen

    # An unrelated, unbounded, always-present symbol is unaffected by any
    # of the three mechanisms firing at once, and the library itself stays
    # loaded (only the affected pointers are re-nilled).
    check testlib_noopAvailable()
    check testlibLoaded()
