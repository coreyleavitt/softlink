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
  cpmOutOfCorpus  ## "9.9.9" — not literally harvested; testlib_gated's
                  ## mismatch interval is unbounded (covers "9.9.9" too),
                  ## but out-of-corpus versions load normally regardless
                  ## (RFC-0001 §C.3 policy, identical to C4b's)

var corpusProbeMode = cpmVerified

dynlib "libtestlib.so":
  compatManifest "manifests/testlib_drift_required.compat.json"
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
  # testlib_gated: REQUIRED here (a separate module from C4b's own binding,
  # which binds the identical underlying .so symbol `optional`) — RFC-0001
  # §C.3/§9 slice C4c: present in libtestlib.so, but the manifest records a
  # mismatch interval starting at "4.0.0" — a hit must unwind the WHOLE
  # load (library unloaded, handle nil), not merely re-nil one pointer.
  proc testlib_gated(): cint {.cdecl, header: "tests/testlib.h".}
  versionProbe:
    case corpusProbeMode
    of cpmVerified: "2.0.0"
    of cpmMismatch: "4.0.0"
    of cpmOutOfCorpus: "9.9.9"

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
      check (symbol: "testlib_gated", reason: mrDriftRefused) in c.missingReasons
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

  test "out-of-corpus probe mode loads normally despite an unbounded mismatch interval":
    corpusProbeMode = cpmOutOfCorpus
    unloadTestlib()
    let r = loadTestlib()
    check r.kind == lrOk
    check testlibLoaded()
    check testlib_gated() == 21
    let c = testlibCompat()
    check c.attestation == atOutOfCorpus
    check c.runtimeVersion == "9.9.9"

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
