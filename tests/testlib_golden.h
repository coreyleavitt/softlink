#ifndef TESTLIB_GOLDEN_H
#define TESTLIB_GOLDEN_H

/* RFC-0003 §7 A1: a dedicated, minimal header for the byte-identical
 * generated-C golden-snapshot check (`tests/tgolden_verify_apparatus.nim` +
 * `runGoldenVerifyApparatusCheck` in `softlink.nimble`) — deliberately its
 * own header/proc, decoupled from tests/testlib.h's own churn, so the
 * golden snapshot only ever changes for a reason that actually touches
 * `genVerifyBlock`'s emission (a Nim-version codegen shift, or a genuine
 * verify.nim change), never as a side effect of an unrelated testlib.h
 * edit. Declared here only — nothing ever dlsym's or calls it; the golden
 * check is a --compileOnly proof. */

#ifdef __cplusplus
extern "C" {
#endif

int softlink_golden_add(int a, int b);

#ifdef __cplusplus
}
#endif

#endif
