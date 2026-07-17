## Finding #24(c) (code-review round 2 coverage gap): `parseManifest`'s
## shape-guard branches in `src/softlink/manifest.nim` — non-array
## `corpus`, non-object `symbols`, non-object `header`, a non-array fact
## value, a non-object interval entry, and an unrecognized fact key — had
## no test coverage at all (only the "missing key"/"wrong scalar kind"
## families were exercised). This is a standalone `unittest` file (no
## `std/macros`, per `softlink/manifest`'s own "directly unittest-able"
## design note) proving each shape guard actually fires, and names the
## right thing in its error message.

import std/[unittest, strutils]
import softlink/manifest

suite "softlink/manifest -- shape-guard branches (finding #24c)":
  test "parseManifest: non-array 'corpus' raises ManifestError naming 'corpus'":
    let text = """{"schema":1,"lib":"x","harvest":{"abi":"linux-lp64"},
      "corpus":{"not":"an array"},"symbols":{}}"""
    var raised = false
    var msg = ""
    try:
      discard parseManifest(text, "bogus.json")
    except ManifestError as e:
      raised = true
      msg = e.msg
    check raised
    check "'corpus' must be an array" in msg

  test "parseManifest: non-object 'symbols' raises ManifestError naming 'symbols'":
    let text = """{"schema":1,"lib":"x","harvest":{"abi":"linux-lp64"},
      "corpus":[],"symbols":["not an object"]}"""
    var raised = false
    var msg = ""
    try:
      discard parseManifest(text, "bogus.json")
    except ManifestError as e:
      raised = true
      msg = e.msg
    check raised
    check "'symbols' must be an object" in msg

  test "parseManifest: non-object symbol entry raises ManifestError (falls through requireKey's own guard)":
    # `symbols.foo` is a bare string rather than `{"header": {...}}` --
    # `requireKey` treats "not an object" and "missing the key" identically
    # (both fail its `node.kind != JObject or not node.hasKey(key)` guard),
    # so the diagnostic names the missing key, not the wrong shape --
    # still a clean, non-silent rejection, and worth pinning explicitly so
    # a future refactor can't quietly turn this into a crash instead.
    let text = """{"schema":1,"lib":"x","harvest":{"abi":"linux-lp64"},
      "corpus":[],"symbols":{"foo":"not an object"}}"""
    var raised = false
    var msg = ""
    try:
      discard parseManifest(text, "bogus.json")
    except ManifestError as e:
      raised = true
      msg = e.msg
    check raised
    check "missing required key 'header'" in msg

  test "parseManifest: non-object 'header' raises ManifestError naming the symbol":
    let text = """{"schema":1,"lib":"x","harvest":{"abi":"linux-lp64"},
      "corpus":[],"symbols":{"foo":{"header":["not an object"]}}}"""
    var raised = false
    var msg = ""
    try:
      discard parseManifest(text, "bogus.json")
    except ManifestError as e:
      raised = true
      msg = e.msg
    check raised
    check "symbol 'foo'.header must be an object" in msg

  test "parseManifest: non-array fact value raises ManifestError naming the key":
    let text = """{"schema":1,"lib":"x","harvest":{"abi":"linux-lp64"},
      "corpus":[],"symbols":{"foo":{"header":{"verified":"not an array"}}}}"""
    var raised = false
    var msg = ""
    try:
      discard parseManifest(text, "bogus.json")
    except ManifestError as e:
      raised = true
      msg = e.msg
    check raised
    check "symbol 'foo'.header.verified must be an array of intervals" in msg

  test "parseManifest: non-object interval entry raises ManifestError naming the key":
    let text = """{"schema":1,"lib":"x","harvest":{"abi":"linux-lp64"},
      "corpus":[],"symbols":{"foo":{"header":{"verified":["not an object"]}}}}"""
    var raised = false
    var msg = ""
    try:
      discard parseManifest(text, "bogus.json")
    except ManifestError as e:
      raised = true
      msg = e.msg
    check raised
    check "symbol 'foo'.header.verified has a non-object interval entry" in msg

  test "parseManifest: unrecognized fact key raises ManifestError naming it":
    let text = """{"schema":1,"lib":"x","harvest":{"abi":"linux-lp64"},
      "corpus":[],"symbols":{"foo":{"header":{"bogus_kind":[]}}}}"""
    var raised = false
    var msg = ""
    try:
      discard parseManifest(text, "bogus.json")
    except ManifestError as e:
      raised = true
      msg = e.msg
    check raised
    check "has an unrecognized fact key 'bogus_kind'" in msg

  test "parseManifest: control -- a well-formed manifest with all four fact kinds parses cleanly":
    let text = """{"schema":1,"lib":"x","harvest":{"abi":"linux-lp64"},
      "corpus":[{"version":"1.0.0"}],
      "symbols":{"foo":{"header":{
        "verified":[{"lo":"1.0.0"}],
        "absent":[],
        "mismatch":[],
        "unknown":[]
      }}}}"""
    let m = parseManifest(text, "bogus.json")
    check m.symbols.len == 1
    check m.symbols[0].cname == "foo"
