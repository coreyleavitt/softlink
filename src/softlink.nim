## softlink — Type-safe optional dynamic library bindings for Nim.
##
## Provides a `dynlib` macro that generates runtime-loadable FFI bindings
## from type-safe proc definitions. Solves the Nim ecosystem gap between
## `{.importc, dynlib.}` (type-safe but fatal on missing) and `std/dynlib`
## (optional but loses type safety).

import std/[macros, sequtils, sets, strutils]
import std/dynlib as stdDynlib
export stdDynlib.LibHandle, stdDynlib.loadLibPattern, stdDynlib.symAddr,
       stdDynlib.unloadLib

type
  SoftlinkError* = ref object of CatchableError
    ## Raised when calling a function from a library that hasn't been loaded.
    symbol*: string
    library*: string

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

proc raiseNotLoaded*(library, symbol: string) {.noreturn, noinline.} =
  raise SoftlinkError(
    msg: library & ": library not loaded, cannot call: " & symbol,
    library: library, symbol: symbol)

func libNameToIdent(libPattern: string): string =
  ## Convert "libmbedtls.so(.16|.14|)" → "Mbedtls"
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
  let baseName = libNameToIdent(libPattern)
  let baseNameLower = baseName.toLowerAscii()
  let loadProcName = ident("load" & baseName)
  let unloadProcName = ident("unload" & baseName)
  let loadedProcName = ident(baseNameLower & "Loaded")
  let handleName = ident("softlinkHandle" & baseName)
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

  # Collect proc info and generate pointer vars
  const callingConventions = ["cdecl", "stdcall", "fastcall", "syscall", "noconv"]

  type ProcInfo = object
    name: NimNode
    nameStr: string
    ptrName: NimNode
    formalParams: NimNode
    callConv: string
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

    # Pragma validation: extract calling convention and optional flag
    var callConv = ""
    var isOptional = false
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
        elif pragmaName != "":
          error("dynlib does not support pragma '" & pragmaName &
                "' on proc '" & nameStr & "'", stmt)

    if callConv == "":
      error("proc '" & nameStr &
            "' must specify a calling convention pragma (e.g., {.cdecl.})", stmt)

    procs.add(ProcInfo(name: procName, nameStr: nameStr, ptrName: ptrName,
                        formalParams: formalParams, callConv: callConv,
                        isOptional: isOptional, hasReturn: hasReturn))

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

  # loadXxx*(): LoadResult
  block:
    let hasOptional = procs.anyIt(it.isOptional)
    var loadBody = newStmtList()
    let missingName = ident("softlinkMissing")

    # if not handle.isNil: return LoadResult(kind: lrOk)
    loadBody.add(newIfStmt((
      prefix(newCall(ident("isNil"), handleName), "not"),
      newStmtList(newNimNode(nnkReturnStmt).add(
        newNimNode(nnkObjConstr).add(
          ident("LoadResult"),
          newNimNode(nnkExprColonExpr).add(ident("kind"), ident("lrOk"))
        )
      ))
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

    # var missing: seq[string] (only if there are optional procs)
    if hasOptional:
      loadBody.add(newNimNode(nnkVarSection).add(
        newNimNode(nnkIdentDefs).add(
          missingName,
          newNimNode(nnkBracketExpr).add(ident("seq"), ident("string")),
          newEmptyNode()
        )
      ))

    # For each proc: resolve symbol
    for p in procs:
      let symName = newStrLitNode(p.nameStr)
      let tempSym = genSym(nskLet, "sym")

      # Build proc type for cast
      var procTy = newNimNode(nnkProcTy)
      procTy.add(p.formalParams.copy())
      procTy.add(newNimNode(nnkPragma).add(ident(p.callConv)))

      # let sym = handle.symAddr("name")
      loadBody.add(newLetStmt(tempSym, newCall(ident("symAddr"), handleName, symName)))

      if p.isOptional:
        # if sym.isNil: missing.add(name) else: fpXxx = cast[ProcType](sym)
        var ifElse = newNimNode(nnkIfStmt)
        ifElse.add(newNimNode(nnkElifBranch).add(
          newCall(ident("isNil"), tempSym),
          newStmtList(newCall(newDotExpr(missingName, ident("add")), symName))
        ))
        ifElse.add(newNimNode(nnkElse).add(
          newStmtList(newAssignment(p.ptrName, newNimNode(nnkCast).add(procTy, tempSym)))
        ))
        loadBody.add(ifElse)
      else:
        # if sym.isNil: cleanup and return LoadResult(kind: lrSymbolNotFound, symbol: name)
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

        # fpXxx = cast[ProcType](sym)
        loadBody.add(newAssignment(p.ptrName, newNimNode(nnkCast).add(procTy, tempSym)))

    # return: lrOkPartial if missing, lrOk otherwise
    if hasOptional:
      # if missing.len > 0: return LoadResult(kind: lrOkPartial, missing: missing)
      loadBody.add(newIfStmt((
        newNimNode(nnkInfix).add(ident(">"),
          newDotExpr(missingName, ident("len")),
          newIntLitNode(0)),
        newStmtList(newNimNode(nnkReturnStmt).add(
          newNimNode(nnkObjConstr).add(
            ident("LoadResult"),
            newNimNode(nnkExprColonExpr).add(ident("kind"), ident("lrOkPartial")),
            newNimNode(nnkExprColonExpr).add(ident("missing"), missingName)
          )
        ))
      )))

    # return LoadResult(kind: lrOk)
    loadBody.add(newNimNode(nnkReturnStmt).add(
      newNimNode(nnkObjConstr).add(
        ident("LoadResult"),
        newNimNode(nnkExprColonExpr).add(ident("kind"), ident("lrOk"))
      )
    ))

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
