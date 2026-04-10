## softlink — Type-safe optional dynamic library bindings for Nim.
##
## Provides a `dynlib` macro that generates runtime-loadable FFI bindings
## from type-safe proc definitions, and a `dyntype` macro for compile-time
## struct layout verification against C headers. Solves the Nim ecosystem
## gap between `{.importc, dynlib.}` (type-safe but fatal on missing) and
## `std/dynlib` (optional but loses type safety).

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

macro dynlib*(libPattern: static[string], body: untyped): untyped =
  ## Generate type-safe, runtime-optional bindings for a dynamic library.
  ## The generated ``loadXxx``/``unloadXxx`` procs are **not thread-safe**.
  ## Wrapper proc calls must also not race with ``unloadXxx`` — the loaded
  ## state and function pointer dispatch are not atomic.
  ## Callers must synchronize externally if using from multiple threads.
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
  let libPatternLit = newStrLitNode(libPattern)

  result = newStmtList()

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

  type ProcInfo = object
    name: NimNode
    nameStr: string
    ptrName: NimNode
    formalParams: NimNode
    callConv: string
    headerFile: string
    isOptional: bool
    hasReturn: bool

  var procs: seq[ProcInfo]
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

    # Pragma validation: extract calling convention, optional flag, and header
    var callConv = ""
    var isOptional = false
    var headerFile = ""
    let pragmas = stmt[4]
    if pragmas.kind == nnkPragma:
      for pragma in pragmas:
        let pragmaName = if pragma.kind == nnkIdent: $pragma
                         elif pragma.kind == nnkExprColonExpr: $pragma[0]
                         else: ""
        if pragmaName in callingConventions:
          if callConv != "":
            error("proc '" & nameStr & "' has multiple calling conventions", stmt)
          callConv = pragmaName
        elif pragmaName == "optional":
          isOptional = true
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
    if headerFile == "":
      error("proc '" & nameStr &
            "' must specify a header pragma (e.g., {.header: \"foo.h\".})", stmt)

    procs.add(ProcInfo(name: procName, nameStr: nameStr, ptrName: ptrName,
                        formalParams: formalParams, callConv: callConv,
                        headerFile: headerFile, isOptional: isOptional,
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
    result.add(newNimNode(nnkPragma).add(
      newNimNode(nnkExprColonExpr).add(
        ident("emit"),
        newStrLitNode("/*INCLUDESECTION*/\n" & includeCode &
          "#if defined(__cplusplus)\n" &
          "#include <type_traits>\n" &
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
      let errMsg = "softlink dynlib: " & p.nameStr & " signature mismatch vs " & p.headerFile

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

      # --- C++ path: static_assert + std::is_same + decltype ---
      emitArray.add(newStrLitNode(
        "\n#if defined(__cplusplus)\nstatic_assert(\n  std::is_same<decltype("))
      buildCallArgs(emitArray, p.nameStr, dummyVars)
      emitArray.add(newStrLitNode("), "))
      if p.hasReturn:
        addTypeToEmit(emitArray, p.formalParams[0])
      else:
        emitArray.add(newStrLitNode("void"))
      emitArray.add(newStrLitNode(
        ">::value,\n  \"" & errMsg & "\"\n);\n"))

      # --- GCC/Clang path: __builtin_types_compatible_p + __typeof__ ---
      emitArray.add(newStrLitNode(
        "#elif defined(__GNUC__)\n_Static_assert(\n  __builtin_types_compatible_p(\n    __typeof__("))
      buildCallArgs(emitArray, p.nameStr, dummyVars)
      emitArray.add(newStrLitNode("),\n    "))
      if p.hasReturn:
        addTypeToEmit(emitArray, p.formalParams[0])
      else:
        emitArray.add(newStrLitNode("void"))
      emitArray.add(newStrLitNode(
        "),\n  \"" & errMsg & "\"\n);\n"))

      # --- MSVC C path: call + __typeof__ pointer trick ---
      emitArray.add(newStrLitNode(
        "#elif defined(_MSC_VER)\n"))
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

      # --- Fallback ---
      emitArray.add(newStrLitNode(
        "#else\n#error \"softlink: header verification requires GCC, Clang, MSVC, or a C++ compiler.\"\n#endif\n"))

      verifyBody.add(newNimNode(nnkPragma).add(
        newNimNode(nnkExprColonExpr).add(
          ident("emit"),
          emitArray
        )
      ))

    let verifyProcName = ident("softlinkVerify" & baseName)
    var verifyProc = newProc(
      name = verifyProcName,
      body = verifyBody,
    )
    verifyProc.addPragma(ident("exportc"))
    verifyProc.addPragma(newNimNode(nnkExprColonExpr).add(
      ident("codegenDecl"),
      newStrLitNode("static $# $#$#")
    ))
    result.add(verifyProc)

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
            let pname = if pragma.kind == nnkIdent: $pragma
                        elif pragma.kind == nnkExprColonExpr: $pragma[0]
                        else: ""
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
