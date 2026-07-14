#define TESTLIB_BUILDING
#include "testlib.h"

TESTLIB_API int testlib_add(int a, int b) { return a + b; }
TESTLIB_API void testlib_noop(void) {}
TESTLIB_API int testlib_magic(void) { return 42; }
TESTLIB_API int testlib_versioned(void) { return 7; }
/* testlib_future: NOT implemented — simulates symbol added in future version */

/* testlib_unheralded: in the .so but deliberately NOT declared in testlib.h —
 * simulates a symbol newer than the installed headers. Bindings must use
 * {.noverify.} (header verification would be an implicit-declaration error). */
TESTLIB_API int testlib_unheralded(void) { return 99; }

TESTLIB_API const char *testlib_const_string(void) {
  return "hello from testlib";
}
TESTLIB_API const char *testlib_const_lookup(int key) {
  static const char *strings[] = { "zero", "one", "two", "three" };
  if (key < 0 || key > 3) return "out-of-range";
  return strings[key];
}
TESTLIB_API char *testlib_mutable_string(void) {
  static char buf[] = "mutable";
  return buf;
}
