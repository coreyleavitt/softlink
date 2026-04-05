## softlink — Type-safe optional dynamic library bindings for Nim.
##
## Provides a `dynlib` macro that generates runtime-loadable FFI bindings
## from type-safe proc definitions. Solves the Nim ecosystem gap between
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
            headerFile = $pragma[1]
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

    # Build proc type for the var
    var procTy = newNimNode(nnkProcTy)
    procTy.add(formalParams.copy())
    procTy.add(newNimNode(nnkPragma).add(ident(callConv)))

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
        includeCode.add("#include \"" & p.headerFile & "\"\n")

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

    # Emit per-proc verification inside a dummy proc so they appear
    # after the function pointer vars in the generated C code.
    var verifyBody = newStmtList()
    for p in procs:
      var emitArray = newNimNode(nnkBracket)
      emitArray.add(newStrLitNode(
        "#if defined(__cplusplus)\n" &
        "/* C++ path: static_assert + std::is_same + decltype */\n" &
        "static_assert(\n" &
        "  (std::is_same<decltype(&" & p.nameStr & "), decltype("
      ))
      emitArray.add(p.ptrName)
      emitArray.add(newStrLitNode(
        ")>::value),\n" &
        "  \"softlink: " & p.nameStr & " signature mismatch vs " & p.headerFile & "\"\n" &
        ");\n" &
        "#elif defined(__STDC_VERSION__) && __STDC_VERSION__ >= 202311L\n" &
        "/* C23 path: typeof (fully standard) */\n" &
        "_Static_assert(\n" &
        "  _Generic(&" & p.nameStr & ",\n" &
        "    typeof("
      ))
      emitArray.add(p.ptrName)
      emitArray.add(newStrLitNode(
        "): 1,\n" &
        "    default: 0\n" &
        "  ),\n" &
        "  \"softlink: " & p.nameStr & " signature mismatch vs " & p.headerFile & "\"\n" &
        ");\n" &
        "#elif defined(__GNUC__) || defined(__clang__) || defined(_MSC_VER)\n" &
        "/* C11 + extensions: __typeof__ */\n" &
        "_Static_assert(\n" &
        "  _Generic(&" & p.nameStr & ",\n" &
        "    __typeof__("
      ))
      emitArray.add(p.ptrName)
      emitArray.add(newStrLitNode(
        "): 1,\n" &
        "    default: 0\n" &
        "  ),\n" &
        "  \"softlink: " & p.nameStr & " signature mismatch vs " & p.headerFile & "\"\n" &
        ");\n" &
        "#else\n" &
        "#error \"softlink: header verification requires C23 typeof, GNU __typeof__, or C++ decltype. Your compiler supports none of these.\"\n" &
        "#endif\n"
      ))
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
    verifyProc.addPragma(ident("used"))
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
      procTy.add(newNimNode(nnkPragma).add(ident(p.callConv)))

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
      procTy.add(newNimNode(nnkPragma).add(ident(p.callConv)))

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

    result.add(newProc(
      name = postfix(p.name.copy(), "*"),
      params = params,
      body = wrapperBody,
    ))

    # xxxAvailable*(): bool for optional symbols
    if p.isOptional:
      let availName = ident(p.nameStr & "Available")
      result.add(newProc(
        name = postfix(availName, "*"),
        params = [ident("bool")],
        body = newStmtList(prefix(newCall(ident("isNil"), p.ptrName), "not")),
      ))
