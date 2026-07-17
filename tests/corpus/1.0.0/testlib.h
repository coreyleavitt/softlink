#ifndef CORPUS_TESTLIB_H
#define CORPUS_TESTLIB_H

/* RFC-0001 slice B3a fixture corpus -- version 1.0.0
 *
 * This is NOT the real tests/testlib.h used by the rest of the suite --
 * it is a small, self-contained corpus snapshot that the (not-yet-written)
 * slice B3 harvester will compile the fixture binding module against, one
 * version directory at a time, via `--passC:-I tests/corpus/<version>`.
 * Symbol names are corpus-distinct (`corpuslib_*`) on purpose so a name
 * collision with the real tests/testlib.h can never silently mask a
 * corpus bug -- see tests/corpus/README.md for the full rationale.
 *
 * Classification story across the three corpus versions (full narrative
 * in tests/corpus/README.md):
 *
 *   corpuslib_stable  -- declared with the IDENTICAL signature in both
 *                        1.0.0 and 2.0.0. A binding pinned to this
 *                        signature classifies `verified` at both.
 *
 *   corpuslib_changed -- declared HERE with one signature
 *                        (`int corpuslib_changed(int a)`); 2.0.0 changes
 *                        the return type only (arity is unchanged — a
 *                        return-type-only drift is deliberate: it's the
 *                        one drift shape the shipped call-based
 *                        `_Static_assert` chain can actually distinguish
 *                        from an unrelated compile failure. An arity
 *                        change makes the call expression itself a raw
 *                        "too few/many arguments" compiler error, which
 *                        preempts softlink's own assert and would
 *                        misclassify as `unknown`, not `mismatch` — see
 *                        RFC-0001 slice B3's harvester, whose
 *                        `assertMismatchNeedle` confirmation depends on
 *                        the assert actually running). A binding pinned
 *                        to the 1.0.0 signature classifies `verified` at
 *                        1.0.0 and `mismatch` at 2.0.0.
 *
 *   corpuslib_added   -- NOT declared in this version at all; added in
 *                        2.0.0 (see that version's header). A binding
 *                        classifies `absent` at 1.0.0 and `verified` at
 *                        2.0.0.
 *
 * 3.0.0's testlib.h is the fourth classification's fixture: it fails to
 * compile at all (a broken #include near the top), so every symbol
 * probed against it classifies `unknown` -- see that version's header.
 *
 * corpuslib_crosscheck -- code-review Finding #19.7: declared with the
 *                        IDENTICAL signature in both 1.0.0 and 2.0.0,
 *                        same story as corpuslib_stable above, but the
 *                        harvester fixture binds it with BOTH `header`
 *                        AND `prototype` together (cross-check mode) --
 *                        see tests/tharvest_binding.nim. Proves the
 *                        harvester probes (never skips) a symbol bound
 *                        this way, classifying it identically to a
 *                        header-only binding.
 */

#ifdef __cplusplus
extern "C" {
#endif

int corpuslib_stable(int a, int b);

int corpuslib_changed(int a);

int corpuslib_crosscheck(int a, int b);

#ifdef __cplusplus
}
#endif

#endif
