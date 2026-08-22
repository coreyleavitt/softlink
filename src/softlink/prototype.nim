## `softlink/prototype` — RFC-0001 §3 A.1 (extended by A6): the vendored
## `{.prototype: "<C prototype>".}` pragma's tokenizer, analyzer, and
## builtin-type classifier. Extracted from `src/softlink.nim` (code-review
## finding #13, a clean seam — none of the procs below close over any
## `dynlib`/`verifyProcs` macro local; every one is a pure function over a
## string or a token stream). Shared by `softlink/pragmas`' `parseProcPragmas`
## (the sole cross-module caller of `parsePrototypePragma`/
## `nonBuiltinIdentifiers`) and unit-tested directly by
## `tests/test_softlink.nim` via `import softlink/prototype {.all.}`.
##
## `tokenizePrototype`/`analyzePrototype` themselves stay module-private
## here, exactly as they were module-private in `softlink.nim` before this
## move — only `parsePrototypePragma` and `nonBuiltinIdentifiers` (the two
## procs a caller outside this file actually needs) are exported.

import std/[macros, strutils, sets]

type
  PrototypeTokenKind = enum
    ## `ptkIdent`: a C identifier (`[A-Za-z_][A-Za-z0-9_]*`) — this includes
    ## C keywords like `const`/`void`; the tokenizer does no declarator-
    ## grammar analysis, so callers filter keywords themselves if needed
    ## (see A6's builtin-type detection).
    ## `ptkPunct`: single-character punctuation (`(`, `)`, `*`, `,`, `;`,
    ## `[`, `]`, ...), or the three-character `...` ellipsis, emitted as one
    ## token.
    ptkIdent
    ptkPunct

  PrototypeToken = object
    ## One token of a tokenized C prototype string. `depth` is the paren
    ## nesting level: for identifiers/other punctuation it's the level the
    ## token sits at; for `(`/`)` it's the level of the group being opened/
    ## closed (i.e. a matching `(`/`)` pair share the same `depth`), so "the
    ## first `(` at paren depth 0" (RFC-0001 §3 A.1) is exactly
    ## `tokens.find(tok => tok.text == "(" and tok.depth == 0)`.
    ## Fields are exported (not the type itself) so the test suite — which
    ## imports this module with `{.all.}` — can unit-test the tokenizer
    ## directly; object field visibility is independent of `{.all.}`.
    kind*: PrototypeTokenKind
    text*: string
    depth*: int

func tokenizePrototype(prototype: string): seq[PrototypeToken] =
  ## Minimal C-prototype tokenizer: identifiers, punctuation, and paren
  ## depth only — no full declarator grammar (RFC-0001 §3 A.1, "round 2"
  ## name-extraction rule). A pure function, reused as-is by two consumers:
  ## A1's name extraction / function-pointer-return / variadic detection
  ## (`analyzePrototype` below), and (later) A6's builtin-type detection,
  ## which scans the same identifier tokens against a builtin-type
  ## allowlist. Whitespace (including embedded newlines/indentation from
  ## triple-quoted, upstream-formatted prototypes) is skipped entirely —
  ## inert for tokenization, exactly as it is in the emitted C.
  var i = 0
  var depth = 0
  let n = prototype.len
  while i < n:
    let c = prototype[i]
    if c in Whitespace:
      inc i
    elif c == '_' or c.isAlphaAscii:
      let start = i
      inc i
      while i < n and (prototype[i] == '_' or prototype[i].isAlphaNumeric):
        inc i
      result.add(PrototypeToken(kind: ptkIdent, text: prototype[start ..< i], depth: depth))
    elif c == '.' and i + 2 < n and prototype[i + 1] == '.' and prototype[i + 2] == '.':
      result.add(PrototypeToken(kind: ptkPunct, text: "...", depth: depth))
      i += 3
    elif c == '(':
      result.add(PrototypeToken(kind: ptkPunct, text: "(", depth: depth))
      inc depth
      inc i
    elif c == ')':
      if depth > 0: dec depth
      result.add(PrototypeToken(kind: ptkPunct, text: ")", depth: depth))
      inc i
    else:
      # Any other single character (`*`, `,`, `;`, `[`, `]`, digits of a
      # numeric literal, ...) — inert for the rules above, emitted
      # one-at-a-time so paren depth stays exact around it.
      result.add(PrototypeToken(kind: ptkPunct, text: $c, depth: depth))
      inc i

type
  PrototypeAnalysis = object
    ## A1-specific analysis over one prototype's token stream. Fields
    ## exported for the same `{.all.}`-import reason as `PrototypeToken`.
    ok*: bool                       ## false: no depth-0 '(' found (malformed)
    name*: string                   ## identifier before the first depth-0 '('
    isFunctionPointerReturn*: bool  ## '(' immediately followed by '*' — name
                                     ## is nested inside the return type
    hasVariadic*: bool              ## a `...` token appears anywhere

func analyzePrototype(prototype: string): PrototypeAnalysis =
  ## Run the shared tokenizer and extract the facts A1's prototype
  ## validation needs: the candidate symbol name, whether the prototype has
  ## a function-pointer return type (name unextractable — the classic
  ## `void (*signal(int, void (*)(int)))(int)` shape), and whether it's
  ## variadic. Pure function over `tokenizePrototype`'s output; kept
  ## separate from the tokenizer itself so A6 can consume the token stream
  ## directly without inheriting A1's naming rules.
  let tokens = tokenizePrototype(prototype)
  var parenIdx = -1
  for idx, tok in tokens:
    if tok.kind == ptkPunct and tok.text == "(" and tok.depth == 0:
      parenIdx = idx
      break
  if parenIdx == -1:
    return PrototypeAnalysis(ok: false)
  result.ok = true
  if parenIdx + 1 < tokens.len and tokens[parenIdx + 1].text == "*":
    result.isFunctionPointerReturn = true
  elif parenIdx > 0 and tokens[parenIdx - 1].kind == ptkIdent:
    result.name = tokens[parenIdx - 1].text
  for tok in tokens:
    if tok.text == "...":
      result.hasVariadic = true
      break

const builtinCTypeKeywords = [
  ## RFC-0001 §3 A.1, slice A6: the C keywords a prototype can use without
  ## needing any header to resolve them — base types, qualifiers, and
  ## storage-adjacent keywords that are part of the C grammar itself
  ## rather than something a header `typedef`s or declares as a struct/
  ## enum tag. Deliberately excludes `size_t`/`ptrdiff_t`/etc. — those are
  ## real typedefs from `<stddef.h>` and friends, not language keywords, so
  ## a prototype using them genuinely does need a header (or at least the
  ## standard one that defines them; softlink does not special-case the
  ## standard library headers per RFC-0001 §3 A.1: "softlink does not
  ## attempt full detection").
  "void", "char", "short", "int", "long", "float", "double",
  "signed", "unsigned", "const", "volatile", "restrict",
  "_Bool", "_Complex", "_Imaginary"
]

func nonBuiltinIdentifiers*(prototype: string): seq[string] =
  ## RFC-0001 §3 A.1, slice A6: scan a vendored prototype for identifiers
  ## that are neither the C builtin-type allowlist above nor (best-effort)
  ## the function name / parameter names, returning them in first-seen
  ## order with duplicates removed. A non-empty result means the prototype
  ## references a typedef/struct/enum tag only a header could define —
  ## exactly the case where dropping `{.header.}` is likely a mistake.
  ##
  ## Reuses the shared A1 tokenizer (`tokenizePrototype`) — "one primitive,
  ## two consumers" per that proc's doc comment. Deliberately NOT a full
  ## declarator parse (RFC: "softlink does not attempt full detection"):
  ## - The return type is every depth-0 token before the first depth-0
  ##   `(`, minus the trailing one (the function name itself — already
  ##   validated elsewhere to match the proc's Nim name).
  ## - Each top-level parameter is a comma-separated span at depth 1
  ##   between the matching parens. Only that parameter's OWN depth-1
  ##   tokens are considered; anything nested deeper (a function-pointer
  ##   parameter's internal parameter list, e.g. the `cb`/`int` inside
  ##   `void (*cb)(int)`) is out of scope and simply not classified —
  ##   erring toward fewer false hints rather than more, on the
  ##   documented assumption that this rare shape is not the common case
  ##   this hint targets.
  ## - Within a parameter's depth-1 tokens, a trailing identifier is
  ##   treated as the parameter's NAME (not its type) whenever something
  ##   else precedes it (`unsigned char y` → `y` is the name); a lone
  ##   identifier with nothing else in the parameter is instead an
  ##   unnamed, typedef'd-type parameter (`Z3_context` alone) and IS
  ##   classified — C prototypes have no other way to write "a single
  ##   bare identifier" in a parameter position.
  let tokens = tokenizePrototype(prototype)
  var parenIdx = -1
  for idx, tok in tokens:
    if tok.kind == ptkPunct and tok.text == "(" and tok.depth == 0:
      parenIdx = idx
      break
  if parenIdx == -1:
    return @[]  # malformed; parsePrototypePragma already reports this

  var seen: HashSet[string]
  template consider(tok: PrototypeToken) =
    if tok.kind == ptkIdent and tok.text notin builtinCTypeKeywords and
       tok.text notin seen:
      seen.incl(tok.text)
      result.add(tok.text)

  # Return-type identifiers: depth-0 tokens before the paren, minus the
  # trailing function-name token.
  for i in 0 ..< parenIdx - 1:
    consider(tokens[i])

  # The matching close paren that returns to depth 0.
  var closeIdx = -1
  for idx in parenIdx + 1 ..< tokens.len:
    if tokens[idx].kind == ptkPunct and tokens[idx].text == ")" and
       tokens[idx].depth == 0:
      closeIdx = idx
      break
  if closeIdx == -1:
    return  # malformed; shouldn't happen once parsePrototypePragma passed

  # Parameter spans: split the range between the parens on depth-1 commas.
  var segStart = parenIdx + 1
  var segments: seq[tuple[a, b: int]]
  for idx in parenIdx + 1 ..< closeIdx:
    if tokens[idx].kind == ptkPunct and tokens[idx].text == "," and
       tokens[idx].depth == 1:
      segments.add((segStart, idx))
      segStart = idx + 1
  segments.add((segStart, closeIdx))

  for (a, b) in segments:
    var depth1: seq[PrototypeToken]
    for idx in a ..< b:
      if tokens[idx].depth == 1: depth1.add(tokens[idx])
    if depth1.len == 0:
      continue
    let dropTrailingName = depth1.len > 1 and depth1[^1].kind == ptkIdent
    let stop = if dropTrailingName: depth1.len - 1 else: depth1.len
    for i in 0 ..< stop:
      consider(depth1[i])

proc parsePrototypePragma*(pragma, stmt: NimNode, nameStr, cName: string): tuple[raw, name: string] =
  ## Extract and validate the `{.prototype: "<C prototype>".}` pragma
  ## (RFC-0001 §3 A.1): a non-empty string literal — triple-quoted/
  ## multi-line strings are explicitly blessed so upstream's own
  ## multi-line formatting can be pasted verbatim — containing a single C
  ## function prototype. Runs the shared tokenizer-based name extraction,
  ## rejects function-pointer return types (name unextractable — route
  ## through a typedef'd return type instead), rejects `...` (variadic —
  ## mirrors the existing `varargs` rejection: C lets you call a variadic
  ## function with only its fixed arguments, so the assert would type-check
  ## without verifying the variadic tail), and requires the extracted name
  ## to match the proc's C name. Shared by `dynlib` and `verifyProcs` —
  ## both select a declaration source on this axis (RFC-0001 §3, "four
  ## pragma axes"). A1 only validates; nothing is emitted from the result
  ## yet (extern declaration + verify-TU wiring is slice A2).
  ##
  ## RFC 0011 S0a item 3: `cName` is the proc's EFFECTIVE C name — `nameStr`
  ## itself unless a `{.symbol: "...".}` rename pragma overrides it (already
  ## resolved by the caller's prescan, `softlink/pragmas.parseProcPragmas`,
  ## by the time this runs — order-independent regardless of where `symbol:`
  ## sits in the proc's own pragma list). The match check below compares
  ## the prototype's extracted name against `cName`, not `nameStr`: a
  ## vendored prototype describes a C declaration, so it must name the same
  ## C symbol the proc actually resolves against, not the Nim identifier
  ## chosen for it. `nameStr` is kept as a separate parameter purely for
  ## diagnostic attribution ("proc 'nameStr': ...").
  if not (pragma.kind == nnkExprColonExpr and
          pragma[1].kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit}):
    error("proc '" & nameStr & "': prototype pragma requires a C prototype " &
          "string literal (e.g., {.prototype: \"int " & nameStr &
          "(int x)\".}); triple-quoted strings are accepted for upstream's " &
          "own multi-line formatting", stmt)
    ("", "")
  else:
    let raw = pragma[1].strVal
    if raw.strip().len == 0:
      error("proc '" & nameStr &
            "': prototype pragma requires a non-empty C prototype string", stmt)
      ("", "")
    else:
      let analysis = analyzePrototype(raw)
      if not analysis.ok:
        error("proc '" & nameStr & "': could not find a top-level '(' " &
              "introducing the parameter list in prototype: " & raw, stmt)
        (raw, "")
      elif analysis.isFunctionPointerReturn:
        error("proc '" & nameStr & "': prototype has a function-pointer " &
              "return type, so its name is nested inside the return type " &
              "(e.g. `void (*signal(int))(int)`) and can't be extracted " &
              "by name — introduce a typedef for the return type and use " &
              "it instead (e.g. `typedef void (*signal_handler)(int); " &
              "signal_handler signal(int)`)", stmt)
        (raw, "")
      elif analysis.hasVariadic:
        error("proc '" & nameStr & "': prototype must not be variadic " &
              "('...') — mirrors the existing varargs rejection: C " &
              "permits calling a variadic function with only its fixed " &
              "arguments, so the compile-time check would type-check " &
              "without verifying the variadic tail; write a prototype " &
              "for the fixed-arity form only", stmt)
        (raw, "")
      elif analysis.name != cName:
        error("proc '" & nameStr & "': prototype declares '" & analysis.name &
              "', which does not match the proc's C name '" & cName &
              "' — the prototype must describe the same C symbol as the " &
              "proc", stmt)
        (raw, "")
      else:
        (raw, analysis.name)
