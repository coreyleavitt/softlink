#ifndef TESTLIB_H
#define TESTLIB_H

#ifdef _WIN32
  #ifdef TESTLIB_BUILDING
    #define TESTLIB_API __declspec(dllexport)
  #else
    #define TESTLIB_API __declspec(dllimport)
  #endif
#else
  #define TESTLIB_API
#endif

/* Version macro for {.verifyWhen.} tests — real bindings gate on macros
 * like MBEDTLS_VERSION_NUMBER; TESTLIB_VERSION plays that role here.
 * RFC-0002 §6 slice C3a: `#ifndef`-guarded so a second compile invocation
 * can override it (`--passC:-DTESTLIB_VERSION=2`) to present a genuinely
 * different header to the same verify TU — a plain `#define` would make a
 * command-line `-D` a "redefined macro" warning/error instead of a clean
 * override. */
#ifndef TESTLIB_VERSION
#define TESTLIB_VERSION 1
#endif

/* RFC-0001 §3 A.1 slice A2: real C headers meant for C++ inclusion guard
 * their declarations in `extern "C"` — softlink's own verify TU already
 * #includes this header under the C++ backend (for the header-only
 * verification path, which predates {.prototype.}). Without this guard,
 * declarations below get default C++ linkage; the {.prototype.} extern
 * declaration (RFC-0001 §3 A.1) is deliberately `extern "C"`-wrapped
 * (needed so a *drifted* prototype is a hard redeclaration error instead
 * of a silently-resolved C++ overload) — a redeclaration of the SAME
 * symbol with differing linkage is itself a C++ compile error, independent
 * of whether the C signatures agree. Guarding here (the idiomatic,
 * portable fix real headers use) makes both declarations share "C"
 * linkage, so agreement is recognized as a compatible redeclaration
 * (testlib_add, bound with both {.header.} and {.prototype.} for
 * cross-checking) rather than a false-positive linkage conflict.
 */
#ifdef __cplusplus
extern "C" {
#endif

/* Required symbols — always in .so/.dll */
TESTLIB_API int testlib_add(int a, int b);
TESTLIB_API void testlib_noop(void);

/* Symbol bound via a bare logical name ("magic") to exercise
 * deriveLibPattern end-to-end. Compiled to libmagic.so/.dylib/.dll. */
TESTLIB_API int testlib_magic(void);

/* Symbol for the runtime-only versioned-soname test: compiled to
 * libvern.so.3 with NO bare libvern.so, so magic must fall back to a
 * versioned candidate. Linux-only (ELF soname convention). */
TESTLIB_API int testlib_versioned(void);

/* Optional symbol — in header but NOT in .so/.dll (simulates newer API version) */
TESTLIB_API int testlib_future(void);

/* RFC-0002 §4.3/§6, slice C1: an {.optional, since, until.} symbol that is
 * ALSO genuinely never implemented in the .so — the "absent from the .so
 * at-or-above a declared until" case C1's classification change targets.
 * Declared here (never defined in testlib.c) purely so header verification
 * has something to check against, exactly like testlib_future above. */
TESTLIB_API int testlib_dropped(void);

/* Symbol for {.verifyWhen.} true-condition tests: declared here (so the
 * gated _Static_assert has something to verify) and present in the .so. */
TESTLIB_API int testlib_gated(void);

/* RFC-0002 §6, slice C3a: testlib_drifted — a GENUINELY drifted signature
 * across TESTLIB_VERSION (contrast testlib_gated_v2 in testlib.c, whose
 * higher-version declaration is simply ABSENT). Mirrors the RFC's own
 * motivating case exactly: Z3_fpa_get_numeral_sign's `int *sgn` -> `bool
 * *sgn` out-param drift is a POINTER type change, not a scalar one — an
 * earlier draft of this fixture used a scalar `int`/`double` param drift
 * and found (empirically) that softlink's call-based verification cannot
 * catch it: C silently applies the usual arithmetic conversion to a
 * scalar argument at a call site (no error, no warning even without `-w`
 * suppressing it), so a wrong SCALAR param type is invisible to the
 * assert chain (see `genVerifyBlock`'s own doc comment on "const-tolerant
 * param checking"). An incompatible POINTER argument, by contrast, is a
 * hard `-Wincompatible-pointer-types` error on this toolchain (verified
 * by hand) even under `-w` — so the drift here is `int *` -> `double *`,
 * softlink has no {.importc.} rename axis, so two Nim bindings of one
 * drifted C symbol must be distinguishable Nim overloads by parameter
 * type (return-type-only overloading is ambiguous in Nim). Declared here
 * only (never defined in testlib.c) — this fixture is compile-only
 * verification, like testlib_dropped/testlib_future above; nothing ever
 * dlsym's it. */
#if TESTLIB_VERSION >= 2
TESTLIB_API int testlib_drifted(double *sgn);
#else
TESTLIB_API int testlib_drifted(int *sgn);
#endif

/* Symbol for lrLibNotFound testing — declared in header, bound to a non-existent library */
TESTLIB_API int testlib_notreal(void);

/* RFC-0001 §9/§C.2, slice C2: a second lrLibNotFound fixture, on its own
 * dynlib block that ALSO declares a versionProbe — for the "fooCompat()
 * after a failed load" test (the probe never gets a chance to run, so the
 * report must be the zero state). Declared here purely so header
 * verification has something to check against; like testlib_notreal
 * above, this symbol is never actually resolved at runtime (the library
 * never loads). */
TESTLIB_API int testlib_notreal_c2(void);

/* Const-qualified pointer returns — regression tests for #11.
 * On the GCC pathway, `const char *` returns must be considered
 * compatible with the Nim binding's `cstring` type (which emits as
 * `char *`). The fix dereferences both sides so __builtin_types_compatible_p
 * sees `const char` vs `char` — qualifiers are ignored at the top
 * level by GCC's builtin, giving a compatible match.
 */
TESTLIB_API const char *testlib_const_string(void);
TESTLIB_API const char *testlib_const_lookup(int key);
TESTLIB_API char *testlib_mutable_string(void);  /* non-const baseline */

#ifdef __cplusplus
}
#endif

#endif
