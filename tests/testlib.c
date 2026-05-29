#define TESTLIB_BUILDING
#include "testlib.h"

TESTLIB_API int testlib_add(int a, int b) { return a + b; }
TESTLIB_API void testlib_noop(void) {}
/* testlib_future: NOT implemented — simulates symbol added in future version */

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
