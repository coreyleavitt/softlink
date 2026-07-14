## softlink — Type-safe optional dynamic library bindings for Nim.
##
## Provides a `dynlib` macro that generates runtime-loadable FFI bindings
## from type-safe proc definitions, a `dyntype` macro for compile-time struct
## layout verification against C headers, and a `verifyProcs` macro that emits
## the same proc-signature verification standalone (for statically-linked
## `{.importc.}` bindings that want softlink's `_Static_assert` checking
## without runtime loading). Solves the Nim ecosystem gap between
## `{.importc, dynlib.}` (type-safe but fatal on missing) and `std/dynlib`
## (optional but loses type safety).

when defined(js):
  {.error: "softlink requires a native backend (C, C++, or Objective-C). The JavaScript backend does not support dynamic library loading.".}

import std/[macros, sets, strutils]
import std/dynlib as stdDynlib
# Exported because macro-generated code resolves these identifiers at the call site.
export stdDynlib.LibHandle, stdDynlib.loadLibPattern, stdDynlib.symAddr,
       stdDynlib.unloadLib

type
  SoftlinkError* = ref object of CatchableError
    ## Raised when calling a function from a library that hasn't been loaded.
    symbol*: string
    library*: string  ## The raw dynlib pattern string (e.g., ``"libm.so(.6|)"``)

  LoadResultKind* = enum
    lrOk             ## All symbols resolved (required + optional)
    lrOkPartial      ## All required resolved, some optional missing
    lrLibNotFound    ## Library .so not found on system
    lrSymbolNotFound ## Required symbol missing, library unloaded

  LoadResult* = object
    case kind*: LoadResultKind
    of lrOkPartial:
      missing*: seq[string]
    of lrSymbolNotFound:
      symbol*: string
    of lrLibNotFound, lrOk:
      discard

# Exported because macro-generated wrapper procs call this by ident at the call site.
proc raiseNotLoaded*(library, symbol: string) {.noreturn, noinline.} =
  raise SoftlinkError(
    msg: library & ": library not loaded, cannot call: " & symbol,
    library: library, symbol: symbol)

func toIncludeDirective(header: string): string =
  ## Convert a header path to a C #include directive.
  ## Supports angle-bracket syntax: ``"<mbedtls/ssl.h>"`` → ``#include <mbedtls/ssl.h>``
  ## and quoted syntax: ``"mbedtls/ssl.h"`` → ``#include "mbedtls/ssl.h"``
  if header.len >= 2 and header[0] == '<' and header[^1] == '>':
    "#include " & header & "\n"
  else:
    "#include \"" & header & "\"\n"

func libNameToIdent(libPattern: string): string =
  ## Derive an identifier base name from a library pattern string.
  ## Strips "lib" prefix, truncates at first dot, removes non-alphanumeric
  ## characters (underscores, hyphens, etc.), and capitalizes.
  ## Examples: "libmbedtls.so(.16|)" → "Mbedtls", "libfoo_bar.so" → "Foobar"
  var name = libPattern
  if name.startsWith("lib"): name = name[3 .. ^1]
  let dotIdx = name.find('.')
  if dotIdx >= 0: name = name[0 ..< dotIdx]
  # Remove non-alnum chars
  var clean = ""
  for c in name:
    if c.isAlphaNumeric: clean.add(c)
  if clean.len > 0:
    clean[0] = clean[0].toUpperAscii()
  clean

type
  LibOs* = enum
    ## Target operating system for library-name derivation. Passed explicitly
    ## (rather than read from `defined()`) so `deriveLibPattern` stays a pure,
    ## per-OS-testable function.
    osLinux, osMacos, osWindows

func deriveLibPattern*(name: string, os: LibOs): string =
  ## Derive the `loadLibPattern` candidate string for a bare logical library
  ## `name` on the given `os` — e.g. ``"z3"`` → ``"libz3.so(|.7|…)"`` on Linux.
  ## The rule is simply "list the plausible on-disk names for this OS"; the
  ## loader tries them in order. A leading ``lib`` is stripped first, so ``"z3"``
  ## and ``"libz3"`` derive identically.
  ##
  ## Covers bare (``libz3.so``) and single-component major sonames
  ## (``libz3.so.4``). Multi-component runtime-only sonames (openSUSE
  ## ``libz3.so.4.15`` with no bare/major symlink) are out of scope — pin those
  ## with the explicit-pattern escape hatch instead of a bare logical name.
  var stem = name
  if stem.startsWith("lib"): stem = stem[3 .. ^1]
  case os
  # Bare ``.so`` first (dev installs carry the unversioned symlink); then
  # descending *single-component* major sonames, since a runtime-only install
  # often ships only ``libfoo.so.N`` with no bare symlink (e.g. Debian
  # ``libz3.so.4``). NOTE: multi-component runtime-only sonames — e.g. openSUSE's
  # ``libz3.so.4.15`` with no bare or single-major symlink — are deliberately
  # NOT enumerated here: an unbounded minor sweep can't be future-proof and
  # would bloat the candidate list. Such installs use the explicit-pattern
  # escape hatch (``dynlib "libz3.so(.4.15|.4|)"``) or the OS loader path.
  of osLinux: "lib" & stem & ".so(|.7|.6|.5|.4|.3|.2|.1)"
  # macOS mirrors Linux: bare ``.dylib`` first, then descending majors
  # (``libz3.4.dylib``), for runtime-only installs lacking the bare symlink.
  of osMacos: "lib" & stem & "(|.7|.6|.5|.4|.3|.2|.1).dylib"
  # Windows is the one platform where the ``lib`` prefix isn't universal
  # (Z3 ships ``libz3.dll``; many projects ship ``z3.dll``). Try both.
  of osWindows: "(lib" & stem & "|" & stem & ").dll"

func isLogicalName*(spec: string): bool =
  ## True when `spec` is a bare logical library name (a plain stem like
  ## ``"z3"`` or ``"libz3"``) rather than an explicit `loadLibPattern` string.
  ## Explicit patterns carry an extension, alternation, or path separator;
  ## logical names carry none. `dynlib` derives per-OS candidates for logical
  ## names and passes explicit patterns through verbatim (the escape hatch).
  '.' notin spec and '(' notin spec and '/' notin spec and '\\' notin spec

func currentLibOs(): LibOs =
  ## The compile-time target OS as a `LibOs`, for use at macro-evaluation time.
  when defined(windows): osWindows
  elif defined(macosx): osMacos
  else: osLinux

type
  SoftlinkProc* = object
    name: NimNode
    nameStr: string
    ptrName: NimNode
    formalParams: NimNode
    callConv: string
    headerFile: string
    isOptional: bool
    noVerify: bool
    verifyWhen: string  ## C preprocessor expr gating verification; "" = always
    hasReturn: bool

func pragmaKeyName(pragma: NimNode): string =
  ## The identifying name of a proc pragma node: bare (`cdecl`) or
  ## key:value (`header: "foo.h"`). "" for shapes we don't recognize.
  if pragma.kind == nnkIdent: $pragma
  elif pragma.kind == nnkExprColonExpr: $pragma[0]
  else: ""

proc parseVerifyWhenExpr(pragma, stmt: NimNode): string =
  ## Extract and validate the {.verifyWhen: "EXPR".} condition — a non-empty
  ## C preprocessor expression string. Shared by `dynlib` and `verifyProcs`.
  if pragma.kind == nnkExprColonExpr and
     pragma[1].kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit} and
     pragma[1].strVal.strip().len > 0:
    pragma[1].strVal
  else:
    error("verifyWhen pragma requires a non-empty C preprocessor " &
          "expression (e.g., {.verifyWhen: \"FOO_VERSION >= 0x0300\".})", stmt)
    ""

proc genVerifyBlock(allProcs: seq[SoftlinkProc], tag: string): seq[NimNode] =
  ## Generate the compile-time C header signature verification nodes
  ## (include section + a file-local _Static_assert proc). Shared by
  ## `dynlib` and `verifyProcs`.
  # {.noverify.} procs are excluded entirely — no _Static_assert AND no
  # #include of their header. A noverify symbol typically doesn't exist in
  # the installed headers (that's why verification is skipped), and its call
  # expression would be an implicit-declaration error in C. See #14/Defect B:
  # {.optional.} alone is runtime-optional but still compile-time verified.
  var procs: seq[SoftlinkProc]
  for p in allProcs:
    if not p.noVerify: procs.add(p)
  if procs.len == 0:
    return @[]
  var nodes: seq[NimNode] = @[]
  # Compile-time header verification. Compares each symbol's type from
  # the C header against Nim's generated function pointer type.
  # Three-tier fallback for maximum compiler compatibility:
  #   1. C23 typeof (standard)
  #   2. __typeof__ (GCC/Clang extension, also MSVC 2022+)
  #   3. C++ decltype + std::is_same (for --backend:cpp)
  # No linking required — pure compile-time check.
  block:
    var headers: HashSet[string]
    var includeCode = ""
    for p in procs:
      if p.headerFile notin headers:
        headers.incl(p.headerFile)
        includeCode.add(toIncludeDirective(p.headerFile))

    # Emit #include directives + C++ type_traits if needed
    nodes.add(newNimNode(nnkPragma).add(
      newNimNode(nnkExprColonExpr).add(
        ident("emit"),
        newStrLitNode("/*INCLUDESECTION*/\n" & includeCode &
          "#if defined(__cplusplus)\n" &
          "#include <type_traits>\n" &
          "#ifndef SOFTLINK_STRIP_PTR_CONST_DEFINED\n" &
          "#define SOFTLINK_STRIP_PTR_CONST_DEFINED 1\n" &
          "template<typename T> struct softlink_strip_ptr_const { typedef T type; };\n" &
          "template<typename T> struct softlink_strip_ptr_const<const T*> { typedef T* type; };\n" &
          "#endif\n" &
          "#endif\n")
      )
    ))

    # Emit per-proc verification inside a dummy proc to ensure the
    # assertions appear after function pointer var declarations in
    # the generated C code (file-scope emit can't reference these vars).
    # NOTE: {.used.} alone is not sufficient — Nim's dead code elimination
    # drops the proc entirely. {.exportc.} forces Nim to emit the proc.
    # {.codegenDecl: "static ...".} makes it file-local in C — no linker
    # collisions, no binary bloat. _Static_assert is evaluated at C
    # compilation time (during gcc -c), before LTO runs at link time —
    # the assertions cannot be eliminated by link-time optimization.
    var verifyBody = newStmtList()
    for p in procs:
      # Generate dummy variables for each param — Nim emits typed C locals.
      # These are passed to the C function call, enabling const-tolerant
      # param checking (int* implicitly converts to const int* in C).
      var dummyVars: seq[NimNode]
      for i in 1 ..< p.formalParams.len:
        let identDefs = p.formalParams[i]
        let paramType = identDefs[^2]  # type is second-to-last
        for j in 0 ..< identDefs.len - 2:  # one var per name
          let dummyName = genSym(nskVar, "softlinkP")
          var varSection = newNimNode(nnkVarSection).add(
            newNimNode(nnkIdentDefs).add(dummyName, paramType.copy(), newEmptyNode())
          )
          # Add {.used, noinit.} pragmas
          let pragmaExpr = newNimNode(nnkPragmaExpr).add(dummyName, newNimNode(nnkPragma).add(
            ident("used"), ident("noinit")
          ))
          varSection[0][0] = pragmaExpr
          verifyBody.add(varSection)
          dummyVars.add(dummyName)

      # Build the call expression arguments for emit: "symbol(p1, p2, ...)"
      # Each dummy var is a Nim node resolved to its C name via emit array.
      let errMsg = "softlink: " & p.nameStr & " signature mismatch vs " & p.headerFile

      # Helper: build the call args portion of emit array
      # Result: [symName, "(", p1, ", ", p2, ", ", ..., ")"]
      proc buildCallArgs(emitArr: var NimNode, symName: string, vars: seq[NimNode]) =
        emitArr.add(newStrLitNode(symName & "("))
        for i, v in vars:
          if i > 0: emitArr.add(newStrLitNode(", "))
          emitArr.add(v)
        emitArr.add(newStrLitNode(")"))

      # Helper: add a type node to emit array, handling compound nodes
      # like nnkPtrTy that the C emitter can't render directly.
      proc addTypeToEmit(emitArr: var NimNode, typeNode: NimNode) =
        if typeNode.kind == nnkPtrTy:
          addTypeToEmit(emitArr, typeNode[0])
          emitArr.add(newStrLitNode("*"))
        else:
          emitArr.add(typeNode.copy())

      var emitArray = newNimNode(nnkBracket)

      # {.verifyWhen: "EXPR".}: gate this proc's entire verification (all
      # three compiler tiers AND the strict-mode #error fallback) on a C
      # preprocessor expression — verify on systems whose headers are new
      # enough, compile cleanly on older ones. When the condition is false,
      # skipping is legitimate, so strict mode must not fire either.
      if p.verifyWhen.len > 0:
        emitArray.add(newStrLitNode(
          "\n#if (" & p.verifyWhen & ") /* softlink verifyWhen */"))

      # --- C++ path: static_assert + strip_ptr_const + decltype ---
      # strip_ptr_const removes const from pointed-to types in return values
      emitArray.add(newStrLitNode(
        "\n#if defined(__cplusplus)\nstatic_assert(\n  std::is_same<\n" &
        "    typename softlink_strip_ptr_const<decltype("))
      buildCallArgs(emitArray, p.nameStr, dummyVars)
      emitArray.add(newStrLitNode(")>::type,\n    "))
      if p.hasReturn:
        addTypeToEmit(emitArray, p.formalParams[0])
      else:
        emitArray.add(newStrLitNode("void"))
      emitArray.add(newStrLitNode(
        ">::value,\n  \"" & errMsg & "\"\n);\n"))

      # --- GCC/Clang path: __builtin_types_compatible_p + __typeof__ ---
      # For pointer returns, dereference both sides so __builtin_types_compatible_p
      # strips top-level const (e.g., const unsigned char* → const unsigned char,
      # then ignoring qualifiers matches unsigned char). No linker dependency —
      # __typeof__ is purely compile-time.
      #
      # "Pointer return" here covers both `ptr T` (nnkPtrTy in Nim AST) and
      # Nim's pointer-typed aliases that aren't structurally nnkPtrTy but
      # emit as pointer types in C (`cstring` → `char*`, `cstringArray` →
      # `char**`, `pointer` → `void*`). Without the alias check, a proc
      # returning `cstring` against a C function declared `const char *`
      # (e.g., libc's `strerror`, libz3's `Z3_string`) is rejected as a
      # signature mismatch even though it's a perfectly valid binding —
      # see #11.
      let retIsPointerLike =
        p.hasReturn and (
          p.formalParams[0].kind == nnkPtrTy or
          (p.formalParams[0].kind in {nnkIdent, nnkSym} and
           $p.formalParams[0] in ["cstring", "cstringArray", "pointer"]))
      emitArray.add(newStrLitNode(
        "#elif defined(__GNUC__)\n_Static_assert(\n  __builtin_types_compatible_p(\n    __typeof__("))
      if retIsPointerLike:
        emitArray.add(newStrLitNode("*"))
      buildCallArgs(emitArray, p.nameStr, dummyVars)
      emitArray.add(newStrLitNode("),\n    "))
      if p.hasReturn:
        if retIsPointerLike:
          emitArray.add(newStrLitNode("__typeof__(*("))
          addTypeToEmit(emitArray, p.formalParams[0])
          emitArray.add(newStrLitNode(")0)"))
        else:
          addTypeToEmit(emitArray, p.formalParams[0])
      else:
        emitArray.add(newStrLitNode("void"))
      emitArray.add(newStrLitNode(
        "),\n  \"" & errMsg & "\"\n);\n"))

      # --- MSVC C path: _Generic + __typeof__ (C23 only) ---
      # MSVC only exposes _Generic and __typeof__ in C23 mode (/std:clatest), so
      # gate the whole branch on __STDC_VERSION__ >= C23. In default mode MSVC
      # doesn't even recognize _Generic — it parses as a call and errors with
      # C2059/C2275 — so without the gate every pointer-returning proc breaks the
      # build. Gated, default-mode MSVC instead falls through to the graceful
      # fallback below (no verification, but the build works). CI forces
      # /std:clatest + -d:softlinkStrictVerify so the check is genuinely exercised
      # there and can't be silently skipped (see the fallback). For pointer
      # returns the same dereference trick as the GCC path strips pointee const;
      # `retIsPointerLike` classifies cstring/cstringArray/pointer with nnkPtrTy.
      emitArray.add(newStrLitNode(
        "#elif defined(_MSC_VER) && defined(__STDC_VERSION__) && __STDC_VERSION__ >= 202311L\n"))
      if retIsPointerLike:
        # Pointer return: dereference BOTH the return value and the declared
        # return type inside _Generic. _Generic applies lvalue conversion to its
        # controlling expression, which drops the pointee's top-level const —
        # so `*(__typeof__(f()))0` (type `const char`) converts to `char` and
        # matches the association `__typeof__(*(RET)0)` (`char`). This is the
        # same const-tolerant trick the GCC path (`__builtin_types_compatible_p`
        # on dereferenced operands) and the C++ path (`strip_ptr_const`) use, and
        # it reuses the identical `__typeof__(*(RET)0)` construct emitted above.
        # Before this, the branch compared `const char**` (from
        # `(__typeof__(f())*)0`) against `char**` and rejected every
        # `const char *`-returning proc — e.g. libz3's `Z3_string` (#11 on MSVC).
        emitArray.add(newStrLitNode(
          "_Static_assert(\n  _Generic(*(__typeof__("))
        buildCallArgs(emitArray, p.nameStr, dummyVars)
        emitArray.add(newStrLitNode("))0,\n    __typeof__(*("))
        addTypeToEmit(emitArray, p.formalParams[0])
        emitArray.add(newStrLitNode(
          ")0): 1, default: 0),\n  \"" & errMsg & "\"\n);\n"))
      else:
        # Non-pointer: call + _Generic __typeof__ pointer trick
        buildCallArgs(emitArray, p.nameStr, dummyVars)
        emitArray.add(newStrLitNode(";\n_Static_assert(\n  _Generic((__typeof__("))
        buildCallArgs(emitArray, p.nameStr, dummyVars)
        emitArray.add(newStrLitNode(")*)0,\n    "))
        if p.hasReturn:
          addTypeToEmit(emitArray, p.formalParams[0])
        else:
          emitArray.add(newStrLitNode("void"))
        emitArray.add(newStrLitNode(
          "*: 1, default: 0),\n  \"" & errMsg & "\"\n);\n"))

      # --- Fallback: graceful degradation ---
      # Compile-time signature verification is best-effort: it must never break an
      # otherwise-valid build. On a compiler/mode lacking the needed features —
      # notably default-mode MSVC, where _Generic/__typeof__ are unavailable — emit
      # nothing (the runtime FFI machinery is generated separately and is
      # unaffected). Opt into a hard error with `-d:softlinkStrictVerify` so a
      # silently-skipped check can't pass unnoticed; CI sets it (with the std flag
      # that opens the MSVC gate above) to guarantee the check is exercised.
      when defined(softlinkStrictVerify):
        emitArray.add(newStrLitNode(
          "#else\n#error \"softlink: signature verification unavailable here " &
          "(need C++, GCC/Clang, or MSVC /std:clatest); remove -d:softlinkStrictVerify to skip\"\n#endif\n"))
      else:
        emitArray.add(newStrLitNode(
          "#else\n/* softlink: signature verification skipped — unsupported compiler/mode */\n#endif\n"))

      if p.verifyWhen.len > 0:
        emitArray.add(newStrLitNode("#endif /* softlink verifyWhen */\n"))

      verifyBody.add(newNimNode(nnkPragma).add(
        newNimNode(nnkExprColonExpr).add(
          ident("emit"),
          emitArray
        )
      ))

    let verifyProcName = ident("softlinkVerify" & tag)
    var verifyProc = newProc(
      name = verifyProcName,
      body = verifyBody,
    )
    verifyProc.addPragma(ident("exportc"))
    # codegenDecl chooses the storage-class qualifier for the verify proc:
    #
    # - **C backend** (`nim c`): `static` gives the function internal
    #   linkage (file scope, no symbol exported, no linker collisions
    #   when the same dynlib block appears in multiple TUs).
    #
    # - **C++ backend** (`nim cpp`): `static` cannot appear inside a
    #   linkage specification per C++ [dcl.link]/4. Because Nim's
    #   `{.exportc.}` emits `extern "C" ...` under cpp, combining with
    #   `static` produces `extern "C" static void ...` which g++/clang++
    #   reject. `inline` is the C++ equivalent: ODR-relaxed (multiple
    #   definitions across TUs are merged) and compatible with
    #   `extern "C"`. The verify proc only contains compile-time
    #   `_Static_assert` / `static_assert`s, so no runtime overhead
    #   distinguishes the two. See #12.
    let codegenTemplate =
      when defined(cpp): "inline $# $#$#"
      else: "static $# $#$#"
    verifyProc.addPragma(newNimNode(nnkExprColonExpr).add(
      ident("codegenDecl"),
      newStrLitNode(codegenTemplate)
    ))
    nodes.add(verifyProc)
  return nodes

macro dynlib*(libPattern: static[string], body: untyped): untyped =
  ## Generate type-safe, runtime-optional bindings for a dynamic library.
  ## The generated ``loadXxx``/``unloadXxx`` procs are **not thread-safe**.
  ## Wrapper proc calls must also not race with ``unloadXxx`` — the loaded
  ## state and function pointer dispatch are not atomic.
  ## Callers must synchronize externally if using from multiple threads.
  ##
  ## `libPattern` may be a bare logical name (``"z3"``), in which case the
  ## per-OS candidate names are derived automatically (see `deriveLibPattern`);
  ## or an explicit `loadLibPattern` string (``"libz3.so(.4|)"``), used verbatim.
  ##
  ## Per-proc pragmas: a calling convention (required), ``header`` (required
  ## unless ``noverify``), ``optional`` (symbol may be missing at runtime),
  ## ``verifyWhen: "C_PP_EXPR"`` (verify only when the preprocessor condition
  ## holds — for symbols newer than some installed headers), and ``noverify``
  ## (skip verification — for symbols no header declares).
  let resolvedPattern =
    if libPattern.isLogicalName: deriveLibPattern(libPattern, currentLibOs())
    else: libPattern
  # Derive the ident base from the *logical* name (the macro argument), NOT the
  # OS-expanded pattern: deriveLibPattern's Windows form "(libz3|z3).dll" would
  # mangle through libNameToIdent to "Libz3z3", breaking cross-OS ident
  # stability (loadLibz3z3 on Windows vs loadZ3 elsewhere). Using libPattern
  # makes the generated idents identical across every target by construction.
  # (For explicit patterns, resolvedPattern == libPattern, so this is a no-op.)
  let baseName = libNameToIdent(libPattern)
  if baseName.len == 0:
    error("cannot derive identifier from dynlib pattern '" & libPattern & "'", body)
  if not baseName[0].isAlphaAscii:
    error("dynlib pattern '" & libPattern & "' produces invalid identifier '" &
          baseName & "' (must start with a letter)", body)
  let baseNameLower = baseName.toLowerAscii()
  let loadProcName = ident("load" & baseName)
  let unloadProcName = ident("unload" & baseName)
  let loadedProcName = ident(baseNameLower & "Loaded")
  let handleName = ident("softlinkHandle" & baseName)
  let cachedResultName = ident("softlinkResult" & baseName)
  let libPatternLit = newStrLitNode(resolvedPattern)

  result = newStmtList()

  # Duplicate-block guard. Two dynlib blocks whose patterns derive the same
  # ident base (e.g. `dynlib "m"` twice, or "libfoo.so" + "foo") would
  # re-declare every module-scope state var and public proc, surfacing as an
  # opaque "redefinition of 'softlinkHandleX'" pointing INTO softlink.nim.
  # `declared()` is evaluated in the expansion scope at semantic time — before
  # this block's own declarations below — so it fires exactly when a previous
  # expansion in the same scope already claimed the names, and stays silent
  # across modules (the state vars are not exported). See #14/Defect A.
  block:
    let dupMsg = "softlink: dynlib block for '" & libPattern &
      "' collides with an earlier dynlib block in the same scope (both " &
      "derive the identifier base '" & baseName & "' → load" & baseName &
      ", softlinkHandle" & baseName & ", ...). Merge the procs into the " &
      "earlier block; mark symbols that may be missing at runtime " &
      "{.optional.}, adding {.noverify.} if a symbol is also absent from " &
      "the installed C headers."
    var errPragma = newNimNode(nnkPragma).add(
      newNimNode(nnkExprColonExpr).add(ident("error"), newStrLitNode(dupMsg)))
    errPragma.copyLineInfo(body)
    result.add(newNimNode(nnkWhenStmt).add(
      newNimNode(nnkElifBranch).add(
        newCall(ident("declared"), handleName),
        newStmtList(errPragma))))

  # var handle: LibHandle
  result.add(newNimNode(nnkVarSection).add(
    newNimNode(nnkIdentDefs).add(
      handleName,
      ident("LibHandle"),
      newEmptyNode()
    )
  ))

  # var cachedResult: LoadResult — zero-initializes to lrOk, but the
  # idempotent guard checks the handle (nil before first load), so
  # this value is never returned to callers before loadXxx runs.
  result.add(newNimNode(nnkVarSection).add(
    newNimNode(nnkIdentDefs).add(
      cachedResultName,
      ident("LoadResult"),
      newEmptyNode()
    )
  ))

  # Collect proc info and generate pointer vars
  const callingConventions = ["cdecl", "stdcall", "fastcall", "syscall", "noconv"]


  var procs: seq[SoftlinkProc]
  var seenNames: HashSet[string]

  for stmt in body:
    if stmt.kind != nnkProcDef:
      error("dynlib body must contain only proc declarations", stmt)

    let procName = stmt[0]
    let nameStr = $procName
    let ptrName = ident("softlinkFp" & baseName & nameStr)
    let formalParams = stmt[3]
    let hasReturn = formalParams[0].kind != nnkEmpty

    # Duplicate detection
    if nameStr in seenNames:
      error("duplicate proc '" & nameStr & "' in dynlib block", stmt)
    seenNames.incl(nameStr)

    # Pragma validation: extract calling convention, optional flag, noverify
    # flag, and header
    var callConv = ""
    var isOptional = false
    var noVerify = false
    var verifyWhen = ""
    var headerFile = ""
    let pragmas = stmt[4]
    if pragmas.kind == nnkPragma:
      for pragma in pragmas:
        let pragmaName = pragmaKeyName(pragma)
        if pragmaName in callingConventions:
          if callConv != "":
            error("proc '" & nameStr & "' has multiple calling conventions", stmt)
          callConv = pragmaName
        elif pragmaName == "optional":
          isOptional = true
        elif pragmaName == "noverify":
          noVerify = true
        elif pragmaName == "verifyWhen":
          verifyWhen = parseVerifyWhenExpr(pragma, stmt)
        elif pragmaName == "header":
          if pragma.kind == nnkExprColonExpr:
            headerFile = pragma[1].strVal
          else:
            error("header pragma requires a value (e.g., {.header: \"foo.h\".})", stmt)
        elif pragmaName != "":
          error("dynlib does not support pragma '" & pragmaName &
                "' on proc '" & nameStr & "'", stmt)

    if callConv == "":
      error("proc '" & nameStr &
            "' must specify a calling convention pragma (e.g., {.cdecl.})", stmt)
    if noVerify and verifyWhen.len > 0:
      error("proc '" & nameStr & "': {.verifyWhen.} contradicts {.noverify.} — " &
            "one requests conditional verification, the other none. Use " &
            "verifyWhen alone for symbols the header declares only in some " &
            "versions, or noverify alone for symbols no header declares", stmt)
    if headerFile == "" and not noVerify:
      error("proc '" & nameStr &
            "' must specify a header pragma (e.g., {.header: \"foo.h\".}), " &
            "or {.noverify.} to skip compile-time header verification", stmt)

    procs.add(SoftlinkProc(name: procName, nameStr: nameStr, ptrName: ptrName,
                        formalParams: formalParams, callConv: callConv,
                        headerFile: headerFile, isOptional: isOptional,
                        noVerify: noVerify, verifyWhen: verifyWhen,
                        hasReturn: hasReturn))

    # Build proc type for the var — C functions can't raise Nim exceptions
    var procTy = newNimNode(nnkProcTy)
    procTy.add(formalParams.copy())
    procTy.add(newNimNode(nnkPragma).add(
      ident(callConv),
      newNimNode(nnkExprColonExpr).add(
        ident("raises"),
        newNimNode(nnkBracket)
      )
    ))

    # var fpXxx: proc(...) {.callConv.}
    result.add(newNimNode(nnkVarSection).add(
      newNimNode(nnkIdentDefs).add(
        ptrName,
        procTy,
        newEmptyNode()
      )
    ))

  # Visibility for trust points: enumerate {.noverify.} symbols at compile
  # time so audits don't depend on grepping source. A hint in normal builds,
  # upgraded to a warning under -d:softlinkStrictVerify — audit mode wants
  # loudness, but an explicit opt-out must not fail the build. verifyWhen
  # procs get no diagnostic: their status is decided by the C preprocessor
  # and the pragma documents itself at the declaration site.
  block:
    var unverified: seq[string]
    for p in procs:
      if p.noVerify: unverified.add(p.nameStr)
    if unverified.len > 0:
      let msg = "softlink: dynlib \"" & libPattern & "\": " &
        $unverified.len & (if unverified.len == 1: " symbol" else: " symbols") &
        " not header-verified ({.noverify.}): " & unverified.join(", ")
      when defined(softlinkStrictVerify):
        warning(msg, body)
      else:
        hint(msg, body)

  for verifyNode in genVerifyBlock(procs, baseName):
    result.add(verifyNode)

  # loadXxx*(): LoadResult
  block:
    var hasOptional = false
    for p in procs:
      if p.isOptional: hasOptional = true; break
    var loadBody = newStmtList()
    let missingName = ident("softlinkMissing")

    # if not handle.isNil: return cachedResult
    loadBody.add(newIfStmt((
      prefix(newCall(ident("isNil"), handleName), "not"),
      newStmtList(newNimNode(nnkReturnStmt).add(cachedResultName))
    )))

    # handle = loadLibPattern(pattern)
    loadBody.add(newAssignment(handleName, newCall(ident("loadLibPattern"), libPatternLit)))

    # if handle.isNil: return LoadResult(kind: lrLibNotFound)
    loadBody.add(newIfStmt((
      newCall(ident("isNil"), handleName),
      newStmtList(newNimNode(nnkReturnStmt).add(
        newNimNode(nnkObjConstr).add(
          ident("LoadResult"),
          newNimNode(nnkExprColonExpr).add(ident("kind"), ident("lrLibNotFound"))
        )
      ))
    )))

    # Collect temp sym names for deferred assignment
    type SymInfo = object
      ptrName: NimNode
      tempSym: NimNode
      procTy: NimNode
      isOptional: bool

    var syms: seq[SymInfo]

    # Phase 1: Resolve all REQUIRED symbols into temp vars
    for p in procs:
      if p.isOptional: continue
      let symName = newStrLitNode(p.nameStr)
      let tempSym = genSym(nskLet, "sym")

      var procTy = newNimNode(nnkProcTy)
      procTy.add(p.formalParams.copy())
      procTy.add(newNimNode(nnkPragma).add(
        ident(p.callConv),
        newNimNode(nnkExprColonExpr).add(
          ident("raises"), newNimNode(nnkBracket)
        )
      ))

      # let sym = handle.symAddr("name")
      loadBody.add(newLetStmt(tempSym, newCall(ident("symAddr"), handleName, symName)))

      # if sym.isNil: unload + nil handle + return lrSymbolNotFound
      var cleanupBlock = newStmtList()
      cleanupBlock.add(newCall(ident("unloadLib"), handleName))
      cleanupBlock.add(newAssignment(handleName, newNilLit()))
      cleanupBlock.add(newNimNode(nnkReturnStmt).add(
        newNimNode(nnkObjConstr).add(
          ident("LoadResult"),
          newNimNode(nnkExprColonExpr).add(ident("kind"), ident("lrSymbolNotFound")),
          newNimNode(nnkExprColonExpr).add(ident("symbol"), symName)
        )
      ))
      loadBody.add(newIfStmt((newCall(ident("isNil"), tempSym), cleanupBlock)))

      syms.add(SymInfo(ptrName: p.ptrName, tempSym: tempSym, procTy: procTy, isOptional: false))

    # Phase 2: Resolve all OPTIONAL symbols into temp vars
    if hasOptional:
      loadBody.add(newNimNode(nnkVarSection).add(
        newNimNode(nnkIdentDefs).add(
          missingName,
          newNimNode(nnkBracketExpr).add(ident("seq"), ident("string")),
          newEmptyNode()
        )
      ))

    for p in procs:
      if not p.isOptional: continue
      let symName = newStrLitNode(p.nameStr)
      let tempSym = genSym(nskLet, "sym")

      var procTy = newNimNode(nnkProcTy)
      procTy.add(p.formalParams.copy())
      procTy.add(newNimNode(nnkPragma).add(
        ident(p.callConv),
        newNimNode(nnkExprColonExpr).add(
          ident("raises"), newNimNode(nnkBracket)
        )
      ))

      # let sym = handle.symAddr("name")
      loadBody.add(newLetStmt(tempSym, newCall(ident("symAddr"), handleName, symName)))

      # if sym.isNil: missing.add(name)
      loadBody.add(newIfStmt((
        newCall(ident("isNil"), tempSym),
        newStmtList(newCall(newDotExpr(missingName, ident("add")), symName))
      )))

      syms.add(SymInfo(ptrName: p.ptrName, tempSym: tempSym, procTy: procTy, isOptional: true))

    # Phase 3: Assign all resolved pointers
    for s in syms:
      if s.isOptional:
        # if not sym.isNil: fp = cast[ProcType](sym)
        loadBody.add(newIfStmt((
          prefix(newCall(ident("isNil"), s.tempSym), "not"),
          newStmtList(newAssignment(s.ptrName, newNimNode(nnkCast).add(s.procTy, s.tempSym)))
        )))
      else:
        # Required: guaranteed non-nil by Phase 1 early-return on failure
        loadBody.add(newAssignment(s.ptrName, newNimNode(nnkCast).add(s.procTy, s.tempSym)))

    # Cache and return result
    if hasOptional:
      # if missing.len > 0: cache lrOkPartial else: cache lrOk
      var cacheIfElse = newNimNode(nnkIfStmt)
      cacheIfElse.add(newNimNode(nnkElifBranch).add(
        newNimNode(nnkInfix).add(ident(">"),
          newDotExpr(missingName, ident("len")),
          newIntLitNode(0)),
        newStmtList(newAssignment(cachedResultName,
          newNimNode(nnkObjConstr).add(
            ident("LoadResult"),
            newNimNode(nnkExprColonExpr).add(ident("kind"), ident("lrOkPartial")),
            newNimNode(nnkExprColonExpr).add(ident("missing"), missingName)
          )
        ))
      ))
      cacheIfElse.add(newNimNode(nnkElse).add(
        newStmtList(newAssignment(cachedResultName,
          newNimNode(nnkObjConstr).add(
            ident("LoadResult"),
            newNimNode(nnkExprColonExpr).add(ident("kind"), ident("lrOk"))
          )
        ))
      ))
      loadBody.add(cacheIfElse)
    else:
      # cache lrOk
      loadBody.add(newAssignment(cachedResultName,
        newNimNode(nnkObjConstr).add(
          ident("LoadResult"),
          newNimNode(nnkExprColonExpr).add(ident("kind"), ident("lrOk"))
        )
      ))

    # return cachedResult
    loadBody.add(newNimNode(nnkReturnStmt).add(cachedResultName))

    result.add(newProc(
      name = postfix(loadProcName, "*"),
      params = [ident("LoadResult")],
      body = loadBody,
    ))

  # unloadXxx*()
  block:
    var unloadBody = newStmtList()
    var ifBody = newStmtList()
    ifBody.add(newCall(ident("unloadLib"), handleName))
    ifBody.add(newAssignment(handleName, newNilLit()))
    for p in procs:
      ifBody.add(newAssignment(p.ptrName, newNilLit()))
    # Reset cached result. The value doesn't matter because the idempotent
    # guard in loadXxx checks the handle (now nil), so it will recompute.
    ifBody.add(newAssignment(cachedResultName,
      newNimNode(nnkObjConstr).add(
        ident("LoadResult"),
        newNimNode(nnkExprColonExpr).add(ident("kind"), ident("lrOk"))
      )
    ))
    unloadBody.add(newIfStmt((
      prefix(newCall(ident("isNil"), handleName), "not"),
      ifBody
    )))

    result.add(newProc(
      name = postfix(unloadProcName, "*"),
      body = unloadBody,
    ))

  # xxxLoaded*(): bool
  result.add(newProc(
    name = postfix(loadedProcName, "*"),
    params = [ident("bool")],
    body = newStmtList(prefix(newCall(ident("isNil"), handleName), "not")),
  ))

  # Wrapper procs
  for p in procs:
    let nameStr = newStrLitNode(p.nameStr)

    # Build arg list for forwarding call
    var callNode = newCall(p.ptrName)
    for i in 1 ..< p.formalParams.len:
      let identDefs = p.formalParams[i]
      for j in 0 ..< identDefs.len - 2:
        callNode.add(identDefs[j].copy())

    # nil check + call
    var wrapperBody = newStmtList()
    wrapperBody.add(newIfStmt((
      newCall(ident("isNil"), p.ptrName),
      newStmtList(newCall(ident("raiseNotLoaded"), libPatternLit, nameStr))
    )))

    if p.hasReturn:
      wrapperBody.add(newNimNode(nnkReturnStmt).add(callNode))
    else:
      wrapperBody.add(callNode)

    var params: seq[NimNode]
    for i in 0 ..< p.formalParams.len:
      params.add(p.formalParams[i].copy())

    var wrapperProc = newProc(
      name = postfix(p.name.copy(), "*"),
      params = params,
      body = wrapperBody,
    )
    wrapperProc.addPragma(newNimNode(nnkExprColonExpr).add(
      ident("raises"),
      newNimNode(nnkBracket).add(ident("SoftlinkError"))
    ))
    result.add(wrapperProc)

    # xxxAvailable*(): bool for optional symbols
    if p.isOptional:
      let availName = ident(p.nameStr & "Available")
      result.add(newProc(
        name = postfix(availName, "*"),
        params = [ident("bool")],
        body = newStmtList(prefix(newCall(ident("isNil"), p.ptrName), "not")),
      ))

    # xxxPtr*(): proc type — typed function pointer for C callback passing.
    # Returns the dlsym'd pointer directly (nil if not loaded). No nil
    # check — the load function is the single enforcement point.
    # Return type matches the function pointer variable's type (cdecl + raises: [])
    # so callers get type safety without the wrapper's SoftlinkError raises.
    let ptrAccessorName = ident(p.nameStr & "Ptr")
    var ptrReturnType = newNimNode(nnkProcTy)
    ptrReturnType.add(p.formalParams.copy())
    ptrReturnType.add(newNimNode(nnkPragma).add(
      ident(p.callConv),
      newNimNode(nnkExprColonExpr).add(
        ident("raises"), newNimNode(nnkBracket)
      )
    ))
    var ptrAccessorProc = newProc(
      name = postfix(ptrAccessorName, "*"),
      params = [ptrReturnType],
      body = newStmtList(p.ptrName),
    )
    ptrAccessorProc.addPragma(newNimNode(nnkExprColonExpr).add(
      ident("raises"),
      newNimNode(nnkBracket)
    ))
    result.add(ptrAccessorProc)

proc collectVProcs(body: NimNode): seq[SoftlinkProc] =
  ## Parse a block of proc declarations for verification. Each must carry a
  ## calling convention and a {.header.} pragma (same rules as `dynlib`).
  const callingConventions = ["cdecl", "stdcall", "fastcall", "syscall", "noconv"]
  var seenNames: HashSet[string]
  for stmt in body:
    if stmt.kind != nnkProcDef:
      error("verifyProcs body must contain only proc declarations", stmt)
    let procName = stmt[0]
    let nameStr = $procName
    let formalParams = stmt[3]
    let hasReturn = formalParams[0].kind != nnkEmpty
    if nameStr in seenNames:
      error("duplicate proc '" & nameStr & "' in verifyProcs block", stmt)
    seenNames.incl(nameStr)
    var callConv = ""
    var headerFile = ""
    var verifyWhen = ""
    let pragmas = stmt[4]
    if pragmas.kind == nnkPragma:
      for pragma in pragmas:
        let pragmaName = pragmaKeyName(pragma)
        if pragmaName in callingConventions:
          callConv = pragmaName
        elif pragmaName == "header":
          if pragma.kind == nnkExprColonExpr:
            headerFile = pragma[1].strVal
          else:
            error("header pragma requires a value (e.g., {.header: \"foo.h\".})", stmt)
        elif pragmaName == "verifyWhen":
          verifyWhen = parseVerifyWhenExpr(pragma, stmt)
        elif pragmaName == "noverify":
          error("noverify is meaningless in verifyProcs — the block exists " &
                "solely to verify; simply omit proc '" & nameStr & "'", stmt)
        elif pragmaName != "":
          error("verifyProcs does not support pragma '" & pragmaName &
                "' on proc '" & nameStr & "'", stmt)
    if callConv == "":
      error("proc '" & nameStr & "' must specify a calling convention pragma (e.g., {.cdecl.})", stmt)
    if headerFile == "":
      error("proc '" & nameStr & "' must specify a header pragma (e.g., {.header: \"foo.h\".})", stmt)
    result.add(SoftlinkProc(name: procName, nameStr: nameStr, ptrName: procName,
      formalParams: formalParams, callConv: callConv, headerFile: headerFile,
      isOptional: false, verifyWhen: verifyWhen, hasReturn: hasReturn))

macro verifyProcs*(body: untyped): untyped =
  ## Emit ONLY compile-time C header signature verification for the given proc
  ## declarations \u2014 no loading, no wrappers, no runtime footprint. Each proc
  ## needs a calling convention and a {.header.} pragma, exactly like `dynlib`.
  ##
  ## Use this to give statically-linked `{.importc.}` bindings the same
  ## `_Static_assert`-grade signature checking that `dynlib` performs for
  ## dynamic ones. This is identity-coherent with softlink: it *verifies* FFI
  ## signatures against headers; it does not perform static linking.
  let procs = collectVProcs(body)
  let tag = if procs.len > 0: procs[0].nameStr else: "anon"
  result = newStmtList()
  for n in genVerifyBlock(procs, tag):
    result.add(n)

macro dyntype*(headerFile: static[string], body: untyped): untyped =
  ## Verify Nim struct layouts match C header struct definitions at compile time.
  ## Emits ``_Static_assert(sizeof(NimType) == sizeof(CType))`` for each type.
  if headerFile.len == 0:
    error("dyntype requires a header file path", body)

  result = newStmtList()

  type TypeInfo = object
    nimName: NimNode
    ctype: string

  var types: seq[TypeInfo]
  var seenNames: HashSet[string]

  for stmt in body:
    if stmt.kind != nnkTypeSection:
      error("dyntype body must contain only type definitions", stmt)

    # Extract type info and strip ctype pragma before passing through
    let cleanStmt = stmt.copy()
    for i, typeDef in cleanStmt:
      # Unwrap PragmaExpr and nnkPostfix (exported types: type Foo* = ...)
      var rawName = if typeDef[0].kind == nnkPragmaExpr: typeDef[0][0]
                    else: typeDef[0]
      let nimName = if rawName.kind == nnkPostfix: rawName[1]
                    else: rawName
      let nameStr = $nimName

      # Duplicate detection
      if nameStr in seenNames:
        error("duplicate type '" & nameStr & "' in dyntype block", typeDef)
      seenNames.incl(nameStr)

      var ctype = ""

      # Check pragmas for ctype
      if typeDef[0].kind == nnkPragmaExpr:
        let pragmas = typeDef[0][1]
        for pragma in pragmas:
          if pragma.kind == nnkExprColonExpr and $pragma[0] == "ctype":
            ctype = pragma[1].strVal
          else:
            let pname = pragmaKeyName(pragma)
            if pname != "":
              error("dyntype does not support pragma '" & pname &
                    "' on type '" & $nimName & "'", pragma)

        # Strip the ctype pragma — replace PragmaExpr with rawName
        # (preserves nnkPostfix for exported types)
        cleanStmt[i][0] = rawName

      if ctype == "":
        error("type '" & $nimName &
              "' must specify a ctype pragma (e.g., {.ctype: \"my_struct_t\".})", typeDef)

      types.add(TypeInfo(nimName: nimName, ctype: ctype))

    result.add(cleanStmt)

  # Emit #include
  result.add(newNimNode(nnkPragma).add(
    newNimNode(nnkExprColonExpr).add(
      ident("emit"),
      newStrLitNode("/*INCLUDESECTION*/\n" & toIncludeDirective(headerFile))
    )
  ))

  # Emit sizeof verification at file scope per type
  for t in types:
    var emitArray = newNimNode(nnkBracket)
    emitArray.add(newStrLitNode(
      "\n#if defined(__cplusplus)\n" &
      "static_assert(sizeof("
    ))
    emitArray.add(t.nimName)
    emitArray.add(newStrLitNode(
      ") == sizeof(" & t.ctype & "),\n" &
      "  \"softlink dyntype: " & $t.nimName & " size mismatch vs " & headerFile &
      " (" & t.ctype & ")\");\n" &
      "#else\n" &
      "_Static_assert(sizeof("
    ))
    emitArray.add(t.nimName)
    emitArray.add(newStrLitNode(
      ") == sizeof(" & t.ctype & "),\n" &
      "  \"softlink dyntype: " & $t.nimName & " size mismatch vs " & headerFile &
      " (" & t.ctype & ")\");\n" &
      "#endif\n"
    ))
    result.add(newNimNode(nnkPragma).add(
      newNimNode(nnkExprColonExpr).add(
        ident("emit"),
        emitArray
      )
    ))
