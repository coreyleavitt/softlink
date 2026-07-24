#ifndef CORPUS_TESTLIB_H
#define CORPUS_TESTLIB_H

/* RFC-0001 slice B3a fixture corpus -- version 3.0.0: the broken-include
 * version, and the fixture for the `unknown` classification.
 *
 * The very first substantive line below #includes a header that does not
 * exist anywhere in this corpus tree. ANY translation unit that includes
 * this file -- regardless of which symbol it's trying to probe -- fails
 * to compile. That is deliberate: the harvester's baseline compile
 * (ProbeOnly=-, RFC-0001 SS B.2's classification table) fails here before
 * existence/verify probing can even run, so every symbol classifies
 * `unknown` at this version ("this version's headers broken or missing
 * for this module -- reported, never silently dropped").
 *
 * The symbol declarations below are never actually reached by a real
 * compile (the broken #include aborts the TU first) -- they're kept here
 * anyway, matching 2.0.0's shape, purely for a human reader comparing the
 * three headers side by side.
 */

#include "some_nonexistent_dep.h"

#ifdef __cplusplus
extern "C" {
#endif

#define CORPUSLIB_VERSION 300

int corpuslib_stable(int a, int b);

double corpuslib_changed(int a, int b);

int corpuslib_added(int x);

int corpuslib_crosscheck(int a, int b);

double corpuslib_gated_until(int a, int b);

int corpuslib_gated_since(int a);

double corpuslib_gated_crosscheck(int a, int b);

int corpuslib_param_drift(unsigned char *p);

const char *corpuslib_const_return(void);

int corpuslib_const_param(const char *s);

#ifdef __cplusplus
}
#endif

#endif
