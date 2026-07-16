## `softlink/manifest` — RFC-0001 §B.3/§B.5/§B.5a (slice B6a): parsing and
## the pure, macro-independent predicates behind `compatManifest`'s
## compile-time consumption checks.
##
## Kept separate from `softlink/versions` (the tiny pinned-types module
## both the harvester and this one import) per the slice's design
## guidance: `versions.nim` stays the B0 shape/comparator module; this one
## owns parse + validate + query, and is directly `unittest`-able without
## dragging in `std/macros` — `src/softlink.nim`'s `dynlib`/`verifyProcs`
## macros are the ONLY place severity (error vs warning vs hint) is
## decided, because only they hold the `NimNode` needed to anchor a
## diagnostic. Every proc below returns plain data describing what (if
## anything) is wrong; none of them ever call `macros.error`/`warning`/
## `hint` themselves.
##
## The parsed `CompatManifest.symbols` shape is `seq[SymbolFacts]` — the
## exact B0 type slice B6b will serialize into
## `softlinkCompatFacts<Base>: seq[SymbolFacts]` (RFC §B.5) — so that later
## slice reuses this parse verbatim rather than repeating it.

import std/[json, algorithm, options]
import ./versions

export versions

type
  ManifestError* = object of CatchableError
    ## Raised by `parseManifest` for a structurally malformed manifest —
    ## invalid JSON, or JSON missing a key/shape §B.3's schema requires.
    ## Deliberately NOT raised for the schema-VERSION *policy* question (a
    ## structurally well-formed manifest with an unsupported newer
    ## `schema` value parses fine) — `schemaSupported` below is the
    ## separate, named policy predicate RFC-0001 §B.3 calls for; the two
    ## are different failure modes with different remedies (fix the file
    ## vs. upgrade softlink).

  CompatManifest* = object
    ## The parsed form of one `<lib>.compat.json` (§B.3), using the B0
    ## pinned `SymbolFacts`/`VersionInterval` shape verbatim.
    schema*: int
    lib*: string
    abi*: string
    corpus*: seq[string]      ## corpus version strings, cmpVersion-sorted
    symbols*: seq[SymbolFacts]

const supportedSchema* = 1
  ## RFC-0001 §B.3: "a manifest with an unknown (newer) schema value is a
  ## compile error naming the softlink version required." This IS that
  ## required schema number — bump alongside any future schema change.

func factKindOfKey(key: string): Option[FactKind] =
  case key
  of "verified": some(fkVerified)
  of "absent": some(fkAbsent)
  of "mismatch": some(fkMismatch)
  of "unknown": some(fkUnknown)
  else: none(FactKind)

proc requireKey(node: JsonNode, key, path, ctx: string): JsonNode =
  if node.kind != JObject or not node.hasKey(key):
    raise newException(ManifestError, "softlink: compat manifest " & path &
      ": " & ctx & " missing required key '" & key & "'")
  node[key]

proc parseIntervalArray(node: JsonNode, path, cname, key: string): seq[VersionInterval] =
  if node.kind != JArray:
    raise newException(ManifestError, "softlink: compat manifest " & path &
      ": symbol '" & cname & "'.header." & key & " must be an array of intervals")
  for ivNode in node:
    if ivNode.kind != JObject:
      raise newException(ManifestError, "softlink: compat manifest " & path &
        ": symbol '" & cname & "'.header." & key & " has a non-object interval entry")
    var iv: VersionInterval
    if ivNode.hasKey("lo"): iv.lo = ivNode["lo"].getStr
    if ivNode.hasKey("hi"): iv.hi = ivNode["hi"].getStr
    result.add iv

proc parseManifest*(jsonText, path: string): CompatManifest =
  ## Parses `jsonText` (the manifest file's contents; `path` is used only
  ## to make error messages self-locating — e.g. the resolved absolute
  ## path a `compatManifest` directive already computed) into a
  ## `CompatManifest`. Raises `ManifestError` — never returns a partially-
  ## populated manifest — on any structurally malformed input, per §B.3's
  ## "never a silent partial read".
  var j: JsonNode
  try:
    j = parseJson(jsonText)
  except JsonParsingError as e:
    raise newException(ManifestError,
      "softlink: compat manifest " & path & ": invalid JSON: " & e.msg)
  if j.kind != JObject:
    raise newException(ManifestError,
      "softlink: compat manifest " & path & ": top level must be a JSON object")

  result.schema = requireKey(j, "schema", path, "manifest").getInt
  result.lib = requireKey(j, "lib", path, "manifest").getStr
  let harvestNode = requireKey(j, "harvest", path, "manifest")
  result.abi = requireKey(harvestNode, "abi", path, "manifest.harvest").getStr

  let corpusNode = requireKey(j, "corpus", path, "manifest")
  if corpusNode.kind != JArray:
    raise newException(ManifestError,
      "softlink: compat manifest " & path & ": 'corpus' must be an array")
  var corpusVersions: seq[string] = @[]
  for entry in corpusNode:
    corpusVersions.add requireKey(entry, "version", path, "manifest.corpus[]").getStr
  corpusVersions.sort(cmpVersion)
  result.corpus = corpusVersions

  let symbolsNode = requireKey(j, "symbols", path, "manifest")
  if symbolsNode.kind != JObject:
    raise newException(ManifestError,
      "softlink: compat manifest " & path & ": 'symbols' must be an object")
  for cname, symNode in symbolsNode:
    let headerNode = requireKey(symNode, "header", path, "manifest.symbols." & cname)
    if headerNode.kind != JObject:
      raise newException(ManifestError, "softlink: compat manifest " & path &
        ": symbol '" & cname & "'.header must be an object")
    var sf = SymbolFacts(cname: cname)
    for key, ivArr in headerNode:
      let kindOpt = factKindOfKey(key)
      if kindOpt.isNone:
        raise newException(ManifestError, "softlink: compat manifest " & path &
          ": symbol '" & cname & "'.header has an unrecognized fact key '" & key & "'")
      sf.header[kindOpt.get] = parseIntervalArray(ivArr, path, cname, key)
    result.symbols.add sf

func schemaSupported*(m: CompatManifest): bool =
  ## RFC-0001 §B.3 schema policy: this softlink version supports exactly
  ## `supportedSchema`. A newer, unrecognized value must be a compile
  ## error (never a silent partial read) — checking this explicitly,
  ## rather than merely trusting the shape parsed, is the whole point.
  m.schema == supportedSchema

func libIdentityOk*(m: CompatManifest, expectedLib: string): bool =
  ## RFC-0001 §B.3/§B.5: wrong-file paste protection — a manifest's `lib`
  ## must equal the consuming `dynlib` block's own `toLowerAscii(baseName)`
  ## derivation (the same one `buildManifest` in
  ## `tools/harvest/harvester.nim` uses to produce it). Not meaningful for
  ## `verifyProcs` (no library identity) — callers skip this entirely
  ## there, per §B.5a.
  m.lib == expectedLib

func abiOk*(m: CompatManifest, targetAbi: string): bool =
  ## RFC-0001 §B.3/§B.5: a manifest is valid for exactly one ABI class.
  ## `targetAbi` is the CONSUMING build's own `versions.abiTag()`,
  ## computed the identical way the producer (harvester) computed
  ## `m.abi` — one shared definition, so the two sides cannot drift apart.
  m.abi == targetAbi

func findSymbol*(m: CompatManifest, cname: string): Option[SymbolFacts] =
  for sf in m.symbols:
    if sf.cname == cname: return some(sf)
  none(SymbolFacts)

func anyContains(ivs: seq[VersionInterval], v: string): bool =
  for iv in ivs:
    if iv.contains(v): return true
  false

type
  IntervalViolation* = object
    ## One `(symbol, version)` pair that violates RFC-0001 §B.3's
    ## disjoint/exhaustive invariant. `matchCount` is `0` (the version
    ## sits in NO fact-interval set — a gap) or `>= 2` (it sits in more
    ## than one — an overlap); it is never `1`, since that is the
    ## non-violating case and is not reported.
    cname*, version*: string
    matchCount*: int

func validateDisjointExhaustive*(m: CompatManifest): seq[IntervalViolation] =
  ## RFC-0001 §B.3's disjoint/exhaustive invariant, VALIDATED (not merely
  ## trusted) at consumption time: for every symbol the manifest records
  ## and every version in the manifest's own `corpus`, EXACTLY ONE of the
  ## four `FactKind` interval sets must contain that version. Returns
  ## EVERY violation found, not just the first — a hand-merge mistake
  ## should surface completely in one compile, not one error at a time.
  for sf in m.symbols:
    for v in m.corpus:
      var count = 0
      for kind in FactKind:
        for iv in sf.header[kind]:
          if iv.contains(v): inc count
      if count != 1:
        result.add IntervalViolation(cname: sf.cname, version: v, matchCount: count)

func earliestDeclaredVersion(m: CompatManifest, sf: SymbolFacts): string =
  ## Earliest corpus version (in `m.corpus`'s cmpVersion order — sorted by
  ## `parseManifest` above) whose header fact is `verified` or `mismatch`
  ## — i.e. the earliest version any harvested header actually declares
  ## this symbol at all. `""` if none (no harvested version declares it).
  for v in m.corpus:
    if anyContains(sf.header[fkVerified], v) or anyContains(sf.header[fkMismatch], v):
      return v
  ""

type
  SinceCheck* = object
    ## The result of checking one `{.since: "x.y.z".}` claim against the
    ## manifest's header facts. `message` is populated iff `contradicted`
    ## — a complete, ready-to-report diagnostic string (RFC-0001 §B.5: "the
    ## error message includes the corrected bound").
    contradicted*: bool
    message*: string

proc checkSince*(m: CompatManifest, cname, since: string): SinceCheck =
  ## RFC-0001 §B.5/§C.2: `{.since: since.}` claims `cname` exists from
  ## `since` onward — "a lower bound only" (§C.2). Against the manifest's
  ## header facts over its own corpus:
  ## - contradicted if any corpus version `v >= since` is classified
  ##   `absent` (claimed present, header says otherwise);
  ## - contradicted if any corpus version `v < since` is classified
  ##   `verified` or `mismatch` (the header declares it EARLIER than
  ##   claimed, so the lower bound itself is false);
  ## - `unknown` contributes nothing either way (honest ignorance, mirrors
  ##   C3's runtime partition rule).
  ## No check is possible for a symbol entirely absent from the manifest —
  ## `contradicted` stays false (it counts toward the not-in-manifest hint
  ## instead, `notInManifest` below, computed independently).
  let symOpt = findSymbol(m, cname)
  if symOpt.isNone: return SinceCheck(contradicted: false)
  let sf = symOpt.get

  var badVersion = ""
  var reason = ""
  for v in m.corpus:
    if cmpVersion(v, since) >= 0:
      if anyContains(sf.header[fkAbsent], v):
        badVersion = v
        reason = "absent"
        break
    else:
      if anyContains(sf.header[fkVerified], v):
        badVersion = v
        reason = "verified"
        break
      if anyContains(sf.header[fkMismatch], v):
        badVersion = v
        reason = "mismatch"
        break

  if badVersion.len == 0:
    return SinceCheck(contradicted: false)

  let earliest = earliestDeclaredVersion(m, sf)
  let boundMsg =
    if earliest.len > 0: "the corrected lower bound is " & earliest
    else: "no harvested corpus version declares '" & cname & "' at all"
  let detail =
    if reason == "absent":
      "claims '" & cname & "' exists since " & since & ", but the compat " &
      "manifest's header facts show it ABSENT at " & badVersion
    else:
      "claims '" & cname & "' exists since " & since & ", but the compat " &
      "manifest's header facts already show it " & reason & " at " &
      badVersion & " — earlier than the claimed lower bound"
  SinceCheck(contradicted: true,
    message: "softlink: {.since: \"" & since & "\".} on '" & cname & "' " &
      detail & " (" & boundMsg & ")")

func mismatchedSymbols*(m: CompatManifest, boundCNames: seq[string]): seq[string] =
  ## RFC-0001 §B.5 mismatch warning: which of `boundCNames` (this block's
  ## own header/prototype-verified procs) have any recorded `mismatch`
  ## interval in the manifest — a bound symbol whose Nim signature is
  ## provably wrong somewhere in the harvested corpus.
  for cname in boundCNames:
    let symOpt = findSymbol(m, cname)
    if symOpt.isSome and symOpt.get.header[fkMismatch].len > 0:
      result.add cname

func notInManifest*(m: CompatManifest, boundCNames: seq[string]): seq[string] =
  ## RFC-0001 §B.5 not-in-manifest hint: which of `boundCNames` are
  ## entirely absent from the manifest's own symbol table — a stale
  ## manifest should be visible, not silently permissive. Callers must
  ## restrict `boundCNames` to symbols the harvester would actually track
  ## (excluding `noverify` and prototype-only procs — those are corpus-
  ## invariant and never appear in a manifest by design, see
  ## `tools/harvest/harvester.nim`'s own `harvest` doc comment).
  for cname in boundCNames:
    if findSymbol(m, cname).isNone:
      result.add cname
