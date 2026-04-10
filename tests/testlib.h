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

/* Optional symbol — in header but NOT in .so/.dll (simulates newer API version) */
TESTLIB_API int testlib_future(void);

/* Symbol for lrLibNotFound testing — declared in header, bound to a non-existent library */
TESTLIB_API int testlib_notreal(void);

#endif
