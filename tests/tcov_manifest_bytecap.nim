## Finding R2-5 (code-review round 2): the F16 breadth cap
## (`maxManifestBreadth`, symbols.len * corpus.len) doesn't bound
## intervals-per-cell — a manifest with exactly one symbol and one corpus
## entry, but millions of interval objects packed into that single cell,
## evades it entirely, while `parseJson` still has to build a `JsonNode`
## tree over the whole hostile input before any breadth check runs. The
## fix is a raw-byte size cap (`maxManifestBytes`, in
## `src/softlink/manifest.nim`) applied BEFORE `parseJson` — this is a
## standalone `unittest` file (no `std/macros`, per this module's own
## "directly unittest-able" design note), proving:
##  1. an over-cap input is rejected with a clear `ManifestError`, and
##  2. it is rejected WITHOUT ever reaching `parseJson` — i.e. even
##     deliberately-invalid JSON past the cap still reports the byte-cap
##     error, not a JSON-syntax error, because the size check runs first.

import std/[unittest, strutils]
import softlink/manifest

suite "softlink/manifest -- raw-byte size cap (R2-5)":
  test "parseManifest: input over maxManifestBytes raises ManifestError naming the cap":
    # Deliberately malformed JSON (never closes the array) -- if the size
    # cap did not run before `parseJson`, this would raise a "invalid JSON"
    # ManifestError instead of the byte-cap one, which the assertion below
    # would catch.
    let oversized = "{\"padding\":\"" & repeat('x', maxManifestBytes + 1) & "\""
    check oversized.len > maxManifestBytes
    var raised = false
    var msg = ""
    try:
      discard parseManifest(oversized, "bogus.json")
    except ManifestError as e:
      raised = true
      msg = e.msg
    check raised
    check "exceeds the " & $maxManifestBytes & "-byte cap" in msg
    check "invalid JSON" notin msg

  test "parseManifest: input exactly at maxManifestBytes is not rejected by the size cap":
    # Boundary check: the cap is "raw byte length EXCEEDS the cap", so an
    # input of exactly `maxManifestBytes` bytes must clear the size check
    # (and then fail for an ordinary reason -- invalid JSON here -- proving
    # the size check itself did not fire).
    let atCap = "{" & repeat(' ', maxManifestBytes - 2) & "}"
    check atCap.len == maxManifestBytes
    var raised = false
    var msg = ""
    try:
      discard parseManifest(atCap, "bogus.json")
    except ManifestError as e:
      raised = true
      msg = e.msg
    check raised
    check "exceeds the " & $maxManifestBytes & "-byte cap" notin msg

  test "parseManifest: small, well-formed manifest is unaffected by the size cap (control)":
    let text = """{"schema":1,"lib":"x","harvest":{"abi":"linux-lp64"},
      "corpus":[],"symbols":{}}"""
    let m = parseManifest(text, "bogus.json")
    check m.schema == 1
    check m.lib == "x"
