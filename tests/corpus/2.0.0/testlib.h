#ifndef CORPUS_TESTLIB_H
#define CORPUS_TESTLIB_H

/* RFC-0001 slice B3a fixture corpus -- version 2.0.0
 *
 * See 1.0.0/testlib.h's header comment for the full corpus rationale and
 * tests/corpus/README.md for the complete classification narrative. This
 * version changes exactly two things relative to 1.0.0:
 *
 *   corpuslib_changed -- signature CHANGED from 1.0.0 (`int (int)` here
 *                        becomes `double (int)` — RETURN TYPE ONLY, same
 *                        arity; see 1.0.0/testlib.h's header comment for
 *                        why an arity change isn't used here): a binding
 *                        pinned to the 1.0.0 signature classifies
 *                        `mismatch` against this version's header.
 *
 *   corpuslib_added   -- newly declared in this version (absent from
 *                        1.0.0): a binding classifies `verified` here
 *                        (and `absent` at 1.0.0).
 *
 *   corpuslib_stable  -- unchanged byte-for-byte from 1.0.0: `verified`
 *                        at both versions.
 */

#ifdef __cplusplus
extern "C" {
#endif

int corpuslib_stable(int a, int b);

double corpuslib_changed(int a);

int corpuslib_added(int x);

#ifdef __cplusplus
}
#endif

#endif
