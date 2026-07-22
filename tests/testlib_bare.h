#ifndef TESTLIB_BARE_H
#define TESTLIB_BARE_H

/* RFC-0002 `versionMacros(header = ...)` extension (the Z3 case): a proc
 * header that, unlike tests/testlib.h, does NOT define or #include
 * TESTLIB_VERSION itself — mirrors z3.h, which does not include
 * z3_version.h. Declares the same genuinely-drifted-across-TESTLIB_VERSION
 * signature tests/testlib.h's testlib_drifted uses (see its own doc
 * comment there for why the drift is a POINTER type, not a scalar one, and
 * why that matters for softlink's call-based verification), under a
 * different C name (testlib_bare_drifted) so this header can be
 * #included ALONGSIDE tests/testlib.h in the same verify TU without a
 * redeclaration clash. Declared here only (never defined in testlib.c) —
 * like testlib_drifted, this fixture is compile-only verification; nothing
 * ever dlsym's it. */

#ifdef __cplusplus
extern "C" {
#endif

#if TESTLIB_VERSION >= 2
int testlib_bare_drifted(double *sgn);
#else
int testlib_bare_drifted(int *sgn);
#endif

#ifdef __cplusplus
}
#endif

#endif
