#ifndef TESTLIB_H
#define TESTLIB_H

/* Required symbols — always in .so */
int testlib_add(int a, int b);
void testlib_noop(void);

/* Optional symbol — in header but NOT in .so (simulates newer API version) */
int testlib_future(void);

#endif
