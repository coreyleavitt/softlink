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
## NOT compiled by the regular test suite; see the `nimble test` task.
import std/[unittest, sequtils]
import softlink

type CorpusProbeMode = enum
  cpmAbsentInterval    ## "1.0.0" — testlib_future's headers do NOT declare it here
  cpmVerifiedInterval  ## "2.0.0" — testlib_future's headers DO declare it here (also: in-corpus)
  cpmUnknownInterval   ## "3.0.0" — testlib_future's facts are unknown here (also: in-corpus)
  cpmOutOfCorpus       ## "9.9.9" — parseable, not literally harvested; both symbols fall in
                       ## their own "unknown"/uncovered tail range here

var corpusProbeMode = cpmVerifiedInterval

dynlib "libtestlib.so":
  compatManifest "manifests/testlib_compat_report.compat.json"
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
  # testlib_future: declared in tests/testlib.h, never implemented in
  # tests/testlib.c — always in LoadResult.missing on lrOkPartial. Its
  # manifest facts (see the fixture) are absent/[1.0.0], verified/[2.0.0],
  # unknown/[3.0.0..) — exactly the three C3 partition outcomes.
  proc testlib_future(): cint {.cdecl, optional, header: "tests/testlib.h".}
  # testlib_future_nv: ALSO never implemented, but {.noverify.} (no header
  # facts tracked in the manifest at all — RFC-0001 §C.2's "symbol not in
  # the manifest entirely" case) and carrying a {.since.} claim far ahead
  # of every probed version this file ever uses, so it isolates the
  # since-ALONE contribution to the partition (item 4 of the slice) from
  # testlib_future's own header-fact coverage.
  proc testlib_future_nv(): cint {.cdecl, optional, noverify, since: "9.5.0".}
  versionProbe:
    case corpusProbeMode
    of cpmAbsentInterval: "1.0.0"
    of cpmVerifiedInterval: "2.0.0"
    of cpmUnknownInterval: "3.0.0"
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
    check c.missing.len == 0

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
    check (symbol: "testlib_future", reason: mrAnomalous) in c.missing

  test "missing symbol, probed version in an absent interval -> mrExpected":
    corpusProbeMode = cpmAbsentInterval
    unloadTestlib()
    discard loadTestlib()
    let c = testlibCompat()
    check (symbol: "testlib_future", reason: mrExpected) in c.missing

  test "probed version unknown-classified for this symbol -> no entry (honest ignorance)":
    corpusProbeMode = cpmUnknownInterval
    unloadTestlib()
    let r = loadTestlib()
    check r.kind == lrOkPartial  # report otherwise populated: a real load happened
    let c = testlibCompat()
    check c.attestation == atAttested
    check c.runtimeVersion == "3.0.0"
    check not c.missing.anyIt(it.symbol == "testlib_future")

  test "{.since.} alone contributes mrExpected when facts don't cover the probed version":
    corpusProbeMode = cpmVerifiedInterval  # "2.0.0" -- well short of since: "9.5.0"
    unloadTestlib()
    discard loadTestlib()
    let c = testlibCompat()
    check (symbol: "testlib_future_nv", reason: mrExpected) in c.missing

  test "resolved symbols never appear in the partition":
    corpusProbeMode = cpmVerifiedInterval
    unloadTestlib()
    discard loadTestlib()
    let c = testlibCompat()
    check not c.missing.anyIt(it.symbol == "testlib_add")

  test "partition is mutually exclusive: each missing symbol appears at most once":
    corpusProbeMode = cpmVerifiedInterval
    unloadTestlib()
    discard loadTestlib()
    let c = testlibCompat()
    var seen: seq[string] = @[]
    for entry in c.missing:
      check entry.symbol notin seen
      seen.add entry.symbol

  test "unloadTestlib resets the partition to empty":
    corpusProbeMode = cpmVerifiedInterval
    unloadTestlib()
    discard loadTestlib()
    check testlibCompat().missing.len > 0
    unloadTestlib()
    check testlibCompat().missing.len == 0
