#ifndef TESTLIB_GATES_VERSION_H
#define TESTLIB_GATES_VERSION_H

/* RFC-0002 `versionMacros(header = ...)` extension: a fixture "version
 * header" standing in for upstream's z3_version.h — defines TESTLIB_VERSION
 * independently of tests/testlib_bare.h (which deliberately does not
 * define or include it). #ifndef-guarded, matching tests/testlib.h's own
 * convention, so --passC:-DTESTLIB_VERSION=2 can still override it from
 * the command line for the dual-compile drift proof. */
#ifndef TESTLIB_VERSION
#define TESTLIB_VERSION 1
#endif

#endif
