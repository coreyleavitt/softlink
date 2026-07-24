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
 *
 * RFC-0003 slice A2 adds a CORPUSLIB_VERSION discriminator macro (new
 * setup work -- this corpus had no version-discriminator macro before A2,
 * unlike the unrelated single-header tests/testlib.h's TESTLIB_VERSION)
 * plus three hand-written-gate fixture symbols, each pinned to the
 * existing healthy 1.0.0/2.0.0 pair (no new corpus version directory):
 *
 *   corpuslib_gated_until      -- signature drifts 1.0.0 -> 2.0.0 exactly
 *                        like corpuslib_changed (return type only), but
 *                        the BINDING additionally carries a hand
 *                        {.verifyWhen: "CORPUSLIB_VERSION < 200".} gate
 *                        that CLOSES at the drift version, paired with
 *                        {.until: "2.0.0".}. Pre-RFC-0003 (gate-respecting)
 *                        harvest: the closed gate elides the assert at
 *                        2.0.0, the verify probe trivially compiles, and
 *                        the drift is masked as a false `verified` (RFC-
 *                        0003 Gap A). Ground truth (post-A2) defeats the
 *                        gate in the probe TU, so the real drift surfaces
 *                        as `mismatch` at 2.0.0.
 *
 *   corpuslib_gated_since      -- NOT declared here at all (added at
 *                        2.0.0, see that version's header), paired with a
 *                        hand {.verifyWhen: "CORPUSLIB_VERSION >= 200".}
 *                        gate that OPENS at 2.0.0 and {.since: "2.0.0".}
 *                        (RFC-0003 §4.5's since+hand-verifyWhen
 *                        companion — since-only procs carry no
 *                        synthesized gate, so the masked case is a hand
 *                        gate paired with since). Pre-RFC-0003: the
 *                        closed gate at 1.0.0 elides BOTH the existence
 *                        reference and the assert, so the probe
 *                        trivially compiles even though the header never
 *                        declares the symbol -- a false `verified` where
 *                        the correct fact is `absent`. Ground truth
 *                        defeats the gate, so the existence probe
 *                        genuinely fails at 1.0.0 (correct `absent`).
 *
 *   corpuslib_gated_crosscheck -- RFC-0003 §5.2(iv): a header+prototype
 *                        symbol whose vendored {.prototype.} decl is
 *                        STALE relative to whichever corpus version is
 *                        being checked. Declared here (1.0.0) as
 *                        `int corpuslib_gated_crosscheck(int a)` -- the
 *                        binding pins this TRUE 1.0.0 signature and a
 *                        {.prototype: "double corpuslib_gated_crosscheck(int a)".}
 *                        string that matches 2.0.0's signature instead
 *                        (see 2.0.0/testlib.h) -- stale at 1.0.0. Without
 *                        A1's verify-probe suppression of the probed
 *                        symbol's own vendored decl, the stale `double(int)`
 *                        extern conflicts with the header's real
 *                        `int(int)` declaration at file scope, a hard
 *                        compile error unrelated to the header's own
 *                        truth -- a false `mismatch`/`unknown` from
 *                        scaffolding freshness. With the suppression, only
 *                        the header's own declaration is checked, and the
 *                        binding's pinned 1.0.0 signature matches it:
 *                        `verified`, from the header alone. Also carries
 *                        the SAME {.verifyWhen: "CORPUSLIB_VERSION < 200".}
 *                        + {.until: "2.0.0".} gate as corpuslib_gated_until
 *                        (this symbol's own true signature drifts at
 *                        2.0.0 too -- see that version's header), so it
 *                        doubles as a second gated-drift fixture.
 *
 * RFC-0003 slice B2b adds the Gap B (parameter-drift) fixture -- the
 * nim-z3 `Z3_fpa_get_numeral_sign` shape (RETURN type held fixed, a
 * POINTER PARAMETER drifts) that no return-type-only assert can catch,
 * caught ONLY via the dummy-call + the B2a `-Werror=incompatible-pointer-
 * types` pin. UNGATED (no verifyWhen/since/until) on purpose -- this
 * isolates Gap B from Gap A; nothing here depends on gate defeat.
 *
 *   corpuslib_param_drift -- declared HERE (1.0.0) as
 *                        `int corpuslib_param_drift(int *p)`; 2.0.0
 *                        changes ONLY the parameter's pointee type, to
 *                        `unsigned char *` (the corpus's existing style
 *                        favors plain C types over `<stdbool.h>`'s `bool`
 *                        -- `unsigned char*` is RFC-0003 §7 B2b's named
 *                        equivalent shape). The binding pins the TRUE
 *                        1.0.0 signature (`ptr cint`). A binding compiled
 *                        against 1.0.0's header classifies `verified`; the
 *                        SAME binding's dummy call against 2.0.0's header
 *                        passes an `int*` where the header now declares
 *                        `unsigned char*` -- an incompatible-pointer-types
 *                        diagnostic at the dummy call site, never reaching
 *                        softlink's own assert (RFC-0003 §1 Gap B),
 *                        reclassified `mismatch` by the isolation argument
 *                        (§5.2 ii) once the diagnostic is pinned to an
 *                        error (§5.2 i) -- see tests/tharvest.nim's
 *                        "corpuslib_param_drift" suite for the full
 *                        pinned-vs-permissive-toolchain proof.
 *
 * RFC-0003 slice B2c adds TWO more symbols -- tolerance REGRESSION
 * CONTROLS, not drift fixtures: both are UNGATED and declared with the
 * IDENTICAL signature at every corpus version (never drift), proving the
 * B2a/B2b diagnostic-severity pins (and GCC 15's own default-error
 * behavior) do NOT reverse GH #11's const-tolerance -- the whole point of
 * this slice. See tests/corpus/README.md's "RFC-0003 slice B2c" section
 * for the full derivation of why these are the two mechanically-
 * achievable const-tolerance directions (Nim's type system has no way to
 * emit a `const`-qualified C type itself, so only "header adds const
 * relative to the unqualified Nim/C type" is constructible -- at the
 * RETURN position (GH #11 itself) and, independently, at the PARAMETER
 * position (verify.nim's own dummy-call mechanism, never previously
 * fixture-covered)):
 *
 *   corpuslib_const_return -- RETURN-position #11 shape: this header
 *                        declares `const char *` as the return type; the
 *                        binding declares Nim return type `cstring`
 *                        (RFC-0001 finding #11: `strerror`/libz3's
 *                        `Z3_string`). Must classify `verified` at both
 *                        1.0.0 and 2.0.0.
 *
 *   corpuslib_const_param -- PARAMETER-position tolerance shape (the
 *                        mirror of #11 for the OTHER code path,
 *                        `src/softlink/verify.nim`'s dummy-var mechanism,
 *                        comment: "enabling const-tolerant param checking
 *                        (int* implicitly converts to const int* in C)"):
 *                        this header declares a `const char *` PARAMETER;
 *                        the binding declares the Nim param type
 *                        `cstring`, so the emitted (non-const) dummy `char
 *                        *` var is passed into the header's `const char *`
 *                        parameter -- a standard, warning-free C qualifier
 *                        ADDITION (never a "discards qualifiers" diagnostic
 *                        -- that direction would require a const-qualified
 *                        Nim-side dummy var, which Nim's type system cannot
 *                        produce; see tests/corpus/README.md). Must
 *                        classify `verified` at both 1.0.0 and 2.0.0.
 */

#define CORPUSLIB_VERSION 100

#ifdef __cplusplus
extern "C" {
#endif

int corpuslib_stable(int a, int b);

int corpuslib_changed(int a);

int corpuslib_crosscheck(int a, int b);

int corpuslib_gated_until(int a);

/* corpuslib_gated_since is NOT declared at 1.0.0 -- added at 2.0.0. */

int corpuslib_gated_crosscheck(int a);

int corpuslib_param_drift(int *p);

const char *corpuslib_const_return(void);

int corpuslib_const_param(const char *s);

#ifdef __cplusplus
}
#endif

#endif
