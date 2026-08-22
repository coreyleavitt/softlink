## Tests for softlink macro.
##
## Tests against system math/C libraries (Linux) and a custom test library (all platforms).
## Build the test library before running (see nimble test task).

import std/[unittest, math, strutils, sequtils]
import softlink {.all.}
import softlink/versions
import softlink/manifest
import softlink/gates
# code-review finding #13: the prototype tokenizer/analyzer this suite unit-
# tests directly (`tokenizePrototype`/`analyzePrototype`/
# `nonBuiltinIdentifiers` below) moved from `softlink.nim` itself into the
# internal `softlink/prototype` submodule — `import softlink {.all.}` above
# only bypasses visibility for symbols declared IN softlink.nim, not for an
# unexported symbol one of its submodules declares, so this second `{.all.}`
# import is needed to keep reaching them. Path-only change, no test logic.
import softlink/prototype {.all.}

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
  # applied to the *logical name*, never to the OS-expanded pattern — this
  # stays correct-by-construction regardless of what libNameToIdent does
  # with any one pattern shape, and remains load-bearing for hand-authored
  # explicit per-OS patterns with irreducibly different stems across
  # platforms (e.g. "(lib|)gtk-4-1.dll" vs "libgtk-4.so(|.1)" — RFC 0011's
  # `identBase` motivating case: no string-level normalization can unify
  # "4-1" and "4").
  test "logical name yields a stable, OS-independent base ident":
    check libNameToIdent("z3") == "Z3"
    check libNameToIdent("libz3") == "Z3"
  # RFC 0011 S0a item 2: the general leading-alternation `(lib|)`
  # normalization fix (see the "libNameToIdent — leading-alternation"
  # suite below) closes this exact trap for bare-stem libraries —
  # deriveLibPattern's Windows form "(libz3|z3).dll" is the optional-lib
  # prefix spelled per-candidate rather than via "(lib|)"'s bare
  # alternation, and treating the two spellings differently would just be
  # the same bug under a different mask. The OS-expanded pattern is
  # therefore no longer a trap for this shape; this test is kept (renamed
  # from "is the trap... must avoid") as a live pin that it stays closed.
  test "the OS-expanded Windows pattern no longer diverges (RFC 0011 item 2)":
    check libNameToIdent(deriveLibPattern("z3", osWindows)) == "Z3"
    check libNameToIdent("z3") == libNameToIdent(deriveLibPattern("z3", osWindows))

suite "libNameToIdent — leading-alternation `(lib|)` normalization (RFC 0011 item 2)":
  # Bug: the optional-`lib` alternation the pattern grammar already defines
  # (`"(lib|)stem..."`, `"(libstem|stem)..."`) was NOT treated the same as
  # a literal "lib" prefix — only a plain startsWith("lib") was stripped.
  # Fix: a LEADING parenthesized alternation whose alternatives all reduce
  # to the same stem after optional-lib-prefix stripping is replaced by
  # that stem before the rest of the derivation (dot-truncation, non-alnum
  # stripping, capitalization) runs, unchanged.
  test "the motivating example: (lib|) bare optional prefix":
    check libNameToIdent("(lib|)glib-2.0-0.dll") == "Glib2"

  test "matches the equivalent Linux explicit-alternation pattern":
    check libNameToIdent("(lib|)glib-2.0-0.dll") ==
          libNameToIdent("libglib-2.0.so(|.0)")

  test "general form: two DIFFERENT alternatives that reduce to the same stem":
    # deriveLibPattern's own Windows shape: "(lib" & stem & "|" & stem & ")".
    check libNameToIdent("(libz3|z3).dll") == "Z3"
    check libNameToIdent("(libfoo|foo).so") == "Foo"

  test "alternative order doesn't matter":
    check libNameToIdent("(|lib)glib-2.dll") == "Glib2"

  test "alternatives that do NOT reduce to a common stem fall back unchanged":
    # No principled stem to pick — falls back to the pre-fix behavior (the
    # whole leading group survives into the non-alnum strip).
    check libNameToIdent("(libfoo|bar).dll") == "Libfoobar"

  test "malformed group (no closing paren) falls back unchanged, never crashes":
    check libNameToIdent("(unbalanced.dll") == "Unbalanced"

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
  # RFC-0002 §4.4/§4.9, slice C4b/C4c: declared-bound refusal at the
  # manifest-LESS `atNoManifest` site. This block carries THREE bounded
  # procs sharing the identical declared interval `[1.0.0, 99.0.0)` by
  # fixture coincidence: `testlib_add` (REQUIRED, `until` only —
  # slice A3's own prototype+until control), `testlib_noop` (REQUIRED,
  # both bounds — slice A2's own control), and `testlib_gated_v2`
  # (OPTIONAL, both bounds — C4b's original target). Declared-bound
  # candidates are checked REQUIRED-then-optional, in PROC DECLARATION
  # ORDER within each list (mirrors the attested loop's own ordering) —
  # `testlib_add` is declared before `testlib_noop`, so at a probe that
  # decisively hits `until` (both required procs' shared bound), C4c's
  # "first hit wins" unwind fires on `testlib_add`, short-circuiting
  # `testlib_noop`'s own check and EVERY optional check (incl.
  # `testlib_gated_v2`'s) for that same load attempt. At a probe that
  # decisively hits `since` (below "1.0.0"), only `testlib_noop` carries
  # a `since` bound at all (`testlib_add` has none), so it is the one
  # that fires.
  pmAboveUntil      ## "100.0" — decisively at-or-above the shared until;
                    ## `testlib_add` (REQUIRED, first in decl order) wins
  pmBelowSince      ## "0.5" — decisively below the shared since;
                    ## `testlib_add` has no since bound, so `testlib_noop`
                    ## (REQUIRED) wins
  pmTieUntil        ## "99.0.0-rc1" — numeric prefix ties until for all
                    ## three procs, alpha tail -> not comparable for all;
                    ## no refusal fires for anyone, load proceeds normally

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
  # RFC-0002 §4.1/§6, slice A3 positive control: {.until.} + {.prototype.} +
  # {.header.} together is the one prototype-only shape `until` DOES accept
  # (cross-check mode — trackable via the header; see
  # tfail_until_prototype_only.nim for the no-header rejection this proves
  # isn't overbroad).
  # RFC-0002 §4.1/§5/§6, slice D1: `until` requires `verifyWhen` — gated on
  # `TESTLIB_VERSION < 99`, trivially true under the header's real (default
  # `TESTLIB_VERSION == 1`) value, so this stays a LIVE verification, not a
  # vacuous one — behavior-preserving for every check below.
  proc testlib_add(a: cint, b: cint): cint
    {.cdecl, header: "tests/testlib.h", prototype: "int testlib_add(int a, int b)",
      until: "99.0.0", verifyWhen: "TESTLIB_VERSION < 99".}
  # RFC-0002 §4.1/§6, slice A1: {.until: "x.y.z".} parses, validates, and
  # carries through exactly like {.since.} — no manifest/probe consumption
  # yet (later slices), so a valid claim here must compile and load/call
  # exactly as testlib_noop always has. Slice A2: carrying BOTH bounds
  # together is a non-empty interval [1.0.0, 99.0.0) — this proc is the
  # positive control proving the since>=until contradiction check (below,
  # tfail_since_until_empty_interval.nim) doesn't also reject valid,
  # correctly-ordered pairs.
  # RFC-0002 §4.1/§5/§6, slice D1: `until` requires `verifyWhen` — same
  # trivially-true-under-the-real-header gate as `testlib_add` above.
  proc testlib_noop() {.cdecl, since: "1.0.0", until: "99.0.0",
    verifyWhen: "TESTLIB_VERSION < 99", header: "tests/testlib.h".}
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
  # RFC-0002 §4.1/§6, slice A3 positive control: `until` coexisting with
  # `since` + `header` + `verifyWhen` + `optional` all on one proc — the
  # full allowlist minus `prototype` (that combination is testlib_add
  # above). Bounds are parse/carry only through A3 (no runtime effect yet),
  # so this is behavior-preserving for the dispatch check below.
  proc testlib_gated_v2(): cint
    {.cdecl, optional, verifyWhen: "TESTLIB_VERSION >= 2", header: "tests/testlib.h",
      since: "1.0.0", until: "99.0.0".}
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

  # RFC 0011 S0a item 4: statement pass-through in dynlib bodies. Binding
  # modules routinely interleave narrative type/const/helper definitions
  # with declarations (a struct's Nim type declared alongside the
  # functions that use it, not hoisted into a separate "types" file) — a
  # bodyless proc is still the only thing that means "resolve this symbol
  # at runtime"; everything else here passes through verbatim.

  # (a) the common direction: a `type` section declared first, used by a
  # LATER binding's own signature — no forward-reference concern, since
  # pointer vars are only emitted after every passed-through type/const
  # section in this block (see `dynlib`'s "hoisted" codegen).
  type
    ScaleFactor = distinct cint

  proc testlib_double(x: ScaleFactor): ScaleFactor {.cdecl, noverify.}

  # (b)/(c) helper procs WITH a body over the passed-through type — these
  # pass through verbatim (unlike the bodyless proc above, which is a
  # binding declaration).
  proc `==`(a, b: ScaleFactor): bool = cint(a) == cint(b)
  proc `$`(a: ScaleFactor): string = $cint(a)

  ## (d) a standalone doc-comment statement (`nnkCommentStmt`) — preserved
  ## verbatim, not merely tolerated, so docgen still sees it.

  # (e) the reverse direction (deliverable 2): the binding is declared
  # BEFORE the type it uses in its own signature — legal because
  # type/const sections are hoisted ahead of every pointer-var declaration
  # in this block, regardless of their own source position.
  proc testlib_triple(x: TripleFactor): TripleFactor {.cdecl, noverify.}

  type
    TripleFactor = distinct cint

  # (f) a passed-through const, exported like any other top-level const.
  const TestlibPassthroughMagic* = 7.cint

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
    of pmAboveUntil: "100.0"
    of pmBelowSince: "0.5"
    of pmTieUntil: "99.0.0-rc1"

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
  # RFC-0002 §4.1/§6, slice A1 verifyProcs parity: {.until.} must parse and
  # carry here too, composing harmlessly with an unrelated {.verifyWhen.}.
  # Slice A2 parity: {.since.} + {.until.} together form a non-empty
  # interval [1.0.0, 99.0.0) — the verifyProcs-side positive control for the
  # since>=until contradiction check (dynlib's is testlib_noop above).
  proc testlib_gated(): cint
    {.cdecl, verifyWhen: "TESTLIB_VERSION >= 1", since: "1.0.0", until: "99.0.0",
      header: "tests/testlib.h".}
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
    # F4 (code-review finding): the {.optional.} rejection branch itself had
    # zero test coverage — noverify and varargs (above) exercised the
    # surrounding rejection machinery, but not this specific pragma. Exact
    # diagnostic wording is separately pinned by a tfail fixture + nimble
    # grep (tests/tfail_verifyprocs_optional.nim) per this repo's convention
    # for pinning macro-error text; this `compiles()` check only proves the
    # branch actually rejects (matching this suite's existing style).
    check not compiles(block:
      verifyProcs:
        proc vp_optional(): cint {.cdecl, optional, header: "tests/testlib.h".}
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
    check c.missingReasons.len == 0
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
    check c.missingReasons.len == 0
    probeMode = pmNormal

  # TDD suite item 6: unloadTestlib() must reset fooCompat() to this
  # block's own "probe hasn't run" state, and a subsequent reload must
  # repopulate it — never serving a previous load's trust signals.
  # RFC-0001 §C.2, finding #11: TestLib's block DOES declare a
  # `versionProbe` (see `dynlib TestLib:` above), so its post-unload
  # zero-ish state is `atProbeNotRun` (transient — a reload will run the
  # probe again), never the permanent-structural `atNoProbe` (reserved for
  # blocks that declare no probe at all — see the "probe-less block stays
  # atNoProbe" suite further below for that contrast).
  test "CompatReport: unloadTestlib resets to atProbeNotRun; reload repopulates (item 6)":
    probeMode = pmNormal
    unloadTestlib()
    discard loadTestlib()
    check testlibCompat().attestation == atNoManifest
    check testlibCompat().runtimeVersion == "1.5"
    unloadTestlib()
    let zero = testlibCompat()
    check zero.attestation == atProbeNotRun
    check zero.runtimeVersion == ""
    check zero.missingReasons.len == 0
    discard loadTestlib()
    let reloaded = testlibCompat()
    check reloaded.attestation == atNoManifest
    check reloaded.runtimeVersion == "1.5"

  # RFC-0002 §4.4/§4.9, slice C4b/C4c: declared-bound refusal at the
  # manifest-LESS `atNoManifest` site — the second of §4.4's two sites
  # (the first, manifest-attached `atOutOfCorpus`, is
  # `tests/tcompat_report_manifest.nim`'s own suite). `pmAboveUntil` was
  # C4b's original OPTIONAL-only target (`testlib_gated_v2`); C4c adds
  # `testlib_add` (REQUIRED, `until` only, declared BEFORE `testlib_noop`
  # in the block — see the `ProbeMode` doc comment above) to the SAME
  # bound, "first hit wins" REQUIRED-then-declaration-order — so at this
  # probe the REQUIRED refusal fires and unwinds the WHOLE load before
  # `testlib_noop`'s or `testlib_gated_v2`'s own checks ever run.
  test "declared-bound refusal (RFC-0002 C4c): probe decisively ABOVE until, no manifest -> REQUIRED symbol unwinds the whole load":
    probeMode = pmAboveUntil
    unloadTestlib()
    let r = loadTestlib()
    check r.kind == lrSymbolNotFound
    check r.symbol == "testlib_add"
    check not testlibLoaded()
    let c = testlibCompat()
    check c.attestation == atNoManifest
    check c.runtimeVersion == "100.0"
    # §4.4: no facts-driven partition to compute in a manifest-less block —
    # missingReasons carries ONLY this refusal's own entry.
    check c.missingReasons.len == 1
    check c.missingReasons.anyIt(it.symbol == "testlib_add" and it.reason == mrDriftRefused)
    check c.missingReasons.filterIt(it.symbol == "testlib_add")[0].interval ==
      VersionInterval(lo: "", hi: "99.0.0")
    var caught: SoftlinkError
    try:
      discard testlib_add(2, 3)
      fail()
    except SoftlinkError as e:
      caught = e
    check caught != nil
    check "testlib_add" in caught.msg
    check "<99.0.0" in caught.msg
    check "refus" in caught.msg
    probeMode = pmNormal
    unloadTestlib()

  # C4c's "first hit wins" required-then-declaration-order check means a
  # probe hitting ONLY `since` (`testlib_add` has no `since` bound) skips
  # `testlib_add` entirely and lands on `testlib_noop` (REQUIRED, both
  # bounds) instead — proving the below-since symmetry for a REQUIRED
  # candidate too, for free (same shared `buildBoundCheck` fragment C4b's
  # own below-since test already exercises for the optional case).
  test "declared-bound refusal (RFC-0002 C4c): probe decisively BELOW since -> REQUIRED symbol unwinds the whole load (both-bounds symmetry)":
    probeMode = pmBelowSince
    unloadTestlib()
    let r = loadTestlib()
    check r.kind == lrSymbolNotFound
    check r.symbol == "testlib_noop"
    check not testlibLoaded()
    let c = testlibCompat()
    check c.attestation == atNoManifest
    check c.runtimeVersion == "0.5"
    check c.missingReasons.len == 1
    check c.missingReasons.anyIt(it.symbol == "testlib_noop" and it.reason == mrDriftRefused)
    check c.missingReasons.filterIt(it.symbol == "testlib_noop")[0].interval ==
      VersionInterval(lo: "1.0.0", hi: "99.0.0")
    var caught: SoftlinkError
    try:
      testlib_noop()
      fail()
    except SoftlinkError as e:
      caught = e
    check caught != nil
    check "testlib_noop" in caught.msg
    check ">=1.0.0" in caught.msg
    check "refus" in caught.msg
    probeMode = pmNormal
    unloadTestlib()

  # RFC-0002 §4.4, slice C4c: the tie is decided per bound, independently,
  # so it applies to `testlib_add`/`testlib_noop` (REQUIRED) exactly as it
  # does to `testlib_gated_v2` (OPTIONAL) — none of the three is refused,
  # and the load proceeds (required candidates never get a chance to
  # short-circuit anything here, since neither of them ever decides).
  test "declared-bound refusal (RFC-0002 C4b/C4c): boundary tie with an alpha run -> loads normally, probeNotComparable = true":
    probeMode = pmTieUntil
    unloadTestlib()
    let r = loadTestlib()
    check r.kind == lrOkPartial
    check "testlib_gated_v2" notin r.missing
    check testlib_gated_v2Available()
    check testlib_gated_v2() == 42
    check testlibLoaded()
    check testlib_add(2, 3) == 5
    testlib_noop()
    let c = testlibCompat()
    check c.attestation == atNoManifest
    check c.probeNotComparable
    check not c.missingReasons.anyIt(it.symbol == "testlib_gated_v2")
    check not c.missingReasons.anyIt(it.symbol == "testlib_add")
    check not c.missingReasons.anyIt(it.symbol == "testlib_noop")
    probeMode = pmNormal
    unloadTestlib()

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

suite "statement pass-through in dynlib bodies (RFC 0011 S0a item 4)":
  # The ScaleFactor/TripleFactor pair, `==`/`$` helpers, doc comment, and
  # `TestlibPassthroughMagic` const all live in the `dynlib TestLib:` block
  # above (tests/test_softlink.nim), interleaved with ordinary bindings —
  # reaching these tests at all already proves that whole block compiled.
  test "type declared BEFORE its binding: wrapper dispatches through the real C symbol":
    check loadTestlib().kind in {lrOk, lrOkPartial}
    check testlib_double(ScaleFactor(21.cint)) == ScaleFactor(42.cint)

  test "type declared AFTER its binding (deliverable 2, reverse direction)":
    check loadTestlib().kind in {lrOk, lrOkPartial}
    check cint(testlib_triple(TripleFactor(10.cint))) == 30.cint

  test "passed-through helper procs (== and $) over the passed-through type work":
    check ScaleFactor(4.cint) == ScaleFactor(4.cint)
    check not (ScaleFactor(4.cint) == ScaleFactor(5.cint))
    check $ScaleFactor(5.cint) == "5"

  test "passed-through const is visible outside the block, with its export marker intact":
    check TestlibPassthroughMagic == 7.cint

# RFC 0011 S0a item 3: `{.symbol: "c_name".}` rename pragma. `identBase` (RFC
# 0011 S0a item 1) disambiguates each block from the main `TestLib` block
# above and from each other, since all three re-bind the same real library.
#
# Block 1 (stories (a)/(b)/(h)-positive): `renamedAdd` gives `testlib_add` a
# second Nim name, cross-checked against BOTH the real header and a vendored
# prototype naming the C symbol (not the Nim alias) — proving the
# `{.prototype.}` name-match rule keys on `symbol:`'s C name. `renamedAdd2`
# is a THIRD Nim view of the exact same C symbol: two Nim procs, one
# `symAddr`, and — critically — not a duplicate-proc error (that check keys
# on the Nim name, which differs for all three).
dynlib TestLib:
  identBase "SymbolRename"
  proc renamedAdd(a: cint, b: cint): cint
    {.cdecl, header: "tests/testlib.h",
      prototype: "int testlib_add(int a, int b)", symbol: "testlib_add".}
  proc renamedAdd2(a: cint, b: cint): cint
    {.cdecl, header: "tests/testlib.h", symbol: "testlib_add".}

# Block 2 (story (d), required symbol): a bogus C name on a REAL library —
# the load must fail at the real, resolvable library, purely because the
# (renamed) symbol doesn't exist — and the report must name the bogus C
# symbol, never the Nim alias `requiredBogusAlias`. `{.noverify.}` because
# no header declares a symbol that doesn't exist.
dynlib TestLib:
  identBase "SymbolRenameBogusRequired"
  proc requiredBogusAlias(): cint
    {.cdecl, noverify, symbol: "testlib_symbol_rename_bogus_required".}

# Block 3 (story (d), optional symbol): same idea, but optional — the load
# still succeeds (lrOkPartial), and `missing`/`xxxAvailable()` must both
# reflect the bogus C symbol, not the Nim alias.
dynlib TestLib:
  identBase "SymbolRenameBogusOptional"
  proc optionalBogusAlias(): cint
    {.cdecl, optional, noverify, symbol: "testlib_symbol_rename_bogus_optional".}

suite "symbol rename pragma (RFC 0011 S0a item 3)":
  test "renamed proc loads and dispatches through the real C symbol (a)":
    check loadSymbolRename().kind in {lrOk, lrOkPartial}
    check renamedAdd(2, 3) == 5

  test "two Nim procs sharing one C symbol both dispatch correctly — two slots, one symAddr (b)":
    check renamedAdd2(2, 3) == 5
    check renamedAdd(10, 32) == renamedAdd2(10, 32)

  test "duplicate Nim proc names still error even when symbol: differs — the dup check keys on the Nim name (c)":
    check not compiles(block:
      verifyProcs:
        proc dupSymProc(): cint {.cdecl, header: "tests/testlib.h", symbol: "testlib_gated".}
        proc dupSymProc(): cint {.cdecl, header: "tests/testlib.h", symbol: "testlib_noop".}
    )

  test "compile-time: importc (bare and valued) is an unrecognized pragma in verifyProcs too, not a rename axis (e, verifyProcs parity)":
    check not compiles(block:
      verifyProcs:
        proc icBareVp(): cint {.cdecl, header: "tests/testlib.h", importc.}
    )
    check not compiles(block:
      verifyProcs:
        proc icValuedVp(): cint {.cdecl, header: "tests/testlib.h", importc: "testlib_noop".}
    )

  test "compile-time: symbol pragma argument validation (f)":
    check not compiles(block:
      verifyProcs:
        proc symBadTypeVp(): cint {.cdecl, header: "tests/testlib.h", symbol: 123.}
    )
    check not compiles(block:
      verifyProcs:
        proc symEmptyVp(): cint {.cdecl, header: "tests/testlib.h", symbol: "".}
    )
    check not compiles(block:
      verifyProcs:
        proc symBadIdentVp(): cint {.cdecl, header: "tests/testlib.h", symbol: "123bad".}
    )
    check compiles(block:
      verifyProcs:
        proc symOkVp(): cint {.cdecl, header: "tests/testlib.h", symbol: "testlib_noop".}
    )

  test "lrSymbolNotFound reports the C symbol, never the Nim alias, for a required renamed proc (d)":
    let r = loadSymbolRenameBogusRequired()
    check r.kind == lrSymbolNotFound
    check r.symbol == "testlib_symbol_rename_bogus_required"

  test "missing reports the C symbol, never the Nim alias, for an optional renamed proc (d)":
    let r = loadSymbolRenameBogusOptional()
    check r.kind == lrOkPartial
    check r.missing == @["testlib_symbol_rename_bogus_optional"]
    check not optionalBogusAliasAvailable()

  test "compile-time: symbol: is supported uniformly in verifyProcs, same parsing path as dynlib":
    check compiles(block:
      verifyProcs:
        proc vpRenamedAdd(a: cint, b: cint): cint
          {.cdecl, header: "tests/testlib.h", symbol: "testlib_add".}
    )

  test "compile-time: prototype name-match rule keys on the C symbol, not the Nim alias (h)":
    check not compiles(block:
      verifyProcs:
        proc protoAliasBadVp(a: cint, b: cint): cint
          {.cdecl, symbol: "testlib_add",
            prototype: "int protoAliasBadVp(int a, int b)".}
    )

# Missing library — for lrLibNotFound test
dynlib "libdefinitely_not_real.so":
  proc testlib_notreal(): cint {.cdecl, header: "tests/testlib.h".}

# RFC-0001 §9/§C.2, slice C2 — TDD suite item 5, revised for finding #11: a
# versionProbe DECLARED on a library that never loads. Phase 1 fails before
# Phase 3/the probe ever runs, so `fooCompat()` must report `atProbeNotRun`
# (the probe exists but hasn't run yet — transient, not the permanent
# `atNoProbe`) — not a fabricated `atProbeFailed` — per the judgment call
# recorded in the C2 handoff (softlink.nim's loadX codegen: the Phase-1
# early-return report writes always use `probeNotRunFields()`, never a
# fabricated post-probe classification, regardless of `hasProbe`).
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

  # RFC 0011 S0a item 5, story (e): the per-candidate OS-loader detail is
  # reachable through the generated `loadX` public API, both structured
  # (`LoadResult.attempts`) and as a one-line rendering (`osLoaderDetail`).
  # `libdefinitely_not_real.so` (declared above) is a single-candidate
  # pattern (no `(a|b)` alternation), so exactly one attempt is expected.
  test "osLoaderDetail: candidate name + OS error text reachable through the public LoadResult API":
    let r = loadDefinitelyNotReal()
    check r.kind == lrLibNotFound
    check r.attempts.len == 1
    check r.attempts[0].candidate == "libdefinitely_not_real.so"
    check r.attempts[0].osError.len > 0
    let detail = r.osLoaderDetail
    check "libdefinitely_not_real.so" in detail
    check r.attempts[0].osError in detail
    # A non-lrLibNotFound result renders no loader detail at all.
    check loadTestlib().osLoaderDetail == ""

  # RFC-0001 §9/§C.5 — degradation matrix, cell 3 ("neither" — no
  # versionProbe, no compatManifest at all, the plain pre-Stage-C shape):
  # `definitelyNotRealC2Compat` (directly below) pins the DIFFERENT,
  # finding-#11 outcome for a block that DOES declare a probe but never
  # reaches it (Phase 1 fails first) — `atProbeNotRun`, not `atNoProbe`. The
  # genuinely probe-less/manifest-less `libdefinitely_not_real.so` block
  # above is this test's own control: it degrades to the PERMANENT
  # `atNoProbe`, unconditionally, exactly like every other return path.
  test "CompatReport: zero report (atNoProbe) after a failed load, no probe declared at all":
    check loadDefinitelyNotReal().kind == lrLibNotFound
    let c = definitelyNotRealCompat()
    check c.attestation == atNoProbe
    check c.runtimeVersion == ""
    check c.missingReasons.len == 0

  # RFC-0001 §9/§C.2, slice C2 — TDD suite item 5, revised for finding #11:
  # fooCompat() on a block that DOES declare a versionProbe must report
  # `atProbeNotRun` — both in its pristine, never-loaded state (this block
  # is touched nowhere else in this file, so `definitelyNotRealC2Compat()`
  # below observes it genuinely untouched) and after a FAILED load (Phase 1
  # fails before Phase 3/the probe ever runs) — `atProbeNotRun` is
  # TRANSIENT, distinct from the permanent-structural `atNoProbe` the
  # probe-less sibling test above pins for `libdefinitely_not_real.so`.
  test "CompatReport: atProbeNotRun before load and after a failed load, when a probe IS declared":
    block:
      let c = definitelyNotRealC2Compat()
      check c.attestation == atProbeNotRun
      check c.runtimeVersion == ""
      check c.missingReasons.len == 0
    check loadDefinitelyNotRealC2().kind == lrLibNotFound
    let c = definitelyNotRealC2Compat()
    check c.attestation == atProbeNotRun
    check c.runtimeVersion == ""
    check c.missingReasons.len == 0

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
    check c.missingReasons.len == 0
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
      check c.missingReasons.len == 0
    check loadMagic().kind == lrOk
    block:
      let c = magicCompat()
      check c.attestation == atNoProbe
      check c.runtimeVersion == ""
      check c.missingReasons.len == 0
    unloadMagic()
    block:
      let c = magicCompat()
      check c.attestation == atNoProbe
      check c.runtimeVersion == ""
      check c.missingReasons.len == 0
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


# RFC 0011 S0a item 1: `identBase` overrides the derived identifier base.
# Motivating case: multiple dynlib blocks over ONE library needing distinct
# load-proc names — proven here by a SECOND block over the exact same
# `TestLib` pattern the main suite's own block (near the top of this file)
# already uses, which is only possible because `identBase` picks a
# different base (the dup-block guard fires on `declared(softlinkHandle<Base>)`,
# so two blocks deriving the SAME base from the SAME pattern would collide).
# `testlib_dropped` (declared in testlib.h, never defined in testlib.c —
# see its own header comment) is unused as a wrapper anywhere else in this
# file, so binding it {.optional.} here can't collide with another dynlib
# block's wrapper proc AND still proves a real end-to-end load/dispatch
# cycle (lrOkPartial, not a compile-only fixture).
dynlib TestLib:
  identBase "TestlibAlt"
  proc testlib_dropped(): cint {.cdecl, optional, header: "tests/testlib.h".}

suite "identBase (RFC 0011 S0a item 1) — override drives every generated name":
  test "loadTestlibAlt/unloadTestlibAlt/testlibaltLoaded exist and work independently of loadTestlib":
    check not testlibaltLoaded()
    check loadTestlibAlt().kind == lrOkPartial
    check testlibaltLoaded()
    check not testlib_droppedAvailable()
    unloadTestlibAlt()
    check not testlibaltLoaded()


# RFC 0011 S0b, work item (i): `trustedWrappers` — a THIRD block over the
# same `TestLib` pattern, disambiguated via `identBase` (RFC 0011 S0a item
# 1), same precedent as the symbol-rename and identBase blocks above. Every
# wrapper generated here is `{.raises: [].}` instead of `{.raises:
# [SoftlinkError].}` — proven below both by the effect system itself
# (`compiles()` against a `{.raises: [].}` caller) and by an ordinary
# successful load/dispatch cycle (item (h): `loadX`/`unloadX`/`LoadResult`/
# the load surface are byte-identical in trusted mode).
dynlib TestLib:
  identBase "TrustedTestlib"
  trustedWrappers: "test fixture — every symbol here is a real, always-present testlib export"
  proc trusted_add(a: cint, b: cint): cint {.cdecl, symbol: "testlib_add", header: "tests/testlib.h".}
  proc trusted_noop() {.cdecl, symbol: "testlib_noop", header: "tests/testlib.h".}
  # RFC 0011 S0b, work item (h): `xxxAvailable*()`/`xxxPtr*()` are
  # generated identically for a trusted wrapper too — neither accessor
  # goes through the nil-check/fatal branch at all (`xxxAvailable` reads
  # the pointer directly; `xxxPtr` returns it, nil or not, with "the load
  # function is the single enforcement point" already the documented
  # contract) — so `{.optional.}` composing with `trustedWrappers` needs
  # no special case, proven here with a symbol that's always actually
  # present at runtime (this fixture isn't testing optional-MISSING
  # behavior, just that the accessors exist and work).
  proc trusted_magic(): cint {.cdecl, optional, symbol: "testlib_magic", header: "tests/testlib.h".}

suite "trustedWrappers (RFC 0011 S0b) — raises:[] wrappers, unaffected load surface":
  test "loadX/unloadX/LoadResult/the load surface are byte-identical in trusted mode (h)":
    check not trustedtestlibLoaded()
    check loadTrustedTestlib().kind in {lrOk, lrOkPartial}
    check trustedtestlibLoaded()
    check trusted_add(10, 32) == 42
    check trusted_magicAvailable()
    check trusted_magicPtr() != nil
    check trusted_magic() == 42
    unloadTrustedTestlib()
    check not trustedtestlibLoaded()
    # Idempotent reload after unload — ordinary loadX/unloadX behavior,
    # unaffected by trustedWrappers.
    check loadTrustedTestlib().kind in {lrOk, lrOkPartial}

  test "generated wrappers are genuinely {.raises: [].} — a raises:[] caller may call them directly (f)":
    ## Must run AFTER a successful load (the suite above already loaded
    ## and left the block loaded) — the point here is the EFFECT SIGNATURE
    ## (the compiler accepts a raises:[] caller invoking a trusted wrapper
    ## with zero cast, the spike's own proven shape), not the nil branch,
    ## which has its own dedicated subprocess pin (story (g),
    ## `tests/fatal_child_wrapper.nim`) precisely because it terminates the
    ## process.
    check trustedtestlibLoaded()
    proc callerMayNotRaise(): cint {.raises: [].} =
      trusted_noop()
      trusted_add(2, 3)
    check callerMayNotRaise() == 5


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
    # Finding #19.7 added a 4th probed symbol (corpuslib_crosscheck,
    # header+prototype cross-check mode); RFC-0003 slice A2 added three more
    # hand-written-gate fixture symbols (corpuslib_gated_until/_since/
    # _crosscheck); slice B2b added an 8th, corpuslib_param_drift (the
    # Gap B parameter-drift end-to-end fixture); slice B2c added a 9th and
    # 10th, corpuslib_const_return/corpuslib_const_param (the #11
    # tolerance-regression-control pair, UNGATED and non-drifting) to
    # tests/corpus/expected.compat.json.
    check m.symbols.len == 10
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

  # Finding R2-A: `checkSince`'s symmetric hole below `since` — an
  # `fkUnknown` fact there is not decisive evidence the symbol was
  # genuinely absent (as `since` claims), yet the pre-fix rule 2 only
  # checked `fkVerified`/`fkMismatch`, letting `fkUnknown` pass vacuously.
  # Hand-built manifests (like the `checkUntil` suite below), not the
  # golden fixture — the golden fixture has no `since`-bearing scenario
  # with an `unknown` fact below the bound.
  test "checkSince: fkUnknown below since — contradicted (Finding R2-A)":
    var sf = SymbolFacts(cname: "corpuslib_maybe")
    sf.header[fkUnknown].add VersionInterval(lo: "", hi: "2.0.0")
    sf.header[fkVerified].add VersionInterval(lo: "2.0.0", hi: "")
    let m = CompatManifest(schema: 1, lib: "testlib", abi: "linux-lp64",
                            corpus: @["1.0.0", "2.0.0", "3.0.0"], symbols: @[sf])
    let sc = checkSince(m, "corpuslib_maybe", "2.0.0")
    check sc.contradicted
    check "1.0.0" in sc.message
    check "no decisive classification" in sc.message

  test "checkSince: fkMismatch below since — still contradicted (existing rule unaffected)":
    var sf = SymbolFacts(cname: "corpuslib_early")
    sf.header[fkMismatch].add VersionInterval(lo: "", hi: "2.0.0")
    sf.header[fkVerified].add VersionInterval(lo: "2.0.0", hi: "")
    let m = CompatManifest(schema: 1, lib: "testlib", abi: "linux-lp64",
                            corpus: @["1.0.0", "2.0.0", "3.0.0"], symbols: @[sf])
    let sc = checkSince(m, "corpuslib_early", "2.0.0")
    check sc.contradicted
    check "1.0.0" in sc.message
    check "no decisive classification" notin sc.message

  test "checkSince: fkAbsent below since — still NOT contradicted (expected, agrees)":
    var sf = SymbolFacts(cname: "corpuslib_late")
    sf.header[fkAbsent].add VersionInterval(lo: "", hi: "2.0.0")
    sf.header[fkVerified].add VersionInterval(lo: "2.0.0", hi: "")
    let m = CompatManifest(schema: 1, lib: "testlib", abi: "linux-lp64",
                            corpus: @["1.0.0", "2.0.0", "3.0.0"], symbols: @[sf])
    check not checkSince(m, "corpuslib_late", "2.0.0").contradicted

  test "checkSince: fkUnknown at/above since (valid region) — NOT contradicted (honest ignorance)":
    var sf = SymbolFacts(cname: "corpuslib_settled")
    sf.header[fkAbsent].add VersionInterval(lo: "", hi: "1.0.0")
    sf.header[fkVerified].add VersionInterval(lo: "1.0.0", hi: "2.0.0")
    sf.header[fkUnknown].add VersionInterval(lo: "2.0.0", hi: "")
    let m = CompatManifest(schema: 1, lib: "testlib", abi: "linux-lp64",
                            corpus: @["0.5.0", "1.0.0", "2.0.0", "3.0.0"], symbols: @[sf])
    check not checkSince(m, "corpuslib_settled", "1.0.0").contradicted

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
    check classifyAbsence(m.symbols, "corpuslib_added", "1.0.0", "", "") == acExpected

  test "classifyAbsence: version in a verified interval -> acAnomalous":
    let m = parseManifest(fixtureText, fixturePath)
    check classifyAbsence(m.symbols, "corpuslib_added", "2.5.0", "", "") == acAnomalous

  test "classifyAbsence: version in a mismatch interval -> acAnomalous (judgment call)":
    # A symbol that never resolved, whose headers at this version are
    # already known to have DRIFTED, is still "the headers declare it, yet
    # it did not resolve" (RFC-0001 §C.2's own wording for mrAnomalous) —
    # not a separate case, and not honest-ignorance either.
    let m = parseManifest(fixtureText, fixturePath)
    check classifyAbsence(m.symbols, "corpuslib_changed", "2.5.0", "", "") == acAnomalous

  test "classifyAbsence: version in an unknown interval, no since -> acNone":
    let m = parseManifest(fixtureText, fixturePath)
    check classifyAbsence(m.symbols, "corpuslib_stable", "3.5.0", "", "") == acNone

  test "classifyAbsence: unknown interval, but since is still ahead -> acExpected":
    let m = parseManifest(fixtureText, fixturePath)
    check classifyAbsence(m.symbols, "corpuslib_stable", "3.5.0", "5.0.0", "") == acExpected

  test "classifyAbsence: unknown interval, since already passed -> acNone":
    let m = parseManifest(fixtureText, fixturePath)
    check classifyAbsence(m.symbols, "corpuslib_stable", "3.5.0", "1.0.0", "") == acNone

  test "classifyAbsence: symbol entirely absent from manifest, no since -> acNone":
    let m = parseManifest(fixtureText, fixturePath)
    check classifyAbsence(m.symbols, "not_a_real_symbol", "1.0.0", "", "") == acNone

  test "classifyAbsence: symbol entirely absent from manifest, since covers it -> acExpected":
    let m = parseManifest(fixtureText, fixturePath)
    check classifyAbsence(m.symbols, "not_a_real_symbol", "1.0.0", "5.0.0", "") == acExpected

  # RFC-0002 §4.3/§6, slice C1: `until` threaded into `classifyAbsence` as a
  # 5th param. The demotion branches BEFORE the anomalous-mismatch rule —
  # `corpuslib_changed` carries mismatch/[2.0.0,3.0.0), which would
  # classify acAnomalous on its own (see the mismatch-interval test above);
  # declaring `until` at-or-below the probed version overrides that.
  test "classifyAbsence: until threaded, probed version AT until -> acExpected (tracer, wins over an anomalous mismatch fact)":
    let m = parseManifest(fixtureText, fixturePath)
    check classifyAbsence(m.symbols, "corpuslib_changed", "2.0.0", "", "2.0.0") == acExpected

  test "classifyAbsence: probed version ABOVE until -> acExpected (also wins over an anomalous mismatch fact)":
    let m = parseManifest(fixtureText, fixturePath)
    check classifyAbsence(m.symbols, "corpuslib_changed", "2.5.0", "", "2.0.0") == acExpected

  test "classifyAbsence: probed version BELOW until, header still says mismatch -> acAnomalous (unchanged)":
    let m = parseManifest(fixtureText, fixturePath)
    check classifyAbsence(m.symbols, "corpuslib_changed", "2.5.0", "", "3.0.0") == acAnomalous

  test "classifyAbsence: probed version BELOW until, no since, no header coverage -> acNone (§4.3 silent on until here; pre-until rule stands)":
    let m = parseManifest(fixtureText, fixturePath)
    check classifyAbsence(m.symbols, "corpuslib_stable", "3.5.0", "", "5.0.0") == acNone

  test "classifyAbsence: until absent (\"\") -> behaves exactly as before C1 (regression)":
    let m = parseManifest(fixtureText, fixturePath)
    check classifyAbsence(m.symbols, "corpuslib_changed", "2.5.0", "", "") == acAnomalous
    check classifyAbsence(m.symbols, "corpuslib_added", "1.0.0", "", "") == acExpected

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

  # Finding #19.8 (code-review coverage gap): this used to assert only
  # `.len > 0` — a tautology any non-empty fallback text satisfies, pinning
  # nothing about what that text actually says. Pinned to the exact
  # fallback string `formatInterval` returns (its own `else: "any version"`
  # branch — see src/softlink/manifest.nim).
  test "formatInterval: unbounded both ways -> exact fallback text \"any version\"":
    check formatInterval(VersionInterval(lo: "", hi: "")) == "any version"

# RFC-0002 §4.2/§6, slice B1: `checkUntil` — the `{.until.}` cross-check.
# NOT a mechanical mirror of `checkSince` above: rule (a)'s absence check is
# scoped by whether `since` is present, rule (b) is a revert-detection check
# `checkSince` has no analogue of, and rule (c) requires positive evidence
# `checkSince` doesn't either. Every manifest here is hand-built (`mkManifest`
# below) rather than drawn from the golden fixture — the pinned scenarios
# (corpus gaps, beyond-corpus-max bounds, all-absent symbols) don't exist in
# `tests/corpus/expected.compat.json` and don't need a real harvest to test a
# pure function.
suite "softlink/manifest — checkUntil (RFC-0002 §4.2, slice B1)":
  proc mkManifest(corpus: seq[string], sf: SymbolFacts): CompatManifest =
    # RFC-0003 §2/§7 slice C1: `harvesterVersion` set to an arbitrary
    # non-empty placeholder here (its VALUE is never compared, only
    # presence/absence, per the §2 "sole trigger" rule) so this suite's
    # pre-existing exact-message assertions (e.g. "drafted wording verbatim"
    # below) keep exercising the RULE text alone, unperturbed by the
    # ground-truth breadcrumb — that breadcrumb's own absence-triggered
    # behavior is pinned separately, on a manifest that deliberately leaves
    # this field unset (see the "ground-truth breadcrumb" suite below).
    CompatManifest(schema: 1, lib: "testlib", abi: "linux-lp64",
                    harvesterVersion: "0.10.0",
                    corpus: corpus, symbols: @[sf])

  test "checkUntil: mismatch inside the window — hard error (tracer bullet)":
    var sf = SymbolFacts(cname: "corpuslib_drifted")
    sf.header[fkVerified].add VersionInterval(lo: "", hi: "2.0.0")
    sf.header[fkMismatch].add VersionInterval(lo: "2.0.0", hi: "")
    let m = mkManifest(@["1.0.0", "2.0.0", "3.0.0"], sf)
    let uc = checkUntil(m, "corpuslib_drifted", "1.0.0", "3.0.0")
    check uc.contradicted
    check "2.0.0" in uc.message

  test "checkUntil: until-without-since, early-corpus absence — passes (absence is since's business)":
    # Introduced late (absent through 2.0.0, verified from 2.0.0), until:
    # "3.0.0" declared with NO since. Rule (a)'s absence check must not
    # fire for the pre-introduction absence, since only `since` scopes
    # that — a naive copy-paste of `checkSince`'s two-fact-kind scan
    # would wrongly flag "1.0.0" here (§4.2's own worked example).
    # Header verified only in [2.0.0, 3.0.0) and drifted at-or-above
    # 3.0.0 — an open-ended `fkVerified` reaching to the corpus end would
    # itself trip rule (b)'s revert detection, which is a DIFFERENT
    # scenario than this test targets.
    var sf = SymbolFacts(cname: "corpuslib_added")
    sf.header[fkAbsent].add VersionInterval(lo: "", hi: "2.0.0")
    sf.header[fkVerified].add VersionInterval(lo: "2.0.0", hi: "3.0.0")
    sf.header[fkMismatch].add VersionInterval(lo: "3.0.0", hi: "")
    let m = mkManifest(@["1.0.0", "2.0.0", "3.0.0"], sf)
    check not checkUntil(m, "corpuslib_added", "", "3.0.0").contradicted

  test "checkUntil: re-verified above until — revert detection, drafted wording verbatim":
    # RFC-0002 §4.2's own worked example, reproduced exactly (down to the
    # symbol/version numbers) so the produced message can be asserted
    # equal to the drafted, grep-pinned string.
    var sf = SymbolFacts(cname: "Z3_fpa_get_numeral_sign")
    sf.header[fkVerified].add VersionInterval(lo: "", hi: "4.16.0")
    sf.header[fkMismatch].add VersionInterval(lo: "4.16.0", hi: "4.18.0")
    sf.header[fkVerified].add VersionInterval(lo: "4.18.0", hi: "")
    let m = mkManifest(@["4.10.0", "4.16.0", "4.18.0"], sf)
    let uc = checkUntil(m, "Z3_fpa_get_numeral_sign", "", "4.16.0")
    check uc.contradicted
    check uc.message == "softlink: {.until: \"4.16.0\".} on 'Z3_fpa_get_numeral_sign' " &
      "contradicts the compat manifest: the corpus re-verifies the declared " &
      "signature at 4.18.0, at or above the declared bound — softlink's " &
      "single-interval model cannot express drift-then-revert (RFC-0002 §3); " &
      "drop 'until' for this symbol to fall back to unbounded verification."

  test "checkUntil: fkVerified exactly AT until — half-open window, 'above' triggers revert detection":
    var sf = SymbolFacts(cname: "corpuslib_boundary")
    sf.header[fkVerified].add VersionInterval(lo: "", hi: "")
    let m = mkManifest(@["1.0.0", "2.0.0"], sf)
    let uc = checkUntil(m, "corpuslib_boundary", "", "2.0.0")
    check uc.contradicted
    check "2.0.0" in uc.message

  test "checkUntil: corpus gap at the boundary — passes (cmpVersion tolerance)":
    # until: "4.16.0" declared in a gap the corpus doesn't sample exactly
    # (4.15.0 -> 4.17.0) — the same granularity tolerance checkSince has.
    var sf = SymbolFacts(cname: "corpuslib_gapped")
    sf.header[fkVerified].add VersionInterval(lo: "", hi: "4.16.0")
    sf.header[fkMismatch].add VersionInterval(lo: "4.16.0", hi: "")
    let m = mkManifest(@["4.15.0", "4.17.0"], sf)
    check not checkUntil(m, "corpuslib_gapped", "", "4.16.0").contradicted

  test "checkUntil: until beyond corpus max — passes vacuously":
    var sf = SymbolFacts(cname: "corpuslib_stable")
    sf.header[fkVerified].add VersionInterval(lo: "", hi: "")
    let m = mkManifest(@["1.0.0", "2.0.0"], sf)
    check not checkUntil(m, "corpuslib_stable", "", "9.0.0").contradicted

  test "checkUntil: all-absent symbol with until — fails rule (c), no positive evidence":
    var sf = SymbolFacts(cname: "corpuslib_ghost")
    sf.header[fkAbsent].add VersionInterval(lo: "", hi: "")
    let m = mkManifest(@["1.0.0", "2.0.0"], sf)
    let uc = checkUntil(m, "corpuslib_ghost", "", "9.0.0")
    check uc.contradicted
    check "extend the corpus" in uc.message

  test "checkUntil: fkAbsent inside the window when since IS present — hard error (checkSince's rule extended)":
    var sf = SymbolFacts(cname: "corpuslib_holed")
    sf.header[fkVerified].add VersionInterval(lo: "", hi: "2.0.0")
    sf.header[fkAbsent].add VersionInterval(lo: "2.0.0", hi: "3.0.0")
    sf.header[fkVerified].add VersionInterval(lo: "3.0.0", hi: "")
    let m = mkManifest(@["1.0.0", "2.0.0", "3.0.0", "4.0.0"], sf)
    let uc = checkUntil(m, "corpuslib_holed", "1.0.0", "4.0.0")
    check uc.contradicted
    check "ABSENT" in uc.message
    check "2.0.0" in uc.message

  test "checkUntil: symbol entirely absent from manifest — no check possible":
    var sf = SymbolFacts(cname: "corpuslib_real")
    sf.header[fkVerified].add VersionInterval(lo: "", hi: "")
    let m = mkManifest(@["1.0.0"], sf)
    check not checkUntil(m, "not_a_real_symbol", "", "5.0.0").contradicted

  # Finding R2-A: rule (b)'s at-or-above-`until` scan checked ONLY
  # `fkVerified` — an `fkUnknown` fact there (harvester couldn't classify)
  # passed vacuously, even though it is no more decisive evidence of
  # invalidity than a re-verification is evidence of validity. Left
  # unfixed, an attested probe landing exactly on that corpus version
  # would sail through the runtime attested-path exemption (which trusts
  # this proc having validated the whole declared-invalid window), and a
  # drifted pointer would dispatch silently.
  test "checkUntil: fkUnknown at/above until — contradicted (Finding R2-A)":
    var sf = SymbolFacts(cname: "corpuslib_hazy")
    sf.header[fkVerified].add VersionInterval(lo: "", hi: "2.0.0")
    sf.header[fkUnknown].add VersionInterval(lo: "2.0.0", hi: "")
    let m = mkManifest(@["1.0.0", "2.0.0", "3.0.0"], sf)
    let uc = checkUntil(m, "corpuslib_hazy", "", "2.0.0")
    check uc.contradicted
    check "2.0.0" in uc.message
    check "no decisive classification" in uc.message

  test "checkUntil: fkMismatch at/above until — still NOT contradicted (agrees with the bound)":
    var sf = SymbolFacts(cname: "corpuslib_confirmed_drift")
    sf.header[fkVerified].add VersionInterval(lo: "", hi: "2.0.0")
    sf.header[fkMismatch].add VersionInterval(lo: "2.0.0", hi: "")
    let m = mkManifest(@["1.0.0", "2.0.0", "3.0.0"], sf)
    check not checkUntil(m, "corpuslib_confirmed_drift", "", "2.0.0").contradicted

  test "checkUntil: fkAbsent at/above until — still NOT contradicted (dropped, expected per §4.3)":
    var sf = SymbolFacts(cname: "corpuslib_retired")
    sf.header[fkVerified].add VersionInterval(lo: "", hi: "2.0.0")
    sf.header[fkAbsent].add VersionInterval(lo: "2.0.0", hi: "")
    let m = mkManifest(@["1.0.0", "2.0.0", "3.0.0"], sf)
    check not checkUntil(m, "corpuslib_retired", "", "2.0.0").contradicted

  test "checkUntil: fkUnknown BELOW until (inside the valid window) — NOT contradicted (honest ignorance)":
    var sf = SymbolFacts(cname: "corpuslib_early_unknown")
    sf.header[fkUnknown].add VersionInterval(lo: "", hi: "2.0.0")
    sf.header[fkVerified].add VersionInterval(lo: "2.0.0", hi: "3.0.0")
    sf.header[fkMismatch].add VersionInterval(lo: "3.0.0", hi: "")
    let m = mkManifest(@["1.0.0", "2.0.0", "3.0.0"], sf)
    check not checkUntil(m, "corpuslib_early_unknown", "", "3.0.0").contradicted

# Check 7 bound-covered mismatch fix (nim-z3 report, softlink-mismatch-
# warning-issue.md; CHECK7-WARNING.handoff.md): `mismatchCoveredByUntil` is
# the pure predicate Check 7 (`src/softlink/directives.nim`) partitions
# `mismatchedSymbols` on — true iff the symbol's recorded drift is fully
# explained by a declared `{.until.}` bound (every `fkMismatch` interval
# lies at-or-above `until`), so the compile-time diagnostic can downgrade
# that case from a WARNING to a HINT. Hand-built manifests via a local
# `mkManifest`, same convention as the `checkUntil` suite above
# (`harvesterVersion` stamped so these tests exercise the predicate alone,
# unperturbed by the ground-truth breadcrumb).
suite "softlink/manifest — mismatchCoveredByUntil (Check 7 bound-covered mismatch fix)":
  proc mkManifest(corpus: seq[string], sf: SymbolFacts): CompatManifest =
    CompatManifest(schema: 1, lib: "testlib", abi: "linux-lp64",
                    harvesterVersion: "0.10.0",
                    corpus: corpus, symbols: @[sf])

  test "mismatchCoveredByUntil: mismatch at-or-above until -> true (tracer bullet)":
    var sf = SymbolFacts(cname: "Z3_fpa_get_numeral_sign")
    sf.header[fkVerified].add VersionInterval(lo: "", hi: "4.16.0")
    sf.header[fkMismatch].add VersionInterval(lo: "4.16.0", hi: "")
    let m = mkManifest(@["4.10.0", "4.16.0", "4.18.0"], sf)
    check mismatchCoveredByUntil(m, "Z3_fpa_get_numeral_sign", "4.16.0")

  test "mismatchCoveredByUntil: until empty (unbounded symbol) -> false":
    var sf = SymbolFacts(cname: "testlib_noop")
    sf.header[fkMismatch].add VersionInterval(lo: "", hi: "")
    let m = mkManifest(@["1.0.0", "2.0.0"], sf)
    check not mismatchCoveredByUntil(m, "testlib_noop", "")

  test "mismatchCoveredByUntil: a mismatch interval starting BELOW until -> false (straddle)":
    var sf = SymbolFacts(cname: "corpuslib_straddle")
    sf.header[fkVerified].add VersionInterval(lo: "", hi: "1.0.0")
    sf.header[fkMismatch].add VersionInterval(lo: "1.0.0", hi: "2.0.0")
    sf.header[fkVerified].add VersionInterval(lo: "2.0.0", hi: "3.0.0")
    sf.header[fkMismatch].add VersionInterval(lo: "3.0.0", hi: "")
    let m = mkManifest(@["1.0.0", "2.0.0", "3.0.0"], sf)
    # Both mismatch intervals must be at-or-above "3.0.0" to be covered by
    # `until: "3.0.0"` -- the [1.0.0, 2.0.0) one is below it, so this is a
    # straddling/uncovered mismatch even though the trailing one qualifies.
    check not mismatchCoveredByUntil(m, "corpuslib_straddle", "3.0.0")

  test "mismatchCoveredByUntil: mismatch interval open at -infinity (lo == \"\") -> false":
    var sf = SymbolFacts(cname: "corpuslib_open_lo")
    sf.header[fkMismatch].add VersionInterval(lo: "", hi: "")
    let m = mkManifest(@["1.0.0", "2.0.0"], sf)
    check not mismatchCoveredByUntil(m, "corpuslib_open_lo", "1.0.0")

  test "mismatchCoveredByUntil: symbol not found in manifest -> false":
    var sf = SymbolFacts(cname: "some_other_symbol")
    sf.header[fkMismatch].add VersionInterval(lo: "1.0.0", hi: "")
    let m = mkManifest(@["1.0.0", "2.0.0"], sf)
    check not mismatchCoveredByUntil(m, "not_in_manifest", "1.0.0")

  test "mismatchCoveredByUntil: symbol has no mismatch interval at all -> false":
    var sf = SymbolFacts(cname: "corpuslib_clean")
    sf.header[fkVerified].add VersionInterval(lo: "", hi: "")
    let m = mkManifest(@["1.0.0", "2.0.0"], sf)
    check not mismatchCoveredByUntil(m, "corpuslib_clean", "5.0.0")

# RFC-0003 §2/§7 slice C1: `parseManifest`'s new OPTIONAL `harvest.
# harvesterVersion` field, and the `checkSince`/`checkUntil` ground-truth
# breadcrumb its absence triggers. Pure-function level (no macro, no real
# harvest) — the real-harvest end-to-end proof (a REAL committed-manifest
# attach through `compatManifest`/`applyCompatManifest`, and a REAL harvest
# of the corpus) lives in `tests/tharvest.nim` and the nimble task's
# `tfail_manifest_until_unknown[_stamped].nim` pair.
suite "softlink/manifest — harvesterVersion + ground-truth breadcrumb (RFC-0003 §2, slice C1)":
  test "parseManifest: harvesterVersion present -> parsed verbatim":
    let j = """{"schema": 1, "lib": "x", "harvest": {"abi": "linux-lp64",
      "harvesterVersion": "0.10.0"}, "corpus": [], "symbols": {}}"""
    let m = parseManifest(j, "bogus.json")
    check m.harvesterVersion == "0.10.0"

  test "parseManifest: harvesterVersion absent -> \"\" (forward-compat with " &
       "every pre-C1 manifest)":
    let j = """{"schema": 1, "lib": "x", "harvest": {"abi": "linux-lp64"},
      "corpus": [], "symbols": {}}"""
    let m = parseManifest(j, "bogus.json")
    check m.harvesterVersion == ""

  test "parseManifest: harvesterVersion present but non-string -> ManifestError " &
       "(F2/F7's expectStr guard, extended to this field)":
    let j = """{"schema": 1, "lib": "x", "harvest": {"abi": "linux-lp64",
      "harvesterVersion": 10}, "corpus": [], "symbols": {}}"""
    expect(ManifestError):
      discard parseManifest(j, "bogus.json")

  proc mkStaleManifest(corpus: seq[string], sf: SymbolFacts): CompatManifest =
    ## `harvesterVersion` left at its zero value ("") -- exactly the
    ## "predates this field" shape §2 names. (`unittest.suite` wraps each
    ## suite's body in its own `block:`, so the checkUntil/checkSince
    ## suites' own `mkManifest` helpers above are not in scope here --
    ## this suite defines its own pair, `mkStaleManifest`/`mkFreshManifest`.)
    CompatManifest(schema: 1, lib: "testlib", abi: "linux-lp64",
                    corpus: corpus, symbols: @[sf])

  proc mkFreshManifest(corpus: seq[string], sf: SymbolFacts): CompatManifest =
    ## The "already has the stamp" mirror of `mkStaleManifest` above --
    ## `harvesterVersion`'s VALUE is never compared, only its presence, so
    ## any non-empty placeholder proves the "no breadcrumb when present"
    ## direction.
    CompatManifest(schema: 1, lib: "testlib", abi: "linux-lp64",
                    harvesterVersion: "0.10.0",
                    corpus: corpus, symbols: @[sf])

  test "checkUntil: breadcrumb PREPENDED (not appended) when harvesterVersion " &
       "is absent, on rule (b)'s revert-detection contradiction":
    ## Re-derives the checkUntil suite's own "re-verified above until" drafted-
    ## wording-verbatim scenario, but on a manifest with no `harvesterVersion`
    ## at all. RFC-0003 §2 round 2: the caveat must be read BEFORE rule (b)'s
    ## own imperative ("drop 'until' for this symbol") -- `startsWith` is a
    ## direct, exact proof of "prepended", stronger than a mere substring
    ## `in` check that could pass even if the text were appended instead.
    var sf = SymbolFacts(cname: "Z3_fpa_get_numeral_sign")
    sf.header[fkVerified].add VersionInterval(lo: "", hi: "4.16.0")
    sf.header[fkMismatch].add VersionInterval(lo: "4.16.0", hi: "4.18.0")
    sf.header[fkVerified].add VersionInterval(lo: "4.18.0", hi: "")
    let m = mkStaleManifest(@["4.10.0", "4.16.0", "4.18.0"], sf)
    let uc = checkUntil(m, "Z3_fpa_get_numeral_sign", "", "4.16.0")
    check uc.contradicted
    check uc.message.startsWith(groundTruthBreadcrumb)
    # The rule's own pinned wording (test_softlink.nim's "drafted wording
    # verbatim" test) still appears in full, unmodified, AFTER the breadcrumb.
    check "drop 'until' for this symbol to fall back to unbounded " &
      "verification." in uc.message

  test "checkUntil: NO breadcrumb when harvesterVersion is present -- same " &
       "contradiction, sole trigger is absence of the field":
    var sf = SymbolFacts(cname: "Z3_fpa_get_numeral_sign")
    sf.header[fkVerified].add VersionInterval(lo: "", hi: "4.16.0")
    sf.header[fkMismatch].add VersionInterval(lo: "4.16.0", hi: "4.18.0")
    sf.header[fkVerified].add VersionInterval(lo: "4.18.0", hi: "")
    let m = mkFreshManifest(@["4.10.0", "4.16.0", "4.18.0"], sf)
    let uc = checkUntil(m, "Z3_fpa_get_numeral_sign", "", "4.16.0")
    check uc.contradicted
    check "predates softlink's ground-truth harvest fix" notin uc.message

  test "checkSince: breadcrumb PREPENDED when harvesterVersion is absent, " &
       "on the fkUnknown-below-since contradiction (a DIFFERENT rule than " &
       "checkUntil's above -- proves the trigger is field-absence, not a " &
       "specific rule's text)":
    var sf = SymbolFacts(cname: "corpuslib_maybe")
    sf.header[fkUnknown].add VersionInterval(lo: "", hi: "2.0.0")
    sf.header[fkVerified].add VersionInterval(lo: "2.0.0", hi: "")
    let m = mkStaleManifest(@["1.0.0", "2.0.0", "3.0.0"], sf)
    let sc = checkSince(m, "corpuslib_maybe", "2.0.0")
    check sc.contradicted
    check sc.message.startsWith(groundTruthBreadcrumb)
    check "re-harvest 1.0.0, drop it from the corpus, or adjust the bound." in sc.message

  test "checkSince: NO breadcrumb when harvesterVersion is present -- same " &
       "contradiction":
    var sf = SymbolFacts(cname: "corpuslib_maybe")
    sf.header[fkUnknown].add VersionInterval(lo: "", hi: "2.0.0")
    sf.header[fkVerified].add VersionInterval(lo: "2.0.0", hi: "")
    let m = mkFreshManifest(@["1.0.0", "2.0.0", "3.0.0"], sf)
    let sc = checkSince(m, "corpuslib_maybe", "2.0.0")
    check sc.contradicted
    check "predates softlink's ground-truth harvest fix" notin sc.message

  # RFC-0003 stage-4 review, Finding M3: the breadcrumb wrap
  # (`withGroundTruthBreadcrumb`) is applied at all SIX `checkSince`/
  # `checkUntil` contradiction return sites in manifest.nim, but only two
  # of those six (checkUntil rule (b), checkSince's fkUnknown-below-since
  # rule, both above) had a test pinning the wrap specifically. The other
  # four sites could have their wrap silently dropped and no test would
  # notice. The four tests below close that gap — each re-derives an
  # EXISTING non-breadcrumb test's exact scenario (named in each comment)
  # on a stale (`mkStaleManifest`) manifest instead, and additionally
  # asserts `.startsWith(groundTruthBreadcrumb)`.
  test "checkSince: breadcrumb PREPENDED when harvesterVersion is absent, " &
       "on the mismatch-below-since rule (M3 — re-derives \"checkSince: " &
       "fkMismatch below since\" above)":
    var sf = SymbolFacts(cname: "corpuslib_early")
    sf.header[fkMismatch].add VersionInterval(lo: "", hi: "2.0.0")
    sf.header[fkVerified].add VersionInterval(lo: "2.0.0", hi: "")
    let m = mkStaleManifest(@["1.0.0", "2.0.0", "3.0.0"], sf)
    let sc = checkSince(m, "corpuslib_early", "2.0.0")
    check sc.contradicted
    check sc.message.startsWith(groundTruthBreadcrumb)
    check "earlier than the claimed lower bound" in sc.message

  test "checkUntil: breadcrumb PREPENDED when harvesterVersion is absent, " &
       "on rule (a)'s over-claim (mismatch inside the window) (M3 — " &
       "re-derives the checkUntil suite's \"mismatch inside the window\" " &
       "tracer bullet)":
    var sf = SymbolFacts(cname: "corpuslib_drifted")
    sf.header[fkVerified].add VersionInterval(lo: "", hi: "2.0.0")
    sf.header[fkMismatch].add VersionInterval(lo: "2.0.0", hi: "")
    let m = mkStaleManifest(@["1.0.0", "2.0.0", "3.0.0"], sf)
    let uc = checkUntil(m, "corpuslib_drifted", "1.0.0", "3.0.0")
    check uc.contradicted
    check uc.message.startsWith(groundTruthBreadcrumb)
    check "inside the declared window" in uc.message

  test "checkUntil: breadcrumb PREPENDED when harvesterVersion is absent, " &
       "on rule (b')'s fkUnknown-at-or-above-until contradiction (M3 — " &
       "re-derives \"checkUntil: fkUnknown at/above until\" above, Finding " &
       "R2-A)":
    var sf = SymbolFacts(cname: "corpuslib_hazy")
    sf.header[fkVerified].add VersionInterval(lo: "", hi: "2.0.0")
    sf.header[fkUnknown].add VersionInterval(lo: "2.0.0", hi: "")
    let m = mkStaleManifest(@["1.0.0", "2.0.0", "3.0.0"], sf)
    let uc = checkUntil(m, "corpuslib_hazy", "", "2.0.0")
    check uc.contradicted
    check uc.message.startsWith(groundTruthBreadcrumb)
    check "no decisive classification" in uc.message

  test "checkUntil: breadcrumb PREPENDED when harvesterVersion is absent, " &
       "on rule (c)'s no-positive-evidence contradiction (M3 — re-derives " &
       "\"checkUntil: all-absent symbol with until\" above)":
    var sf = SymbolFacts(cname: "corpuslib_ghost")
    sf.header[fkAbsent].add VersionInterval(lo: "", hi: "")
    let m = mkStaleManifest(@["1.0.0", "2.0.0"], sf)
    let uc = checkUntil(m, "corpuslib_ghost", "", "9.0.0")
    check uc.contradicted
    check uc.message.startsWith(groundTruthBreadcrumb)
    check "extend the corpus" in uc.message

  test "checkUntil: no contradiction -> empty message regardless of " &
       "harvesterVersion (breadcrumb never fires on a non-contradiction)":
    var sf = SymbolFacts(cname: "corpuslib_boring")
    sf.header[fkVerified].add VersionInterval(lo: "", hi: "")
    let m = mkStaleManifest(@["1.0.0", "2.0.0"], sf)
    let uc = checkUntil(m, "corpuslib_boring", "", "9.0.0")
    check not uc.contradicted
    check uc.message.len == 0

# RFC-0002 §4.4/§6, slice C4a: `compareToBound` — the declared-bound
# runtime comparison rule's pure comparator (numeric-prefix-only, tie/
# unparseable -> not comparable). This is the tracer bullet AND the pinned
# cases the slice brief calls out: decisive prefix above/below, a genuine
# boundary tie with an alpha run, an unparseable probe, and the flagship
# distro-suffix case ("4.16.3-ubuntu3" vs until "4.16.0") that must refuse.
suite "softlink/versions — compareToBound (RFC-0002 §4.4, slice C4a)":
  test "decisive: probe's numeric prefix sorts strictly ABOVE the bound (tracer bullet)":
    check compareToBound("4.17.0", "4.16.0") == some(1)

  test "decisive: probe's numeric prefix sorts strictly BELOW the bound":
    check compareToBound("4.15.0", "4.16.0") == some(-1)

  test "boundary tie with an alpha run: \"4.16.0-rc1\" vs until \"4.16.0\" -> not comparable":
    # Genuinely ambiguous under the codebase's no-pre-release-semantics
    # stance (RFC-0001 §5 C.0): is a release candidate "before" or "at"
    # its own release? Declines to decide rather than risk a false refusal.
    check compareToBound("4.16.0-rc1", "4.16.0").isNone

  test "unparseable probe -> not comparable":
    check compareToBound("unknown", "4.16.0").isNone
    check compareToBound("", "4.16.0").isNone

  test "flagship distro-suffix case: \"4.16.3-ubuntu3\" vs until \"4.16.0\" -> decisively ABOVE":
    # The numeric prefix (4.16.3) already decides above the bound (4.16.0)
    # before the trailing alpha run is ever consulted — this is the
    # must-refuse input C4b's declared-bound refusal depends on: a distro
    # patch release the corpus never harvested must still be recognized as
    # past `until` and refused, not silently treated as "not comparable".
    check compareToBound("4.16.3-ubuntu3", "4.16.0") == some(1)

  test "an alpha tail that does not create a tie is irrelevant to the decision":
    # Both sides can carry alpha tails; only an exact numeric-prefix TIE
    # triggers the ambiguity check.
    check compareToBound("4.17.0-rc1", "4.16.0-beta") == some(1)

  test "exact tie, neither side has an alpha tail -> comparable, zero":
    check compareToBound("4.16.0", "4.16.0") == some(0)

# Code-review finding CR1-3: `numericPrefixRuns`/`parseVersion` used to
# accumulate a digit run with an uncapped `val = val*10 + digit`, which
# raises `OverflowDefect` (uncaught anywhere in the generated loader —
# the probe's own try/except catches only `CatchableError`, and
# `compareToBound` runs outside it entirely) on a 19+-digit run, in both
# default AND `-d:release` builds — a runtime-probed, attacker/corruption-
# controlled version string could crash the whole process. A 19-digit
# run is the smallest that can overflow `int64` mid-accumulation; 18
# digits is the widest safe width, so that is exactly where the cap
# sits. Fixed by capping accumulation at 18 digits and treating an
# oversized run as making the WHOLE string unparseable (the existing
# `none`/"not comparable" decline path) rather than saturating to some
# invented value.
suite "softlink/versions — CR1-3: oversized digit run never raises":
  test "compareToBound: a 19+-digit run on the PROBE side declines instead of raising":
    check compareToBound("999999999999999999999999.0.0", "4.16.0").isNone

  test "compareToBound: a 19+-digit run on the BOUND side declines instead of raising":
    check compareToBound("4.16.0", "999999999999999999999999.0.0").isNone

  test "parseVersion: a 19+-digit run makes the whole string unparseable":
    check parseVersion("999999999999999999999999.0.0").isNone
    # A leading, otherwise-valid run before the oversized one is also
    # discarded, not partially kept -- the design choice is "the whole
    # string is unparseable", never a silently-truncated partial parse.
    check parseVersion("4.16.99999999999999999999.3").isNone

  test "parseVersion: exactly 18 digits is the safe boundary and still parses":
    # `int(...)` conversions, not bare literals: an unsuffixed integer
    # literal too large for int32 infers as `int64` regardless of the
    # native `int` width, which would otherwise mismatch `seq[int]` here.
    let parsed = parseVersion("999999999999999999.0.0")
    check parsed.isSome
    check parsed.get == @[int(999999999999999999), int(0), int(0)]

  test "cmpVersion: an oversized run never raises, and compares as the unparseable/empty sequence":
    # Matches cmpVersion's own documented fallback for any unparseable
    # string (module doc comment): sorts below any version with a
    # positive leading component.
    check cmpVersion("999999999999999999999999.0.0", "4.16.0") < 0
    check cmpVersion("4.16.0", "999999999999999999999999.0.0") > 0

# CR1-3 follow-up: the alpha-run base-26 accumulation in `parseVersion` has
# the exact same unbounded `val*26 + ...` shape the digit-run suite above
# guards -- a long-enough pure-letter run overflows int64 the same way a
# long-enough pure-digit run does. Same treatment, same design: decline the
# whole string rather than raise or silently saturate/wrap.
suite "softlink/versions — CR1-3 follow-up: oversized alpha run never raises":
  test "parseVersion: a 14+-letter run makes the whole string unparseable":
    check parseVersion("a".repeat(20)).isNone
    # A leading, otherwise-valid run before the oversized one is also
    # discarded, not partially kept -- same "whole string is unparseable"
    # design choice as the digit-run case.
    check parseVersion("4.16." & "z".repeat(20)).isNone

  test "parseVersion: exactly 13 letters is the safe boundary and still parses":
    let parsed = parseVersion("z".repeat(13))
    check parsed.isSome
    check parsed.get == @[int(2_580_398_988_131_886_038)]

  test "cmpVersion: an oversized alpha run never raises, and compares as the unparseable/empty sequence":
    # Matches cmpVersion's own documented fallback for any unparseable
    # string: sorts below any version with a positive leading component.
    check cmpVersion("a".repeat(20), "4.16.0") < 0
    check cmpVersion("4.16.0", "a".repeat(20)) > 0

  test "VersionInterval.contains: an oversized alpha run never raises":
    let iv = VersionInterval(lo: "1.0.0", hi: "")
    check contains(iv, "1.0.0" & "a".repeat(20)) == false

  test "compareToBound: a 20-letter run on the PROBE side never raises and declines":
    check compareToBound("a".repeat(20), "4.16.0").isNone

  test "compareToBound: a 20-letter run on the BOUND side never raises and declines":
    check compareToBound("4.16.0", "a".repeat(20)).isNone

  test "evaluateBoundRefusal: a 20-letter run on the probed side never raises, declines instead of refusing":
    let r = evaluateBoundRefusal("1.0.0" & "a".repeat(20), "1.0.0", "")
    check r.refuse == false
    check r.notComparable == true

  test "evaluateBoundRefusal: a 20-letter run on the since/until side never raises, declines instead of refusing":
    let r = evaluateBoundRefusal("2.0.0", "a".repeat(20), "")
    check r.refuse == false
    check r.notComparable == true

# RFC-0002 §4.4, code-review finding CR1-4: `evaluateBoundRefusal` — the
# single pure decision function extracted from the `dynlib` macro's
# `buildBoundCheck` (previously hand-assembled NimNode trees with no
# direct unit test). Every case below is a golden pinned directly against
# `buildBoundCheck`'s pre-extraction semantics: `until` is the exclusive
# upper bound (at-until refuses), `since` is the inclusive lower bound
# (at-since accepts), "" means an absent bound on either side, and a
# `none` result from `compareToBound` on EITHER bound independently sets
# `notComparable` without necessarily setting `refuse` (or vice versa).
suite "softlink/versions — evaluateBoundRefusal (RFC-0002 §4.4, code-review CR1-4)":
  test "in range for both bounds: no refusal, comparable":
    let r = evaluateBoundRefusal("4.16.5", "4.16.0", "4.17.0")
    check not r.refuse
    check not r.notComparable

  test "at-until: refuses (until is an EXCLUSIVE upper bound, half-open)":
    let r = evaluateBoundRefusal("4.17.0", "4.16.0", "4.17.0")
    check r.refuse
    check not r.notComparable

  test "at-since: accepts (since is an INCLUSIVE lower bound)":
    let r = evaluateBoundRefusal("4.16.0", "4.16.0", "4.17.0")
    check not r.refuse
    check not r.notComparable

  test "below-since: refuses":
    let r = evaluateBoundRefusal("4.15.9", "4.16.0", "4.17.0")
    check r.refuse
    check not r.notComparable

  test "decisive despite an alpha tail: distro-suffixed probe past until still refuses":
    let r = evaluateBoundRefusal("4.16.3-ubuntu3", "", "4.16.0")
    check r.refuse
    check not r.notComparable

  test "boundary tie with an alpha run: not comparable, does not refuse":
    let r = evaluateBoundRefusal("4.16.0-rc1", "", "4.16.0")
    check not r.refuse
    check r.notComparable

  test "unparseable probe against a real bound: not comparable on both bounds, never refuses":
    let r = evaluateBoundRefusal("unknown", "4.16.0", "4.17.0")
    check not r.refuse
    check r.notComparable

  test "both bounds absent (\"\"): never refuses regardless of probe":
    check not evaluateBoundRefusal("4.16.0", "", "").refuse
    check not evaluateBoundRefusal("4.16.0", "", "").notComparable
    check not evaluateBoundRefusal("garbage", "", "").refuse
    check not evaluateBoundRefusal("garbage", "", "").notComparable

  test "CR1-3 interaction: an overflow-length probe is not comparable and never crashes":
    let r = evaluateBoundRefusal("999999999999999999999999.0.0", "4.16.0", "4.17.0")
    check not r.refuse
    check r.notComparable

# RFC-0002 §5/§6, slice E2: `softlink/gates` — the pure gate synthesizer.
# Golden-tested outside the macro, per §5's own instruction; every case
# below is pinned directly against §5's worked examples/counterexample.
suite "softlink/gates — gate synthesis (RFC-0002 §5, slice E2)":
  test "until \"4.16.0\" against 3 macros — trailing zero strips to a 2-component compare":
    # The RFC's own worked example (§4/§5), reproduced verbatim.
    let r = synthesizeBoundPredicate(
      @["Z3_MAJOR_VERSION", "Z3_MINOR_VERSION", "Z3_BUILD_NUMBER"], "4.16.0", bkUntil)
    check r.ok
    check r.predicate ==
      "(Z3_MAJOR_VERSION < 4) || (Z3_MAJOR_VERSION == 4 && Z3_MINOR_VERSION < 16)"
    check r.usedMacros == @["Z3_MAJOR_VERSION", "Z3_MINOR_VERSION"]

  test "since \"4.0.5\" against 3 macros — the non-trailing-zero counterexample (§5)":
    # The pinned counterexample: the middle "0" is NOT trailing (patch is
    # "5", nonzero) so nothing strips — all 3 components stay against all 3
    # macros. A naive "elide any zero" reading would misalign the remaining
    # components against the wrong macros; this asserts the full,
    # correctly-positioned 3-component expansion instead.
    let r = synthesizeBoundPredicate(
      @["MAJOR", "MINOR", "PATCH"], "4.0.5", bkSince)
    check r.ok
    check r.predicate ==
      "(MAJOR > 4) || (MAJOR == 4 && MINOR > 0) || (MAJOR == 4 && MINOR == 0 && PATCH >= 5)"
    check r.usedMacros == @["MAJOR", "MINOR", "PATCH"]
    # Sanity-check the predicate's actual truth table against the claim
    # "since: 4.0.5 means valid from 4.0.5 onward" — 4.5.3 is genuinely in
    # range (naive elision would wrongly exclude it, per §5); 4.0.6 is in
    # range (patch above the bound); 4.0.4 is NOT (patch below the bound).
    proc evalGe(major, minor, patch: int): bool =
      (major > 4) or (major == 4 and minor > 0) or
        (major == 4 and minor == 0 and patch >= 5)
    check evalGe(4, 5, 3)   # in range
    check evalGe(4, 0, 6)   # in range
    check not evalGe(4, 0, 4)  # out of range

  test "until \"4.16\" against 3 macros — short bound zero-pads then strips identically to \"4.16.0\"":
    let r = synthesizeBoundPredicate(
      @["Z3_MAJOR_VERSION", "Z3_MINOR_VERSION", "Z3_BUILD_NUMBER"], "4.16", bkUntil)
    check r.ok
    check r.predicate ==
      "(Z3_MAJOR_VERSION < 4) || (Z3_MAJOR_VERSION == 4 && Z3_MINOR_VERSION < 16)"
    check r.usedMacros == @["Z3_MAJOR_VERSION", "Z3_MINOR_VERSION"]

  test "both bounds present — AND-combined (since \">=\" predicate, until \"<\" predicate)":
    let r = synthesizeGate(@["MAJOR", "MINOR", "BUILD"], "4.0.0", "4.16.0")
    check r.ok
    check r.predicate == "(MAJOR >= 4) && ((MAJOR < 4) || (MAJOR == 4 && MINOR < 16))"
    check r.usedMacros == @["MAJOR", "MINOR"]

  test "until-only — just the < predicate, no AND":
    let r = synthesizeGate(@["MAJOR", "MINOR"], "", "4.16")
    check r.ok
    check r.predicate == "(MAJOR < 4) || (MAJOR == 4 && MINOR < 16)"

  test "bound with an alpha run is a synthesis error (no C macro to compare a suffix against)":
    let r = synthesizeBoundPredicate(@["MAJOR", "MINOR"], "4.16.0-rc1", bkUntil)
    check not r.ok
    check r.error.kind == geAlphaRun
    check r.error.bound == bkUntil
    check r.error.value == "4.16.0-rc1"

  test "bound with more components than the macro list is a synthesis error":
    let r = synthesizeBoundPredicate(@["MAJOR", "MINOR"], "4.16.3", bkUntil)
    check not r.ok
    check r.error.kind == geExcessComponents
    check r.error.componentCount == 3
    check r.error.macroCount == 2

  test "CR1-2: \"2.0.0\" against 1 macro synthesizes identically to \"2\" (raw-count excess bug)":
    # Regression for CR1-2: the excess-components check used to run on the
    # RAW parsed component count (3, for "2.0.0") BEFORE the trailing-zero
    # strip, so this canonicalized-equivalent-to-"2" bound wrongly errored
    # as 3-components-vs-1-macro even though "2.0.0" == "2" per this
    # module's own documented equivalence invariant.
    let rLong = synthesizeBoundPredicate(@["TESTLIB_VERSION"], "2.0.0", bkUntil)
    let rShort = synthesizeBoundPredicate(@["TESTLIB_VERSION"], "2", bkUntil)
    check rLong.ok
    check rShort.ok
    check rLong.predicate == rShort.predicate
    check rLong.usedMacros == rShort.usedMacros
    check rLong.predicate == "(TESTLIB_VERSION < 2)"

  test "CR1-2: \"4.16.0\" against 2 macros synthesizes identically to \"4.16\"":
    let rLong = synthesizeBoundPredicate(@["MAJOR", "MINOR"], "4.16.0", bkUntil)
    let rShort = synthesizeBoundPredicate(@["MAJOR", "MINOR"], "4.16", bkUntil)
    check rLong.ok
    check rShort.ok
    check rLong.predicate == rShort.predicate
    check rLong.usedMacros == rShort.usedMacros

  test "CR1-2: genuine excess (\"4.16.3\" against 2 macros) is still rejected":
    let r = synthesizeBoundPredicate(@["MAJOR", "MINOR"], "4.16.3", bkUntil)
    check not r.ok
    check r.error.kind == geExcessComponents

  test "CR1-8: single-macro golden — bound \"4\" against 1 macro is an exact, unparenthesized-junction compare":
    let r = synthesizeBoundPredicate(@["MAJOR"], "4", bkUntil)
    check r.ok
    check r.predicate == "(MAJOR < 4)"
    check "||" notin r.predicate
    check "&&" notin r.predicate
    check r.usedMacros == @["MAJOR"]

  test "degenerate all-zero bound: until -> always-false, since -> always-true, no macro referenced":
    let ru = synthesizeBoundPredicate(@["MAJOR", "MINOR"], "0.0", bkUntil)
    check ru.ok
    check ru.predicate == "0"
    check ru.usedMacros.len == 0
    let rs = synthesizeBoundPredicate(@["MAJOR", "MINOR"], "0.0", bkSince)
    check rs.ok
    check rs.predicate == "1"
    check rs.usedMacros.len == 0

# Code-review findings (2026-07 round 1, RFC-0001 §B.3/§B.5 hardening;
# IDs F1/F2/F7/F8/F16 refer to that review's ledger). Every test below
# drives `parseManifest` directly against a
# hand-built JSON string (never the golden fixture's `%*` construction,
# which can't even EXPRESS a duplicate key), asserting the parse fails
# loudly rather than silently corrupting/discarding data.
suite "softlink/manifest — fail-loud hardening (code-review findings F1/F2/F7/F8/F16)":
  test "parseManifest: cmpVersion-aliasing corpus versions raise ManifestError naming both (F1)":
    # "1.09" and "1.9" both parse to the run-sequence @[1, 9] (leading zeros
    # are not preserved by parseVersion's digit-run accumulation), so
    # cmpVersion says they are EQUAL even though they are different corpus
    # directory/version strings — compressFacts' run-boundary logic assumes
    # a strictly-increasing sequence and would silently misattribute one
    # string's facts to the other.
    let text = """{"schema":1,"lib":"x","harvest":{"abi":"linux-lp64"},
      "corpus":[{"version":"1.09"},{"version":"1.9"},{"version":"2.0"}],
      "symbols":{}}"""
    var raised = false
    var msg = ""
    try:
      discard parseManifest(text, "bogus.json")
    except ManifestError as e:
      raised = true
      msg = e.msg
    check raised
    check "1.09" in msg
    check "1.9" in msg

  test "parseManifest: non-aliasing corpus versions are unaffected (F1 control)":
    let text = """{"schema":1,"lib":"x","harvest":{"abi":"linux-lp64"},
      "corpus":[{"version":"1.9"},{"version":"1.10"},{"version":"2.0"}],
      "symbols":{}}"""
    let m = parseManifest(text, "bogus.json")
    check m.corpus == @["1.9", "1.10", "2.0"]

  test "parseManifest: wrong-kind interval 'lo' (a float) raises ManifestError naming the key (F2)":
    let text = """{"schema":1,"lib":"x","harvest":{"abi":"linux-lp64"},
      "corpus":[],"symbols":{"foo":{"header":{"verified":[{"lo":4.16}]}}}}"""
    var raised = false
    var msg = ""
    try:
      discard parseManifest(text, "bogus.json")
    except ManifestError as e:
      raised = true
      msg = e.msg
    check raised
    check "lo" in msg

  test "parseManifest: wrong-kind interval 'hi' (a bool) raises ManifestError naming the key (F2)":
    let text = """{"schema":1,"lib":"x","harvest":{"abi":"linux-lp64"},
      "corpus":[],"symbols":{"foo":{"header":{"verified":[{"hi":true}]}}}}"""
    var raised = false
    var msg = ""
    try:
      discard parseManifest(text, "bogus.json")
    except ManifestError as e:
      raised = true
      msg = e.msg
    check raised
    check "hi" in msg

  test "parseManifest: string schema (\"1\" instead of 1) raises ManifestError (F7)":
    let text = """{"schema":"1","lib":"x","harvest":{"abi":"linux-lp64"},
      "corpus":[],"symbols":{}}"""
    expect(ManifestError):
      discard parseManifest(text, "bogus.json")

  test "parseManifest: float schema (1.5) raises ManifestError (F7)":
    let text = """{"schema":1.5,"lib":"x","harvest":{"abi":"linux-lp64"},
      "corpus":[],"symbols":{}}"""
    expect(ManifestError):
      discard parseManifest(text, "bogus.json")

  test "parseManifest: non-string lib raises ManifestError (F7)":
    let text = """{"schema":1,"lib":42,"harvest":{"abi":"linux-lp64"},
      "corpus":[],"symbols":{}}"""
    expect(ManifestError):
      discard parseManifest(text, "bogus.json")

  test "parseManifest: non-string harvest.abi raises ManifestError (F7)":
    let text = """{"schema":1,"lib":"x","harvest":{"abi":123},
      "corpus":[],"symbols":{}}"""
    expect(ManifestError):
      discard parseManifest(text, "bogus.json")

  test "parseManifest: non-string corpus[].version raises ManifestError (F7)":
    let text = """{"schema":1,"lib":"x","harvest":{"abi":"linux-lp64"},
      "corpus":[{"version":1.0}],"symbols":{}}"""
    expect(ManifestError):
      discard parseManifest(text, "bogus.json")

  test "parseManifest: duplicate top-level key raises ManifestError naming it (F8)":
    let text = """{"schema":1,"schema":2,"lib":"x","harvest":{"abi":"linux-lp64"},
      "corpus":[],"symbols":{}}"""
    var raised = false
    var msg = ""
    try:
      discard parseManifest(text, "bogus.json")
    except ManifestError as e:
      raised = true
      msg = e.msg
    check raised
    check "schema" in msg

  test "parseManifest: duplicate symbol key raises ManifestError naming it (F8)":
    let text = """{"schema":1,"lib":"x","harvest":{"abi":"linux-lp64"},
      "corpus":[],"symbols":{"foo":{"header":{}},"foo":{"header":{}}}}"""
    var raised = false
    var msg = ""
    try:
      discard parseManifest(text, "bogus.json")
    except ManifestError as e:
      raised = true
      msg = e.msg
    check raised
    check "foo" in msg

  test "parseManifest: duplicate fact key inside one symbol's header raises ManifestError naming it (F8)":
    let text = """{"schema":1,"lib":"x","harvest":{"abi":"linux-lp64"},
      "corpus":[],"symbols":{"foo":{"header":{"verified":[],"verified":[{"lo":"1.0.0"}]}}}}"""
    var raised = false
    var msg = ""
    try:
      discard parseManifest(text, "bogus.json")
    except ManifestError as e:
      raised = true
      msg = e.msg
    check raised
    check "verified" in msg

  test "parseManifest: hostile large-breadth manifest raises ManifestError before validation (F16)":
    # `validateDisjointExhaustive` is O(symbols * corpus * FactKind * intervals)
    # with no bound of its own; a hostile (or merely huge) manifest read via
    # `staticRead` at macro-expansion time could hang the compiler. This
    # builds a manifest whose symbols.len * corpus.len crosses 1_000_000
    # using only ~2000 total JSON object entries (1000 corpus x 1001
    # symbols) — a few actual bytes, not a multi-megabyte fixture — proving
    # the cap check itself is cheap (it must reject BEFORE doing anything
    # resembling the O(product) work it exists to prevent).
    var corpusParts: seq[string] = @[]
    for i in 0 ..< 1000:
      corpusParts.add("{\"version\":\"1." & $i & ".0\"}")
    var symbolParts: seq[string] = @[]
    for i in 0 ..< 1001:
      symbolParts.add("\"sym" & $i & "\":{\"header\":{}}")
    let text = "{\"schema\":1,\"lib\":\"x\",\"harvest\":{\"abi\":\"linux-lp64\"}," &
      "\"corpus\":[" & corpusParts.join(",") & "]," &
      "\"symbols\":{" & symbolParts.join(",") & "}}"
    expect(ManifestError):
      discard parseManifest(text, "bogus.json")
