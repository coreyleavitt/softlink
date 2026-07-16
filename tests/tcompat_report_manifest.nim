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
import std/unittest
import softlink

type CorpusProbeMode = enum
  cpmInCorpus     ## returns a version literally present in the manifest's corpus
  cpmOutOfCorpus  ## returns a parseable version absent from the corpus

var corpusProbeMode = cpmInCorpus

dynlib "libtestlib.so":
  compatManifest "manifests/testlib_compat_report.compat.json"
  proc testlib_add(a: cint, b: cint): cint {.cdecl, header: "tests/testlib.h".}
  versionProbe:
    case corpusProbeMode
    of cpmInCorpus: "2.0.0"
    of cpmOutOfCorpus: "9.9.9"

suite "CompatReport (RFC-0001 C2) — manifest attached, in/out of corpus (item 4)":
  test "probed version inside the manifest's harvested corpus -> atAttested":
    corpusProbeMode = cpmInCorpus
    unloadTestlib()
    let r = loadTestlib()
    check r.kind == lrOk
    let c = testlibCompat()
    check c.attestation == atAttested
    check c.runtimeVersion == "2.0.0"
    check c.missing.len == 0

  test "probed version outside the manifest's harvested corpus -> atOutOfCorpus":
    corpusProbeMode = cpmOutOfCorpus
    unloadTestlib()
    let r = loadTestlib()
    check r.kind == lrOk
    let c = testlibCompat()
    check c.attestation == atOutOfCorpus
    check c.runtimeVersion == "9.9.9"
    check c.missing.len == 0
