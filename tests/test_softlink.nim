## Tests for softlink macro.
##
## Tests against system math/C libraries (Linux) and a custom test library (all platforms).
## Build the test library before running (see nimble test task).

import std/[unittest, math, strutils, sequtils]
import softlink {.all.}
import softlink/versions
import softlink/manifest

suite "deriveLibPattern — logical name → per-OS candidates":
  test "Linux → bare .so first, then descending single-component majors":
    check deriveLibPattern("z3", osLinux) == "libz3.so(|.7|.6|.5|.4|.3|.2|.1)"

  test "bare name on Windows → both lib-prefixed and bare .dll":
    check deriveLibPattern("z3", osWindows) == "(libz3|z3).dll"

  test "macOS → bare .dylib first, then descending majors":
    check deriveLibPattern("z3", osMacos) == "libz3(|.7|.6|.5|.4|.3|.2|.1).dylib"

  test "leading 'lib' is stripped so libz3 and z3 agree":
    check deriveLibPattern("libz3", osLinux) == deriveLibPattern("z3", osLinux)
    check deriveLibPattern("libz3", osWindows) == deriveLibPattern("z3", osWindows)

suite "isLogicalName — magic vs verbatim (escape hatch) routing":
  test "bare stems are logical → magic derivation":
    check isLogicalName("z3")
    check isLogicalName("libz3")
    check isLogicalName("mbedtls")

  test "explicit patterns are not logical → used verbatim":
    # Anything carrying an extension, alternation, or path separator is the
    # author's exact loadLibPattern string and must pass through untouched.
    check not isLogicalName("libz3.so(.4|)")
    check not isLogicalName("libtestlib.so")
    check not isLogicalName("libm.so(.6|)")
    check not isLogicalName("/opt/z3/lib/libz3.so")
    check not isLogicalName(r"C:\z3\libz3.dll")

suite "logical-name ident derivation is OS-invariant (C1 regression)":
  # The macro derives its load/unload/loaded proc names from libNameToIdent
  # applied to the *logical name*, never to the OS-expanded pattern. Feeding the
  # Windows-expanded pattern "(libz3|z3).dll" to libNameToIdent mangles it to
  # "Libz3z3" — which would generate loadLibz3z3 on Windows while Linux/macOS
  # generate loadZ3. Deriving from the logical name keeps idents identical
  # across every target by construction.
  test "logical name yields a stable, OS-independent base ident":
    check libNameToIdent("z3") == "Z3"
    check libNameToIdent("libz3") == "Z3"
  test "the OS-expanded Windows pattern is the trap the macro must avoid":
    check libNameToIdent(deriveLibPattern("z3", osWindows)) == "Libz3z3"
    check libNameToIdent("z3") != libNameToIdent(deriveLibPattern("z3", osWindows))

# System library tests — Linux only (library names produce consistent identifiers)
when defined(linux):
  dynlib "libm.so(.6|)":
    proc ceil(x: cdouble): cdouble {.cdecl, header: "math.h".}
    proc floor(x: cdouble): cdouble {.cdecl, header: "math.h".}
    proc sqrt(x: cdouble): cdouble {.cdecl, header: "math.h".}
    proc pow(base: cdouble, exp: cdouble): cdouble {.cdecl, header: "math.h".}
    proc round(x: cdouble): cdouble {.cdecl, header: "<math.h>".}  # angle-bracket syntax
    # RFC-0001 §9/§C.1, slice C1b, TDD suite item 2: a DELIBERATELY-raising
    # probe. loadM() must still return its normal LoadResult (every
    # required symbol here always resolves) with no exception escaping;
    # the probed-version var stays empty and the probe-failed flag is set.
    versionProbe:
      raise newException(ValueError, "deliberate versionProbe failure (RFC-0001 C1b test)")

  dynlib "libc.so(.6|)":
    proc srand(seed: cuint) {.cdecl, header: "stdlib.h".}
    proc rand(): cint {.cdecl, header: "stdlib.h".}
    # RFC-0001 §9/§C.1, slice C1b, TDD suite item 3: a probe that calls
    # loadC() RECURSIVELY. The reentrancy guard converts the resulting
    # raise into a failed probe — this outer loadC() call still returns
    # its normal LoadResult, with no exception escaping.
    versionProbe:
      discard loadC()
      "unreachable — loadC() above always raises reentrantly"


# RFC-0001 §9/§C.1, slice C1b: a single, mode-controlled `versionProbe` on
# the cross-platform TestLib block below, covering every remaining
# behavior from this slice's TDD suite that doesn't need its OWN dedicated
# library (a dynlib block may declare at most one versionProbe, so a
# single library can't host more than one FIXED probe body — a controlled
# "mode" variable, set by each test before calling loadTestlib(), is the
# standard seam for this).
type ProbeMode = enum
  pmNormal          ## returns a real, parseable version built from a bound wrapper (item 1)
  pmUnparseable     ## returns a string with NO digit/alpha runs at all (item 4)
  pmReentrantUnload ## calls unloadTestlib() recursively (item 3, unload variant)

var probeMode = pmNormal
var probeRunCount = 0  ## bumped once per ACTUAL probe run — item 8 (idempotency)

# Test library — cross-platform (built from tests/testlib.c)
when defined(windows):
  const TestLib = "testlib.dll"
elif defined(macosx):
  const TestLib = "libtestlib.dylib"
else:
  const TestLib = "libtestlib.so"

dynlib TestLib:
  # RFC-0001 §3 A.1: {.prototype.} coexisting with {.header.} (cross-checking)
  # — both the header's declaration and the vendored `extern` prototype are
  # emitted; the C compiler itself enforces same-scope agreement (C11
  # 6.7p4), so this compiling at all is a live conflict-free-agreement check
  # (the deliberate-conflict case is slice A4).
  proc testlib_add(a: cint, b: cint): cint
    {.cdecl, header: "tests/testlib.h", prototype: "int testlib_add(int a, int b)".}
  proc testlib_noop() {.cdecl, header: "tests/testlib.h".}
  proc testlib_future(): cint {.cdecl, optional, header: "tests/testlib.h".}
  # Regression: #11 — const-qualified pointer returns must verify
  # against cstring without "signature mismatch" errors under any
  # backend. testlib_const_string returns `const char *`; binding
  # as `cstring` should be accepted.
  proc testlib_const_string(): cstring {.cdecl, header: "tests/testlib.h".}
  proc testlib_const_lookup(key: cint): cstring {.cdecl, header: "tests/testlib.h".}
  proc testlib_mutable_string(): cstring {.cdecl, header: "tests/testlib.h".}
  # Defect B regression (#14): testlib_unheralded is in the .so but NOT in
  # testlib.h. {.optional.} alone would still emit the header verification
  # and fail with an implicit-declaration error; {.noverify.} skips it (and
  # makes the header pragma unnecessary). Runtime resolution is unaffected.
  proc testlib_unheralded(): cint {.cdecl, optional, noverify.}
  # noverify symbol missing at runtime too — must degrade exactly like a
  # plain optional symbol (lands in `missing`, Available() false, raises).
  proc testlib_future_nv(): cint {.cdecl, optional, noverify.}
  # {.verifyWhen.}: verification gated on a C preprocessor expression.
  # TESTLIB_VERSION is 1, so this condition holds and the _Static_assert
  # runs — a wrong signature here must fail the C compile.
  proc testlib_gated(): cint
    {.cdecl, verifyWhen: "TESTLIB_VERSION >= 1", header: "tests/testlib.h".}
  # The motivating scenario: symbol newer than the installed header (absent
  # from testlib.h, present in the .so). Condition is false → verification
  # skipped; unlike {.noverify.}, a system with version >= 2 headers would
  # verify this signature.
  proc testlib_gated_v2(): cint
    {.cdecl, optional, verifyWhen: "TESTLIB_VERSION >= 2", header: "tests/testlib.h".}
  # RFC-0001 §3 A.1 slice A2 happy path: {.prototype.} alone (no {.header.})
  # is accepted, header requirement lifted, AND now fully verified — the
  # vendored prototype is emitted as a file-scope `extern` declaration ahead
  # of the standard call-based _Static_assert chain (see `emitPrototypeDecl`
  # in softlink.nim), so a wrong signature here would fail the C compile
  # exactly like a header-verified proc's would (that negative case is slice
  # A3). testlib_protoonly is in the .so but NOT in testlib.h — the F2
  # scenario A.1 targets — and runtime dispatch is unaffected: still routed
  # through the dlsym'd pointer, never through the extern declaration.
  proc testlib_protoonly(): cint
    {.cdecl, prototype: "int testlib_protoonly(void)".}
  # RFC-0001 §3 A.1 / slice A5: {.prototype.} + {.verifyWhen.} composition —
  # TRUE gate. TESTLIB_VERSION is 1, so "TESTLIB_VERSION >= 1" holds: BOTH
  # the vendored `extern` declaration and its _Static_assert are emitted
  # (see `emitPrototypeDecl`), so a wrong prototype here would fail the C
  # compile exactly like slice A3's un-gated case — the gate composes
  # without weakening verification when the condition holds. Absent from
  # testlib.h (prototype-only), present in the .so.
  proc testlib_proto_gated_true(): cint
    {.cdecl, prototype: "int testlib_proto_gated_true(void)",
      verifyWhen: "TESTLIB_VERSION >= 1".}
  # RFC-0001 slice A5: {.prototype.} + {.verifyWhen.} composition — FALSE
  # gate. TESTLIB_VERSION is 1, so "TESTLIB_VERSION >= 99" is false: the
  # entire `#if`-wrapped blob — vendored declaration AND its assert — is
  # skipped by the C preprocessor. The prototype string below is
  # DELIBERATELY WRONG (different return type and arity than the real C
  # function, which takes no arguments and returns int): this compiling is
  # the "nothing checks the prototype at all" half of the RFC's false-gate
  # semantics. It does NOT by itself prove the *declaration* is gated —
  # runtime dispatch calls through a dlsym'd function pointer, never the
  # symbol name directly, and there's no {.header.} here to conflict with,
  # so an ungated-but-unused wrong-arity `extern` would compile fine too
  # (verified empirically; see the nimble test task's `protoGateFalseCheck`
  # comment). The C-inspection grep there is what actually proves the
  # declaration is suppressed; this test is the runtime half, confirming
  # dispatch is unaffected by the gate either way.
  proc testlib_proto_gated_false(): cint
    {.cdecl, prototype: "void testlib_proto_gated_false(double a, double b, double c)",
      verifyWhen: "TESTLIB_VERSION >= 99".}

  # RFC-0001 §9/§C.1, slice C1b: the mode-controlled probe (see `ProbeMode`
  # above). `pmNormal` calls the block's OWN bound wrapper `testlib_add` —
  # the TDD suite's item 1 ("probe calling a bound wrapper"), proving the
  # wrapper-before-load codegen order (C1a) actually lets a probe do this.
  versionProbe:
    inc probeRunCount
    case probeMode
    of pmNormal: "1." & $testlib_add(2, 3)
    of pmUnparseable: "---"
    of pmReentrantUnload:
      unloadTestlib()
      "unreachable — unloadTestlib() above always raises reentrantly"

# verifyProcs: compile-time signature verification ONLY (no loading, no
# wrappers). Correct signatures must compile; the const-return case (#11)
# must also be accepted here, sharing dynlib's verification codegen.
verifyProcs:
  # {.prototype.} + {.header.} coexisting (cross-checking, §3 A.1): both
  # declarations are emitted; must compile as a live conflict-free-agreement
  # check (same reasoning as the dynlib block above).
  proc testlib_add(a: cint, b: cint): cint
    {.cdecl, header: "tests/testlib.h", prototype: "int testlib_add(int a, int b)".}
  proc testlib_const_string(): cstring {.cdecl, header: "tests/testlib.h".}
  # verifyProcs parity (RFC-0001 slice A2, deliverable 4): the same
  # {.prototype.}-only emission path must fire here too — no dynlib-specific
  # special-casing in `genVerifyBlock`. Reuses testlib_unheralded (the RFC's
  # named A2 fixture, §9): absent from testlib.h, so this compiling proves
  # the extern declaration + assert ran for real, not skipped. (dynlib's own
  # binding of testlib_unheralded stays on {.noverify.} for the #14
  # regression above — a proc name may be reused across independent
  # macro-block instances since neither macro declares a Nim-level symbol
  # by that name outside the emitted C text.)
  proc testlib_unheralded(): cint
    {.cdecl, prototype: "int testlib_unheralded(void)".}
  # verifyWhen in verifyProcs: identical semantics to dynlib. True condition →
  # verified (testlib_gated is declared in testlib.h); false condition →
  # skipped entirely, so a symbol absent from the header must NOT be an
  # implicit-declaration error.
  proc testlib_gated(): cint
    {.cdecl, verifyWhen: "TESTLIB_VERSION >= 1", header: "tests/testlib.h".}
  proc testlib_gated_v2(): cint
    {.cdecl, verifyWhen: "TESTLIB_VERSION >= 2", header: "tests/testlib.h".}
  # RFC-0001 slice A5, deliverable 3: {.prototype.} + {.verifyWhen.}
  # composition parity — verifyProcs must accept the same combination
  # dynlib does and compose the same way (gated declaration + gated
  # assert). True-gate only; false-gate and a full parity sweep across
  # every pragma combination is slice A8. Reuses the dynlib block's C
  # symbol name — safe, since verifyProcs declares no Nim-level identifier
  # for it (same precedent as testlib_add/testlib_gated above).
  proc testlib_proto_gated_true(): cint
    {.cdecl, prototype: "int testlib_proto_gated_true(void)",
      verifyWhen: "TESTLIB_VERSION >= 1".}
  # RFC-0001 slice A8: the false-gate mirror of the pair above, completing
  # the A5 composition parity sweep for verifyProcs (the RFC's own words
  # for this slice: "including the A5 composition"). Deliberately given a
  # C name UNIQUE to this block (never bound by the dynlib block above,
  # unlike testlib_proto_gated_true/false, which verifyProcs reuses) —
  # collision-safe reuse is fine for a *positive* compile, but it would
  # make a C-inspection grep for this exact declaration text ambiguous:
  # it could be satisfied by the dynlib block's own (already-tested)
  # emission instead of proving verifyProcs's independently. `collectVProcs`
  # is the one piece of code NOT literally shared with dynlib's own body-
  # collection loop (both funnel into the same `parseProcPragmas` +
  # `genVerifyBlock`, but each macro has its own loop translating parsed
  # facts into `SoftlinkProc`) — a regression there (e.g. dropping
  # `verifyWhen`/`prototype` on the way into `SoftlinkProc`) is exactly
  # the kind of "future refactor silently breaks the verifyProcs side"
  # this slice exists to catch, and a shared-name fixture can't catch it
  # (proven by fault injection during this slice's TDD cycle — see the
  # nimble test task's `vpProtoGateTrueCheck`/`vpProtoGateFalseCheck`
  # comments). The prototype is deliberately WRONG (different return type
  # and arity, matching the A5 false-gate precedent above) — the false
  # gate must suppress both the (wrong) declaration and its assert.
  proc vp_proto_gated_true(): cint
    {.cdecl, prototype: "int vp_proto_gated_true(void)",
      verifyWhen: "TESTLIB_VERSION >= 1".}
  proc vp_proto_gated_false(): cint
    {.cdecl, prototype: "void vp_proto_gated_false(double a, double b, double c)",
      verifyWhen: "TESTLIB_VERSION >= 99".}

suite "verifyProcs (static-binding header verification)":
  test "correct signatures pass compile-time verification":
    # Reaching here means the verifyProcs block above compiled — the
    # _Static_assert(s) held against the C header. No symbols were loaded.
    check true

  test "compile-time: verifyProcs rejects noverify and unknown pragmas":
    # Positive control first: unlike dynlib, verifyProcs generates no exported
    # procs, so it is legal below top level and compiles() is meaningful here.
    check compiles(block:
      verifyProcs:
        proc vp_ok(): cint {.cdecl, header: "tests/testlib.h".}
    )
    check not compiles(block:
      verifyProcs:
        proc vp_bad(): cint {.cdecl, noverify, header: "tests/testlib.h".}
    )
    check not compiles(block:
      verifyProcs:
        proc vp_vararg(): cint {.cdecl, varargs, header: "tests/testlib.h".}
    )

suite "prototype tokenizer/analyzer (RFC-0001 slice A1)":
  # Pure functions — unit-tested directly, no compiles() gymnastics needed.
  # `tokenizePrototype` is the primitive slice A6 will reuse for builtin-type
  # detection; `analyzePrototype` layers A1's specific rules (name
  # extraction, function-pointer-return detection, variadic detection) on
  # top of the token stream.
  test "tokenizer: identifiers, punctuation, and paren depth":
    let tokens = tokenizePrototype("int foo(int x)")
    check tokens.len == 6
    check tokens[0].kind == ptkIdent and tokens[0].text == "int" and tokens[0].depth == 0
    check tokens[1].kind == ptkIdent and tokens[1].text == "foo" and tokens[1].depth == 0
    check tokens[2].kind == ptkPunct and tokens[2].text == "(" and tokens[2].depth == 0
    check tokens[3].kind == ptkIdent and tokens[3].text == "int" and tokens[3].depth == 1
    check tokens[4].kind == ptkIdent and tokens[4].text == "x" and tokens[4].depth == 1
    check tokens[5].kind == ptkPunct and tokens[5].text == ")" and tokens[5].depth == 0

  test "tokenizer: nested parens (callback parameter) track depth correctly":
    let tokens = tokenizePrototype("int bar(int x, void (*cb)(int))")
    # The callback parameter's own parens must be depth >= 1, never depth 0 —
    # only the function's own opening paren is depth 0.
    var depth0Parens = 0
    for tok in tokens:
      if tok.kind == ptkPunct and tok.text == "(" and tok.depth == 0:
        inc depth0Parens
    check depth0Parens == 1

  test "tokenizer: '...' is a single token, not three '.' punctuation tokens":
    let tokens = tokenizePrototype("int fmt(const char *f, ...)")
    var ellipsisCount = 0
    for tok in tokens:
      if tok.text == "...": inc ellipsisCount
    check ellipsisCount == 1

  test "analyzer: simple prototype — name extracted, not fn-ptr-return, not variadic":
    let a = analyzePrototype("int foo(int x)")
    check a.ok
    check a.name == "foo"
    check not a.isFunctionPointerReturn
    check not a.hasVariadic

  test "analyzer: pointer return type with spaces — name still extracted (#11-adjacent)":
    let a = analyzePrototype("const char *foo(int)")
    check a.ok
    check a.name == "foo"
    check not a.isFunctionPointerReturn

  test "analyzer: nested parens in a parameter don't confuse depth-0 name extraction":
    let a = analyzePrototype("int bar(int x, void (*cb)(int))")
    check a.ok
    check a.name == "bar"
    check not a.isFunctionPointerReturn

  test "analyzer: function-pointer return type detected (name nested, unextractable)":
    let a = analyzePrototype("int (*make_thing(int))(int)")
    check a.ok
    check a.isFunctionPointerReturn

  test "analyzer: the RFC's motivating function-pointer-return shape":
    # void (*signal(int, void (*)(int)))(int) — signal's own name is nested
    # inside the return type; the char after the first depth-0 '(' is '*'.
    let a = analyzePrototype("void (*signal(int, void (*)(int)))(int)")
    check a.ok
    check a.isFunctionPointerReturn

  test "analyzer: variadic '...' detected anywhere in the prototype":
    let a = analyzePrototype("int fmt_like(const char *fmt, ...)")
    check a.ok
    check a.hasVariadic
    check a.name == "fmt_like"

  test "analyzer: embedded newlines/indentation (triple-quoted style) don't affect extraction":
    let a = analyzePrototype("""
      int
        vp_multiline (
          int x
        )
    """)
    check a.ok
    check a.name == "vp_multiline"
    check not a.isFunctionPointerReturn
    check not a.hasVariadic

  test "analyzer: malformed prototype with no parens is reported, not crashed":
    let a = analyzePrototype("int foo")
    check not a.ok

suite "nonBuiltinIdentifiers — builtin-type classification (RFC-0001 slice A6)":
  # Pure function over the shared A1 tokenizer. Excludes the function name
  # (already validated elsewhere) and, best-effort, parameter names — see
  # the doc comment on `nonBuiltinIdentifiers` for the exact scope limits
  # (nested function-pointer-parameter internals are not classified).
  test "all-builtin prototype: no non-builtin identifiers":
    check nonBuiltinIdentifiers("int foo(int x, unsigned char y)").len == 0

  test "'void' as the sole (no-args) parameter is builtin, not flagged":
    check nonBuiltinIdentifiers("int foo(void)").len == 0

  test "non-builtin return type is flagged, function name excluded":
    check nonBuiltinIdentifiers("Foo_Type bar(void)") == @["Foo_Type"]

  test "non-builtin named parameter type is flagged, parameter name excluded":
    check nonBuiltinIdentifiers("int baz(Foo_Context c)") == @["Foo_Context"]

  test "non-builtin unnamed parameter (bare typedef) is flagged":
    check nonBuiltinIdentifiers("int qux(Foo_Context)") == @["Foo_Context"]

  test "const-qualified pointer to a typedef: qualifier ignored, typedef flagged":
    check nonBuiltinIdentifiers("const Foo_Context *get(void)") == @["Foo_Context"]

  test "duplicate non-builtin identifiers reported once, first-seen order":
    check nonBuiltinIdentifiers("int f(Foo_T a, Foo_T b)") == @["Foo_T"]

  test "multiple distinct non-builtin identifiers preserve first-seen order":
    check nonBuiltinIdentifiers("Foo_A f(Foo_B x, Foo_C y)") == @["Foo_A", "Foo_B", "Foo_C"]

  test "nested function-pointer parameter internals are out of scope, not false-flagged":
    # `void (*cb)(int)`'s own "cb"/"int" are nested past depth 1 and are
    # deliberately not classified (RFC: "softlink does not attempt full
    # detection") — only the sibling parameter's typedef is flagged.
    check nonBuiltinIdentifiers("int reg(void (*cb)(int), Foo_Ctx c)") == @["Foo_Ctx"]

suite "verifyProcs — prototype pragma (RFC-0001 slice A1)":
  test "positive: prototype + header coexist, name matches proc":
    check compiles(block:
      verifyProcs:
        proc vp_proto_ok(x: cint): cint
          {.cdecl, header: "tests/testlib.h", prototype: "int vp_proto_ok(int x)".}
    )

  test "positive: triple-quoted multi-line prototype accepted":
    check compiles(block:
      verifyProcs:
        proc vp_proto_multiline(x: cint): cint
          {.cdecl, header: "tests/testlib.h",
            prototype: """
              int
              vp_proto_multiline(int x)
            """.}
    )

  test "positive: prototype alone (no header) — header requirement lifted":
    check compiles(block:
      verifyProcs:
        proc vp_proto_noheader(): cint {.cdecl, prototype: "int vp_proto_noheader(void)".}
    )

  test "negative: non-string-literal prototype value rejected":
    check not compiles(block:
      verifyProcs:
        proc vp_proto_notstring(): cint {.cdecl, prototype: 123, header: "tests/testlib.h".}
    )

  test "negative: empty prototype string rejected":
    check not compiles(block:
      verifyProcs:
        proc vp_proto_empty(): cint {.cdecl, prototype: "", header: "tests/testlib.h".}
    )

  test "negative: whitespace-only prototype string rejected":
    check not compiles(block:
      verifyProcs:
        proc vp_proto_ws(): cint {.cdecl, prototype: "   \n  ", header: "tests/testlib.h".}
    )

  test "negative: extracted name mismatched with proc's C name rejected":
    check not compiles(block:
      verifyProcs:
        proc vp_proto_mismatch(): cint
          {.cdecl, header: "tests/testlib.h", prototype: "int vp_proto_other(void)".}
    )

  test "negative: variadic prototype rejected":
    check not compiles(block:
      verifyProcs:
        proc vp_proto_variadic(): cint
          {.cdecl, header: "tests/testlib.h",
            prototype: "int vp_proto_variadic(const char *fmt, ...)".}
    )

  test "negative: function-pointer-return prototype rejected":
    check not compiles(block:
      verifyProcs:
        proc vp_proto_fpret(): cint
          {.cdecl, header: "tests/testlib.h",
            prototype: "void (*vp_proto_fpret(int))(int)".}
    )

  test "negative: prototype + noverify contradiction rejected":
    check not compiles(block:
      verifyProcs:
        proc vp_proto_noverify(): cint
          {.cdecl, noverify, prototype: "int vp_proto_noverify(void)".}
    )

suite "softlink":
  # System library tests — Linux only
  when defined(linux):
    test "loadM succeeds (libm always available)":
      check loadM().kind == lrOk
      check mLoaded()

    test "math functions work through bindings":
      check loadM().kind == lrOk
      check ceil(2.3) == 3.0
      check floor(2.7) == 2.0
      check sqrt(16.0) == 4.0
      check pow(2.0, 10.0) == 1024.0

    test "unload then reload works":
      check loadM().kind == lrOk
      unloadM()
      check not mLoaded()
      check loadM().kind == lrOk
      check ceil(1.1) == 2.0

    test "double load is idempotent":
      check loadM().kind == lrOk
      check loadM().kind == lrOk
      check ceil(1.1) == 2.0

    test "void proc dispatch works (no return type)":
      check loadC().kind == lrOk
      srand(42.cuint)
      let val = rand()
      srand(42.cuint)
      check rand() == val

    test "calling after unload raises SoftlinkError":
      check loadM().kind == lrOk
      check ceil(1.1) == 2.0
      unloadM()
      expect SoftlinkError:
        discard ceil(1.1)

    test "SoftlinkError contains symbol and library name":
      unloadM()
      try:
        discard ceil(1.1)
        fail()
      except SoftlinkError as e:
        check e.symbol == "ceil"
        check "ceil" in e.msg

    test "unload when not loaded is a no-op":
      unloadM()
      unloadM()
      check not mLoaded()

    test "optional: all-required lib returns lrOk not lrOkPartial":
      check loadM().kind == lrOk

    # RFC-0001 §9/§C.1, slice C1b — TDD suite item 2: a deliberately-
    # raising probe (declared on the libm.so block above) must not escape
    # loadM(); the LoadResult, probed-version var, and failed flag all
    # reflect the failure correctly.
    test "versionProbe: deliberately-raising probe degrades to a failed probe, loadX unaffected":
      unloadM()
      let r = loadM()
      check r.kind == lrOk
      check softlinkProbedVersionM == ""
      check softlinkProbeFailedM == true

    # TDD suite item 3 — reentrancy: a probe calling loadC() recursively
    # (declared on the libc.so block above). The reentrancy guard converts
    # the raise to a failed probe; this OUTER, non-reentrant loadC() call
    # still returns its normal LoadResult with no exception escaping.
    test "versionProbe: reentrant loadC() call from inside its own probe is converted, not escaped":
      unloadC()
      let r = loadC()
      check r.kind == lrOk
      check softlinkProbedVersionC == ""
      check softlinkProbeFailedC == true

  # Cross-platform tests using testlib
  test "testlib: required symbols work":
    let r = loadTestlib()
    check r.kind in {lrOk, lrOkPartial}
    check testlib_add(3.cint, 4.cint) == 7.cint

  test "testlib: void required symbol works":
    check loadTestlib().kind in {lrOk, lrOkPartial}
    testlib_noop()

  test "testlib: partial load returns lrOkPartial with missing optional":
    let r = loadTestlib()
    check r.kind == lrOkPartial
    check r.missing == @["testlib_future", "testlib_future_nv"]

  test "testlib: availability check for optional symbols":
    check loadTestlib().kind in {lrOk, lrOkPartial}
    check not testlib_futureAvailable()

  test "testlib: calling missing optional raises SoftlinkError":
    check loadTestlib().kind in {lrOk, lrOkPartial}
    expect SoftlinkError:
      discard testlib_future()

  # Defect B regression (#14): a symbol newer than the installed headers.
  # {.noverify.} skips the compile-time _Static_assert (and the #include of
  # its header) so the block compiles, while runtime resolution still works.
  # The negative side — {.optional.} WITHOUT {.noverify.} fails against a
  # header lacking the symbol — is a C-compile-time failure (implicit
  # declaration), not a Nim one, so it can't be pinned with compiles();
  # verified manually in Docker.
  test "noverify: symbol absent from header resolves at runtime (#14)":
    check loadTestlib().kind in {lrOk, lrOkPartial}
    check testlib_unheraldedAvailable()
    check testlib_unheralded() == 99.cint

  test "verifyWhen: true condition — symbol verified and callable":
    check loadTestlib().kind in {lrOk, lrOkPartial}
    check testlib_gated() == 21.cint

  test "verifyWhen: false condition — symbol newer than header binds and resolves":
    check loadTestlib().kind in {lrOk, lrOkPartial}
    check testlib_gated_v2Available()
    check testlib_gated_v2() == 42.cint

  test "noverify: symbol missing at runtime degrades like optional (#14)":
    check loadTestlib().kind in {lrOk, lrOkPartial}
    check not testlib_future_nvAvailable()
    expect SoftlinkError:
      discard testlib_future_nv()

  # RFC-0001 §3 A.1 slice A2: {.prototype.} alone (no {.header.}) lifts the
  # header requirement AND is now genuinely header-verified — testlib_protoonly
  # is absent from testlib.h entirely (a plain {.header.} binding of it would
  # be a C implicit-declaration error), yet compiles because the vendored
  # prototype is emitted as its own `extern` declaration ahead of the
  # _Static_assert chain (see softlink.nim `emitPrototypeDecl`; the compile
  # succeeding at all is the compile-time half of this test — a wrong
  # signature here is slice A3). Runtime dispatch is a separate, unaffected
  # path: still routed through the dlsym'd pointer, never the extern decl.
  test "prototype: header-optional path verifies at compile time and dispatches at runtime (A2)":
    check loadTestlib().kind in {lrOk, lrOkPartial}
    check testlib_protoonly() == 77.cint

  # RFC-0001 slice A5: {.prototype.} + {.verifyWhen.} composition, true gate.
  # The compile-time half (declaration + assert both emitted and checked) is
  # covered by the nimble test task's C-inspection grep; this is the runtime
  # half — the symbol still binds and dispatches through the dlsym'd pointer
  # exactly like any other required symbol.
  test "prototype + verifyWhen: true gate verifies and dispatches (A5)":
    check loadTestlib().kind in {lrOk, lrOkPartial}
    check testlib_proto_gated_true() == 88.cint

  # RFC-0001 slice A5: {.prototype.} + {.verifyWhen.} composition, false
  # gate. The bound prototype string is deliberately wrong (see the dynlib
  # block above); the declaration being genuinely suppressed under the
  # false gate is proven by the nimble test task's C-inspection grep
  # (`protoGateFalseCheck`), not by this test — dispatch goes through a
  # dlsym'd function pointer regardless of the gate, so this is only the
  # runtime half, confirming dispatch is unaffected by the gate either way.
  test "prototype + verifyWhen: false gate skips verification, still dispatches (A5)":
    check loadTestlib().kind in {lrOk, lrOkPartial}
    check testlib_proto_gated_false() == 55.cint

  # Regression: #11 — const-qualified pointer returns must bind to
  # cstring without a "signature mismatch vs testlib.h" error under
  # any backend. Before the fix, the GCC pathway compared
  # `const char *` to `char *` directly and rejected as incompatible.
  # The fix dereferences both sides so `__builtin_types_compatible_p`
  # sees `const char` vs `char` — top-level qualifiers ignored,
  # types match.
  test "testlib: const char* return binds to cstring (#11)":
    check loadTestlib().kind in {lrOk, lrOkPartial}
    check $testlib_const_string() == "hello from testlib"

  test "testlib: const char* return with arg (#11)":
    check loadTestlib().kind in {lrOk, lrOkPartial}
    check $testlib_const_lookup(0.cint) == "zero"
    check $testlib_const_lookup(2.cint) == "two"
    check $testlib_const_lookup(99.cint) == "out-of-range"

  test "testlib: non-const char* return still works (#11 regression baseline)":
    check loadTestlib().kind in {lrOk, lrOkPartial}
    check $testlib_mutable_string() == "mutable"

  test "testlib: unload nils function pointers":
    check loadTestlib().kind in {lrOk, lrOkPartial}
    unloadTestlib()
    expect SoftlinkError:
      discard testlib_add(1.cint, 2.cint)

  test "testlib: idempotent partial load":
    let r1 = loadTestlib()
    check r1.kind == lrOkPartial
    let r2 = loadTestlib()
    check r2.kind == lrOkPartial
    check r2.missing == @["testlib_future", "testlib_future_nv"]

  test "testlib: reload after unload preserves partial status":
    check loadTestlib().kind == lrOkPartial
    unloadTestlib()
    check not testlibLoaded()
    let r = loadTestlib()
    check r.kind == lrOkPartial

  test "testlib: unload then call raises SoftlinkError":
    check loadTestlib().kind in {lrOk, lrOkPartial}
    unloadTestlib()
    expect SoftlinkError:
      discard testlib_add(1.cint, 2.cint)

  test "testlib: SoftlinkError has library name":
    unloadTestlib()
    try:
      discard testlib_add(1.cint, 2.cint)
      fail()
    except SoftlinkError as e:
      check e.symbol == "testlib_add"
      check e.library == TestLib

  # RFC-0001 §9/§C.1, slice C1b: versionProbe behaviors exercised through
  # TestLib's single, mode-controlled probe (see `ProbeMode`/`probeMode`
  # above the `dynlib TestLib:` block). Probe outcome never affects
  # `LoadResult.kind`/`.missing` (proven throughout this whole file's
  # OTHER testlib: tests, which keep passing no matter what `probeMode` a
  # prior test left behind) — so test-order independence only requires
  # each test to set its OWN mode before acting, not to reset it
  # afterward; done anyway, for hygiene.
  test "versionProbe: probe calling a bound wrapper — version parses, failed flag clear (item 1)":
    probeMode = pmNormal
    unloadTestlib()
    let r = loadTestlib()
    check r.kind == lrOkPartial
    check softlinkProbedVersionTestlib == "1.5"
    check softlinkProbeFailedTestlib == false
    probeMode = pmNormal

  test "versionProbe: unparseable returned string -> failed flag set, version empty (item 4)":
    probeMode = pmUnparseable
    unloadTestlib()
    let r = loadTestlib()
    check r.kind == lrOkPartial
    check softlinkProbedVersionTestlib == ""
    check softlinkProbeFailedTestlib == true
    probeMode = pmNormal

  test "versionProbe: reentrant unloadTestlib() call from its own probe is converted, not escaped (item 3, unload variant)":
    probeMode = pmReentrantUnload
    unloadTestlib()
    let r = loadTestlib()
    check r.kind == lrOkPartial
    check softlinkProbedVersionTestlib == ""
    check softlinkProbeFailedTestlib == true
    probeMode = pmNormal

  test "versionProbe: unloadTestlib() resets probed version and failed flag to zero values, reload still works (item 5)":
    probeMode = pmNormal
    unloadTestlib()
    discard loadTestlib()
    check softlinkProbedVersionTestlib == "1.5"
    check softlinkProbeFailedTestlib == false
    unloadTestlib()
    check softlinkProbedVersionTestlib == ""
    check softlinkProbeFailedTestlib == false
    let r = loadTestlib()
    check r.kind == lrOkPartial
    check softlinkProbedVersionTestlib == "1.5"

  test "versionProbe: idempotent (already-loaded) call does not re-run the probe (item 8)":
    probeMode = pmNormal
    unloadTestlib()
    discard loadTestlib()
    let before = probeRunCount
    discard loadTestlib()
    discard loadTestlib()
    check probeRunCount == before

  # RFC-0001 §9/§C.2, slice C2 — TDD suite item 2: TestLib's own block
  # carries a versionProbe but no compatManifest, so a successful load must
  # report atNoManifest with the probed version populated.
  test "CompatReport: probe succeeds, no manifest attached -> atNoManifest + runtimeVersion (item 2)":
    probeMode = pmNormal
    unloadTestlib()
    discard loadTestlib()
    let c = testlibCompat()
    check c.attestation == atNoManifest
    check c.runtimeVersion == "1.5"
    check c.missing.len == 0
    probeMode = pmNormal

  # TDD suite item 3 — reusing pmUnparseable (already proven to fail
  # parseVersion above): the compat report must show atProbeFailed with an
  # empty runtimeVersion.
  test "CompatReport: probe fails (unparseable) -> atProbeFailed, runtimeVersion empty (item 3)":
    probeMode = pmUnparseable
    unloadTestlib()
    discard loadTestlib()
    let c = testlibCompat()
    check c.attestation == atProbeFailed
    check c.runtimeVersion == ""
    check c.missing.len == 0
    probeMode = pmNormal

  # TDD suite item 6: unloadTestlib() must reset fooCompat() to the zero
  # report, and a subsequent reload must repopulate it — never serving a
  # previous load's trust signals.
  test "CompatReport: unloadTestlib resets to zero report; reload repopulates (item 6)":
    probeMode = pmNormal
    unloadTestlib()
    discard loadTestlib()
    check testlibCompat().attestation == atNoManifest
    check testlibCompat().runtimeVersion == "1.5"
    unloadTestlib()
    let zero = testlibCompat()
    check zero.attestation == atNoProbe
    check zero.runtimeVersion == ""
    check zero.missing.len == 0
    discard loadTestlib()
    let reloaded = testlibCompat()
    check reloaded.attestation == atNoManifest
    check reloaded.runtimeVersion == "1.5"

  # Compile-time validation tests
  test "compile-time: rejects proc without calling convention":
    check not compiles(block:
      dynlib "libfoo.so":
        proc foo(x: cint): cint {.header: "math.h".}
    )

  test "compile-time: rejects unsupported pragma (varargs)":
    check not compiles(block:
      dynlib "libfoo.so":
        proc foo(x: cint): cint {.cdecl, varargs, header: "math.h".}
    )

  test "compile-time: rejects proc without header":
    check not compiles(block:
      dynlib "libfoo.so":
        proc foo(x: cint): cint {.cdecl.}
    )

  # Defect A regression (#14) — duplicate dynlib blocks for the same library —
  # cannot be tested with compiles() here: dynlib generates exported procs
  # (loadFoo*), which are only legal at top level, so ANY dynlib inside a
  # compiles(block:) fails for that unrelated reason. Instead the nimble test
  # task compiles tests/tfail_duplicate_dynlib.nim expecting the clear
  # "collides with an earlier dynlib block" error.

# Missing library — for lrLibNotFound test
dynlib "libdefinitely_not_real.so":
  proc testlib_notreal(): cint {.cdecl, header: "tests/testlib.h".}

# RFC-0001 §9/§C.2, slice C2 — TDD suite item 5: a versionProbe DECLARED on
# a library that never loads. Phase 1 fails before Phase 3/the probe ever
# runs, so `fooCompat()` must report the zero state (atNoProbe) — not a
# fabricated atProbeFailed — per the judgment call recorded in the C2
# handoff (softlink.nim's loadX codegen: the Phase-1 early-return report
# writes are always the zero-field form, regardless of hasProbe).
dynlib "libdefinitely_not_real_c2.so":
  proc testlib_notreal_c2(): cint {.cdecl, header: "tests/testlib.h".}
  versionProbe:
    "9.9.9"

# dyntype — compile-time struct layout verification
dyntype "tests/testlib_types.h":
  type TestlibPoint {.ctype: "testlib_point_t".} = object
    x: cint
    y: cint

  type TestlibTaggedValue {.ctype: "testlib_tagged_value_t".} = object
    value: cdouble
    flags: cint

  type TestlibRect {.ctype: "testlib_rect_t".} = object
    origin: TestlibPoint
    width: cint
    height: cint

  type TestlibPointExported* {.ctype: "testlib_point_t".} = object
    x: cint
    y: cint

suite "dyntype":
  test "verified type is defined and usable":
    var p: TestlibPoint
    p.x = 10
    p.y = 20
    check p.x == 10
    check p.y == 20

  test "multiple types verified in one block":
    var tv: TestlibTaggedValue
    tv.value = 3.14
    tv.flags = 42
    check tv.value == 3.14
    check tv.flags == 42

  test "nested struct verified":
    var r: TestlibRect
    r.origin.x = 1
    r.origin.y = 2
    r.width = 100
    r.height = 200
    check r.origin.x == 1
    check r.width == 100

  test "compile-time: rejects type without ctype":
    check not compiles(block:
      dyntype "tests/testlib_types.h":
        type BadType = object
          x: cint
    )

  test "compile-time: rejects non-type in body":
    check not compiles(block:
      dyntype "tests/testlib_types.h":
        proc foo() = discard
    )

  test "compile-time: rejects empty header":
    check not compiles(block:
      dyntype "":
        type BadType {.ctype: "foo_t".} = object
          x: cint
    )

  test "compile-time: rejects unsupported pragma on type":
    check not compiles(block:
      dyntype "tests/testlib_types.h":
        type BadType {.ctype: "testlib_point_t", deprecated.} = object
          x: cint
          y: cint
    )

  test "exported type verified":
    var p: TestlibPointExported
    p.x = 42
    check p.x == 42

  test "compile-time: rejects duplicate type name":
    check not compiles(block:
      dyntype "tests/testlib_types.h":
        type Dup {.ctype: "testlib_point_t".} = object
          x: cint
          y: cint
        type Dup {.ctype: "testlib_point_t".} = object
          x: cint
          y: cint
    )

  # NOTE: sizeof mismatch (e.g., wrong number of fields) is caught by
  # _Static_assert at C compile time, not Nim compile time. Can't test
  # with compiles(). Verified manually in Docker — see task #7.

suite "softlink — error paths":
  test "lrLibNotFound for missing library":
    check loadDefinitelyNotReal().kind == lrLibNotFound

  # RFC-0001 §9/§C.5 — degradation matrix, cell 3 ("neither" — no
  # versionProbe, no compatManifest at all, the plain pre-Stage-C shape):
  # `definitelyNotRealC2Compat` (directly below) already pins this for a
  # block that DOES declare a probe but never reaches it (Phase 1 fails
  # first). The genuinely probe-less/manifest-less `libdefinitely_not_real.so`
  # block above must degrade identically after a failed load — zero
  # report, unconditionally, exactly like every other return path.
  test "CompatReport: zero report (atNoProbe) after a failed load, no probe declared at all":
    check loadDefinitelyNotReal().kind == lrLibNotFound
    let c = definitelyNotRealCompat()
    check c.attestation == atNoProbe
    check c.runtimeVersion == ""
    check c.missing.len == 0

  # RFC-0001 §9/§C.2, slice C2 — TDD suite item 5: fooCompat() after a
  # FAILED load, even with a versionProbe declared on the block, must
  # report the zero state — the probe never got a chance to run.
  test "CompatReport: zero report (atNoProbe) after a failed load, even with a probe declared":
    check loadDefinitelyNotRealC2().kind == lrLibNotFound
    let c = definitelyNotRealC2Compat()
    check c.attestation == atNoProbe
    check c.runtimeVersion == ""
    check c.missing.len == 0

when defined(linux):
  suite "softlink — angle-bracket includes":
    test "angle-bracket header syntax works":
      check loadM().kind == lrOk
      check round(2.7) == 3.0

  suite "softlink — effect tracking":
    test "wrapper procs have {.raises: [SoftlinkError].}":
      # This proc compiles only if ceil's raises list is [SoftlinkError],
      # not the conservative [Exception]
      proc usesCeil(): cdouble {.raises: [SoftlinkError].} =
        ceil(1.1)
      check loadM().kind == lrOk
      check usesCeil() == 2.0

  suite "softlink — callback pointers":
    test "xxxPtr returns typed function pointer for callback use":
      check loadM().kind == lrOk
      let fn = ceilPtr()
      check fn != nil
      # Call directly — no cast needed, already typed
      check fn(2.3) == 3.0

    test "xxxPtr returns nil when not loaded":
      unloadM()
      check ceilPtr() == nil

    test "xxxPtr type is compatible with matching proc params":
      # xxxPtr returns the proc type with {.cdecl, raises: [].}
      proc takesCallback(cb: proc(x: cdouble): cdouble {.cdecl, raises: [].}): cdouble {.raises: [].} =
        cb(1.1)
      check loadM().kind == lrOk
      check takesCallback(ceilPtr()) == 2.0


# End-to-end magic: a bare logical name must resolve to the real on-disk
# file via deriveLibPattern. testlib.c is compiled to libmagic.so (see the
# nimble test task); "magic" must resolve to it.
dynlib "magic":
  proc testlib_magic(): cint {.cdecl, header: "tests/testlib.h".}

# RFC-0001 §9/§C.5 — degradation matrix, cell 4: `unloadX` on a block that
# was NEVER loaded, has no versionProbe, and has no compatManifest — must
# be a total no-op yielding the zero-state report. This is the ONLY place
# in this file "magic" is touched before the suite directly below loads it
# for the first time (nothing above this point calls loadMagic/unloadMagic),
# so this test genuinely observes the pristine, never-loaded state — not
# merely "unloaded after a prior load" (which the very next suite's own
# reset-after-load coverage already pins).
#
# Judgment call, recorded here rather than silently claimed: the C4c
# handoff flagged "unload on a never-loaded block" as worth a dedicated
# test, framing it as pinning the report/probe/drift-story resets' move
# OUT of the `if not handle.isNil` guard (commit 773162d). Empirically
# reverting that exact restructuring (moving the reset back inside the
# guard) does NOT fail this test — a probe-less, drift-less block's
# report is ALREADY the zero state before unload ever runs, so the
# restructuring is observably a no-op here by construction; ONLY a block
# that reached a non-zero report with a nil handle (C4c's own required-
# drift-refusal unwind) can distinguish the two placements, and
# `tests/tcompat_drift_required.nim`'s own "unload after a refused load
# resets the report" test already pins exactly that (verified directly:
# reverting the restructuring fails THAT test, not this one). What THIS
# test is actually, empirically sensitive to (verified the same way) is
# the more fundamental `if not handle.isNil` guard around the
# handle/pointer/cached-result reset — removing it entirely turns any
# never-loaded `unloadX()` call into a SIGSEGV (`unloadLib` on a nil
# handle). It also pins the "byte-identical" claim (§C.3/RFC §9 C5) that
# a plain, directive-less block's `unloadX` never required a prior load
# to begin with.
suite "CompatReport degradation (RFC-0001 C5) — unloadX on a never-loaded block (cell 4)":
  test "unloadMagic before any load is a no-op; report is already the zero state":
    check not magicLoaded()
    unloadMagic()
    check not magicLoaded()
    let c = magicCompat()
    check c.attestation == atNoProbe
    check c.runtimeVersion == ""
    check c.missing.len == 0
    # A subsequent, real load still works — the no-op unload didn't
    # corrupt anything.
    check loadMagic().kind == lrOk
    check testlib_magic() == 42
    unloadMagic()

suite "dynlib magic — bare logical name resolves and loads":
  test "dynlib \"magic\" resolves to libmagic.so and calls its symbol":
    check loadMagic().kind == lrOk
    check testlib_magic() == 42

# RFC-0001 §9/§C.2, slice C2 — TDD suite item 1: a probe-less block's
# fooCompat() must be the zero report (atNoProbe) across a full
# load/unload cycle — no versionProbe was ever declared on "magic" above,
# so there is nothing to attest to at any point.
suite "CompatReport (RFC-0001 C2) — probe-less block stays atNoProbe":
  test "fooCompat is zero report before load, after load, and after unload":
    unloadMagic()
    block:
      let c = magicCompat()
      check c.attestation == atNoProbe
      check c.runtimeVersion == ""
      check c.missing.len == 0
    check loadMagic().kind == lrOk
    block:
      let c = magicCompat()
      check c.attestation == atNoProbe
      check c.runtimeVersion == ""
      check c.missing.len == 0
    unloadMagic()
    block:
      let c = magicCompat()
      check c.attestation == atNoProbe
      check c.runtimeVersion == ""
      check c.missing.len == 0
    discard loadMagic()


# Runtime-only single-component soname: libvern.so.3 exists but NO bare
# libvern.so (the Debian `libz3.so.4` situation). Magic must fall back to a
# versioned major candidate. Linux-only — ELF soname convention.
# (Multi-component sonames like openSUSE's libz3.so.4.15 are out of scope for
# magic resolution — see deriveLibPattern's doc; they use the escape hatch.)
when defined(linux):
  dynlib "vern":
    proc testlib_versioned(): cint {.cdecl, header: "tests/testlib.h".}

  suite "dynlib magic — runtime-only versioned soname":
    test "resolves libvern.so.3 with no bare libvern.so present":
      check loadVern().kind == lrOk
      check testlib_versioned() == 7


# RFC-0001 slice B0: softlink/versions — comparator + pinned types.
# Property-style unit tests only; no interval/manifest/JSON logic exists yet
# (that's B1+), so nothing behavioral is tested for VersionInterval/
# SymbolFacts beyond their shape.
suite "softlink/versions — B0 version comparator":
  test "digit runs alone: 4.9.0 < 4.10.0 (the string-compare trap)":
    # Plain string comparison would say "4.10.0" < "4.9.0" (byte '1' < '9');
    # this is the whole reason the comparator parses digit runs as integers.
    check cmpVersion("4.9.0", "4.10.0") < 0
    check cmpVersion("4.10.0", "4.9.0") > 0

  test "OpenSSL-style alpha suffixes preserve order: 1.1.1a < 1.1.1w":
    check cmpVersion("1.1.1a", "1.1.1w") < 0

  test "bijective base-26 rollover: 1.0.2z < 1.0.2za":
    # Collapsing letter suffixes to a single ordinal would break exactly
    # here (z=26 vs a naive "za"-as-one-token); bijective base-26 restores
    # a total order across the two-letter rollover.
    check cmpVersion("1.0.2z", "1.0.2za") < 0

  test "4-component Z3-style version parses digit+alpha runs: 4.15.8p1":
    check parseVersion("4.15.8p1") == some(@[4, 15, 8, 16, 1])

  test "bijective base-26 spot values: a=1, z=26, aa=27, za=677":
    check parseVersion("a") == some(@[1])
    check parseVersion("z") == some(@[26])
    check parseVersion("aa") == some(@[27])
    check parseVersion("za") == some(@[677])

  test "trailing-zero padding: 1.2 == 1.2.0 (missing components are 0)":
    check parseVersion("1.2") == some(@[1, 2])
    check parseVersion("1.2.0") == some(@[1, 2, 0])
    check cmpVersion("1.2", "1.2.0") == 0
    check cmpVersion("1.2.0", "1.2") == 0

  test "case folding: alpha runs are case-insensitive":
    check parseVersion("ZA") == parseVersion("za")
    check cmpVersion("1.0.0A", "1.0.0a") == 0

  test "no runs at all fails to parse (never raises)":
    check parseVersion("").isNone
    check parseVersion("...").isNone
    check parseVersion("-").isNone
    check parseVersion("+++").isNone

  test "total order sanity: antisymmetry over a fixed version list":
    let vs = ["1.0.0", "1.0.1", "1.1.0", "1.9.0", "1.10.0", "2.0.0",
               "2.0.0a", "2.0.0b", "2.0.0za", "10.0.0"]
    for i in 0 ..< vs.len:
      for j in 0 ..< vs.len:
        check cmpVersion(vs[i], vs[j]) == -cmpVersion(vs[j], vs[i])

  test "total order sanity: the fixed list is strictly increasing (transitivity spot check)":
    let vs = ["1.0.0", "1.0.1", "1.1.0", "1.9.0", "1.10.0", "2.0.0",
               "2.0.0a", "2.0.0b", "2.0.0za", "10.0.0"]
    for i in 0 ..< vs.len - 1:
      check cmpVersion(vs[i], vs[i + 1]) < 0
    # transitivity: vs[0] < vs[1] and vs[1] < vs[2] implies vs[0] < vs[2]
    check cmpVersion(vs[0], vs[2]) < 0

  test "VersionInterval/SymbolFacts: pinned shapes only (no interval logic yet)":
    # B0 pins the TYPES the harvester (B6b) and Stage C will populate; this
    # slice does not implement containment, compression, or JSON. "" means
    # unbounded by convention (documented on the type), not asserted here.
    let unbounded = VersionInterval(lo: "", hi: "")
    check unbounded.lo == ""
    check unbounded.hi == ""
    let bounded = VersionInterval(lo: "1.0.0", hi: "2.0.0")
    check bounded.lo == "1.0.0"
    check bounded.hi == "2.0.0"
    var facts = SymbolFacts(cname: "testlib_add")
    facts.header[fkVerified].add VersionInterval(lo: "1.0.0", hi: "2.0.0")
    facts.header[fkAbsent].add VersionInterval(lo: "", hi: "1.0.0")
    check facts.cname == "testlib_add"
    check facts.header[fkVerified].len == 1
    check facts.header[fkMismatch].len == 0
    check facts.header[fkUnknown].len == 0

  test "contains: half-open membership, both bounds unbounded":
    check VersionInterval(lo: "", hi: "").contains("0.0.1")
    check VersionInterval(lo: "", hi: "").contains("99.0.0")

  test "contains: lo inclusive, hi exclusive":
    let iv = VersionInterval(lo: "1.0.0", hi: "2.0.0")
    check not iv.contains("0.9.9")
    check iv.contains("1.0.0")
    check iv.contains("1.5.0")
    check not iv.contains("2.0.0")
    check not iv.contains("2.0.1")

  test "contains: one-sided bounds":
    check VersionInterval(lo: "2.0.0", hi: "").contains("2.0.0")
    check VersionInterval(lo: "2.0.0", hi: "").contains("99.0.0")
    check not VersionInterval(lo: "2.0.0", hi: "").contains("1.9.9")
    check VersionInterval(lo: "", hi: "2.0.0").contains("1.9.9")
    check not VersionInterval(lo: "", hi: "2.0.0").contains("2.0.0")

  test "abiTag: <os>-<datamodel> shape, matches this build's target":
    let tag = abiTag()
    check '-' in tag
    when defined(linux):
      check tag.startsWith("linux-")
    elif defined(macosx):
      check tag.startsWith("macosx-")
    elif defined(windows):
      check tag.startsWith("windows-")
    when sizeof(clong) == 8 and sizeof(pointer) == 8:
      check tag.endsWith("-lp64")
    elif sizeof(clong) == 4 and sizeof(pointer) == 8:
      check tag.endsWith("-llp64")
    elif sizeof(clong) == 4 and sizeof(pointer) == 4:
      check tag.endsWith("-ilp32")

# RFC-0001 §B.3/§B.5, slice B6a: softlink/manifest — pure parse/validate
# predicates, tested directly (no macro involved) against the golden
# fixture already used elsewhere in this suite's corpus
# (tests/corpus/expected.compat.json).
suite "softlink/manifest — parse + validation predicates (RFC-0001 §B.3/§B.5)":
  const fixturePath = "tests/corpus/expected.compat.json"
  let fixtureText = readFile(fixturePath)

  test "parseManifest: schema/lib/abi/corpus/symbols, golden fixture":
    let m = parseManifest(fixtureText, fixturePath)
    check m.schema == 1
    check m.lib == "corpuslib"
    check m.abi == "linux-lp64"
    check m.corpus == @["1.0.0", "2.0.0", "3.0.0"]
    check m.symbols.len == 3
    check schemaSupported(m)
    check libIdentityOk(m, "corpuslib")
    check not libIdentityOk(m, "otherlib")
    check abiOk(m, "linux-lp64")
    check not abiOk(m, "windows-llp64")

  test "parseManifest: malformed JSON raises ManifestError":
    expect(ManifestError):
      discard parseManifest("not json", "bogus.json")

  test "parseManifest: missing required key raises ManifestError":
    expect(ManifestError):
      discard parseManifest("""{"schema": 1, "lib": "x"}""", "bogus.json")

  test "schemaSupported: false for a newer schema value":
    var m = parseManifest(fixtureText, fixturePath)
    m.schema = 2
    check not schemaSupported(m)

  test "validateDisjointExhaustive: golden fixture has no violations":
    let m = parseManifest(fixtureText, fixturePath)
    check validateDisjointExhaustive(m).len == 0

  test "validateDisjointExhaustive: detects an injected overlap":
    var m = parseManifest(fixtureText, fixturePath)
    for i in 0 ..< m.symbols.len:
      if m.symbols[i].cname == "corpuslib_stable":
        # corpuslib_stable is already verified/hi:3.0.0 + unknown/lo:3.0.0;
        # also marking it mismatch across the whole corpus creates overlap.
        m.symbols[i].header[fkMismatch] = @[VersionInterval(lo: "", hi: "")]
    let violations = validateDisjointExhaustive(m)
    check violations.len > 0
    check violations[0].cname == "corpuslib_stable"

  test "validateDisjointExhaustive: detects an injected gap":
    var m = parseManifest(fixtureText, fixturePath)
    for i in 0 ..< m.symbols.len:
      if m.symbols[i].cname == "corpuslib_added":
        # corpuslib_added: absent/hi:2.0.0, verified/lo:2.0.0-hi:3.0.0,
        # unknown/lo:3.0.0. Narrowing verified's hi to before 3.0.0 opens a
        # gap that nothing else covers.
        m.symbols[i].header[fkVerified] = @[VersionInterval(lo: "2.0.0", hi: "2.0.0")]
    let violations = validateDisjointExhaustive(m)
    check violations.len > 0
    check violations.anyIt(it.cname == "corpuslib_added" and it.matchCount == 0)

  test "checkSince: claim too early — a later corpus version is absent":
    let m = parseManifest(fixtureText, fixturePath)
    # corpuslib_added is absent through 2.0.0 (exclusive), verified from 2.0.0.
    let sc = checkSince(m, "corpuslib_added", "1.0.0")
    check sc.contradicted
    check "2.0.0" in sc.message

  test "checkSince: claim too late — an earlier corpus version is already declared":
    let m = parseManifest(fixtureText, fixturePath)
    let sc = checkSince(m, "corpuslib_added", "3.0.0")
    check sc.contradicted
    check "2.0.0" in sc.message

  test "checkSince: claim matches the manifest — no contradiction":
    let m = parseManifest(fixtureText, fixturePath)
    check not checkSince(m, "corpuslib_added", "2.0.0").contradicted

  test "checkSince: symbol absent from manifest entirely — no check possible":
    let m = parseManifest(fixtureText, fixturePath)
    check not checkSince(m, "corpuslib_nonexistent", "1.0.0").contradicted

  test "mismatchedSymbols / notInManifest":
    let m = parseManifest(fixtureText, fixturePath)
    check mismatchedSymbols(m, @["corpuslib_changed", "corpuslib_stable"]) ==
      @["corpuslib_changed"]
    check notInManifest(m, @["corpuslib_stable", "not_a_real_symbol"]) ==
      @["not_a_real_symbol"]

  # RFC-0001 §C.2/§C.3, slice C3: `classifyAbsence` — the pure decision
  # func behind the runtime absence partition (`mrExpected`/`mrAnomalous`),
  # tested directly against the same golden fixture, no macro/loadX
  # involved. `corpuslib_added`/`corpuslib_changed`/`corpuslib_stable`'s
  # interval shapes (see the fixture read above) are reused as-is.
  test "classifyAbsence: version in an absent interval -> acExpected":
    let m = parseManifest(fixtureText, fixturePath)
    check classifyAbsence(m.symbols, "corpuslib_added", "1.0.0", "") == acExpected

  test "classifyAbsence: version in a verified interval -> acAnomalous":
    let m = parseManifest(fixtureText, fixturePath)
    check classifyAbsence(m.symbols, "corpuslib_added", "2.5.0", "") == acAnomalous

  test "classifyAbsence: version in a mismatch interval -> acAnomalous (judgment call)":
    # A symbol that never resolved, whose headers at this version are
    # already known to have DRIFTED, is still "the headers declare it, yet
    # it did not resolve" (RFC-0001 §C.2's own wording for mrAnomalous) —
    # not a separate case, and not honest-ignorance either.
    let m = parseManifest(fixtureText, fixturePath)
    check classifyAbsence(m.symbols, "corpuslib_changed", "2.5.0", "") == acAnomalous

  test "classifyAbsence: version in an unknown interval, no since -> acNone":
    let m = parseManifest(fixtureText, fixturePath)
    check classifyAbsence(m.symbols, "corpuslib_stable", "3.5.0", "") == acNone

  test "classifyAbsence: unknown interval, but since is still ahead -> acExpected":
    let m = parseManifest(fixtureText, fixturePath)
    check classifyAbsence(m.symbols, "corpuslib_stable", "3.5.0", "5.0.0") == acExpected

  test "classifyAbsence: unknown interval, since already passed -> acNone":
    let m = parseManifest(fixtureText, fixturePath)
    check classifyAbsence(m.symbols, "corpuslib_stable", "3.5.0", "1.0.0") == acNone

  test "classifyAbsence: symbol entirely absent from manifest, no since -> acNone":
    let m = parseManifest(fixtureText, fixturePath)
    check classifyAbsence(m.symbols, "not_a_real_symbol", "1.0.0", "") == acNone

  test "classifyAbsence: symbol entirely absent from manifest, since covers it -> acExpected":
    let m = parseManifest(fixtureText, fixturePath)
    check classifyAbsence(m.symbols, "not_a_real_symbol", "1.0.0", "5.0.0") == acExpected

  # RFC-0001 §C.3, slice C4b: `firstMismatchInterval`/`formatInterval` —
  # the pure runtime drift-refusal lookup and its story-text renderer,
  # tested directly against the same golden fixture (`corpuslib_changed`:
  # verified/hi:2.0.0, mismatch/[2.0.0,3.0.0), unknown/lo:3.0.0), no
  # macro/loadX involved — mirrors `classifyAbsence`'s own suite shape
  # directly above.
  test "firstMismatchInterval: version inside the mismatch interval -> some(iv)":
    let m = parseManifest(fixtureText, fixturePath)
    let iv = firstMismatchInterval(m.symbols, "corpuslib_changed", "2.5.0")
    check iv.isSome
    check iv.get == VersionInterval(lo: "2.0.0", hi: "3.0.0")

  test "firstMismatchInterval: version outside the mismatch interval -> none":
    let m = parseManifest(fixtureText, fixturePath)
    check firstMismatchInterval(m.symbols, "corpuslib_changed", "1.0.0").isNone

  test "firstMismatchInterval: symbol has no mismatch facts at all -> none":
    let m = parseManifest(fixtureText, fixturePath)
    check firstMismatchInterval(m.symbols, "corpuslib_stable", "1.0.0").isNone

  test "firstMismatchInterval: symbol entirely absent from manifest -> none":
    let m = parseManifest(fixtureText, fixturePath)
    check firstMismatchInterval(m.symbols, "not_a_real_symbol", "1.0.0").isNone

  test "formatInterval: lower bound only -> \">=lo\"":
    check formatInterval(VersionInterval(lo: "4.16.0", hi: "")) == ">=4.16.0"

  test "formatInterval: upper bound only -> \"<hi\"":
    check formatInterval(VersionInterval(lo: "", hi: "5.0.0")) == "<5.0.0"

  test "formatInterval: both bounds -> \">=lo, <hi\"":
    check formatInterval(VersionInterval(lo: "2.0.0", hi: "3.0.0")) == ">=2.0.0, <3.0.0"

  test "formatInterval: unbounded both ways -> non-empty fallback text":
    check formatInterval(VersionInterval(lo: "", hi: "")).len > 0
