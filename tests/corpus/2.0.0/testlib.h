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
 *
 *   corpuslib_crosscheck -- unchanged byte-for-byte from 1.0.0, same
 *                        story as corpuslib_stable (code-review
 *                        Finding #19.7 — see 1.0.0/testlib.h).
 *
 * RFC-0003 slice A2 (see 1.0.0/testlib.h's header comment for the full
 * rationale of each gated fixture symbol and the CORPUSLIB_VERSION
 * discriminator macro): this version changes/adds three more things:
 *
 *   corpuslib_gated_until      -- signature CHANGES from 1.0.0 (`int(int)`
 *                        becomes `double(int)`, return type only, same
 *                        arity -- identical drift shape to
 *                        corpuslib_changed and for the identical reason:
 *                        the shipped call-based assert can only
 *                        distinguish a return-type-only drift from an
 *                        unrelated compile failure).
 *
 *   corpuslib_gated_since      -- newly declared in this version (absent
 *                        from 1.0.0): matches the binding's pinned
 *                        signature exactly, so a header-alone check here
 *                        classifies `verified`.
 *
 *   corpuslib_gated_crosscheck -- signature ALSO changes from 1.0.0
 *                        (`int(int)` -> `double(int)`, same return-type-
 *                        only shape), independent of the vendored
 *                        {.prototype.} staleness story that lives at
 *                        1.0.0 (see that version's header comment).
 *
 * RFC-0003 slice B2b (see 1.0.0/testlib.h's header comment for the full
 * rationale): this version changes one more thing:
 *
 *   corpuslib_param_drift -- the parameter's POINTER TYPE drifts from
 *                        1.0.0's `int *` to `unsigned char *` here; the
 *                        RETURN type (`int`) is held fixed on purpose
 *                        (RFC-0003 §7 B2b: isolating Gap B means the
 *                        return-type-only assert must have nothing to
 *                        catch here at all -- only the dummy call's
 *                        argument-passing diagnostic can).
 *
 * RFC-0003 slice B2c adds two tolerance-regression-control symbols (see
 * 1.0.0/testlib.h's header comment and tests/corpus/README.md for the
 * full rationale) -- both declared here BYTE-IDENTICAL to 1.0.0, on
 * purpose (UNGATED, never drifting):
 *
 *   corpuslib_const_return -- `const char *corpuslib_const_return(void);`,
 *                        identical to 1.0.0.
 *
 *   corpuslib_const_param -- `int corpuslib_const_param(const char *s);`,
 *                        identical to 1.0.0.
 */

#ifdef __cplusplus
extern "C" {
#endif

#define CORPUSLIB_VERSION 200

int corpuslib_stable(int a, int b);

double corpuslib_changed(int a);

int corpuslib_added(int x);

int corpuslib_crosscheck(int a, int b);

double corpuslib_gated_until(int a);

int corpuslib_gated_since(int a);

double corpuslib_gated_crosscheck(int a);

int corpuslib_param_drift(unsigned char *p);

const char *corpuslib_const_return(void);

int corpuslib_const_param(const char *s);

#ifdef __cplusplus
}
#endif

#endif
