#define TESTLIB_BUILDING
#include "testlib.h"

TESTLIB_API int testlib_add(int a, int b) { return a + b; }
TESTLIB_API void testlib_noop(void) {}
/* testlib_future: NOT implemented — simulates symbol added in future version */
