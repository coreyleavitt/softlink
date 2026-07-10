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

/* Symbol for lrLibNotFound testing — declared in header, bound to a non-existent library */
TESTLIB_API int testlib_notreal(void);

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

#endif
