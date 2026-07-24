## RFC-0001 SS4 B.2/B.3 slice B3: the harvester's integration-test binding
## fixture. Bound against `tests/corpus`'s `corpuslib_*` symbols (slice
## B3a; see tests/corpus/README.md for the full classification narrative),
## NOT the suite's own `tests/testlib.h` — distinct symbol names mean an
## accidental cross-resolution between the two corpora could never
## silently mask a bug.
##
## `header: "testlib.h"` is deliberately BARE (no `tests/` prefix): the
## harvester prepends each corpus version directory via the toolchain's
## include-dir flag, and each `tests/corpus/<version>/` snapshot contains
## exactly one file also named `testlib.h` — the bare name is what lets the
## prepended `-I`/`/I` actually SHADOW anything else on the include path
## (see tests/corpus/README.md).
##
## Five procs, one per corpus fixture symbol plus one proving the
## `{.prototype.}`-only skip path (RFC-0001 SS4 B.2: corpus-invariant,
## never probed):
##   - `corpuslib_stable`    pinned to its TRUE, unchanging signature.
##   - `corpuslib_changed`   pinned to its 1.0.0 signature on purpose — the
##     2.0.0 header changes the return type (only — see
##     tests/corpus/README.md for why the drift is return-type-only).
##   - `corpuslib_added`     pinned to its 2.0.0 signature — 1.0.0's header
##     never declares it at all.
##   - `corpuslib_protoonly` prototype-only (no `header`): the harvester
##     must skip it, never probe it against any corpus version.
##   - `corpuslib_crosscheck` code-review Finding #19.7: bound with BOTH
##     `header` AND `prototype` together (softlink's cross-check mode,
##     RFC-0001 SS3 A.1/A4) — no prior harvester fixture exercised this
##     combination. Its signature is TRUE and unchanging (same story as
##     `corpuslib_stable`; see tests/corpus/README.md), so this pins that
##     the harvester probes it exactly like a header-only symbol
##     (`verified` at 1.0.0/2.0.0, `unknown` at 3.0.0) — never skipped as
##     "corpus-invariant" the way a `{.prototype.}`-only proc is.
##
## RFC-0003 slice A2 adds three hand-written-gate fixture procs, pinned to
## the healthy 1.0.0/2.0.0 pair via the corpus's new `CORPUSLIB_VERSION`
## discriminator macro (see tests/corpus/README.md's "RFC-0003 slice A2"
## section for the full per-symbol classification narrative):
##   - `corpuslib_gated_until`      Gap A shape (RFC-0003 §1/§4): drifts
##     1.0.0 -> 2.0.0 exactly like `corpuslib_changed`, but ALSO carries a
##     hand `{.verifyWhen.}` gate that CLOSES at the drift version, paired
##     with `{.until: "2.0.0".}` — a gate-respecting harvest masks the
##     drift as a false `verified`; ground truth defeats the gate and
##     records the real `mismatch`.
##   - `corpuslib_gated_since`      RFC-0003 §4.5's since+hand-`verifyWhen`
##     companion: absent at 1.0.0, added at 2.0.0, gated OPEN starting at
##     2.0.0 and paired with `{.since: "2.0.0".}` — a gate-respecting
##     harvest masks the below-`since` absence as a false `verified`
##     (nothing is even referenced while the gate is closed); ground truth
##     defeats the gate and records the real `absent`.
##   - `corpuslib_gated_crosscheck` RFC-0003 §5.2(iv)'s stale-vendored-
##     prototype fixture: pins 1.0.0's TRUE signature via `header`, but
##     its vendored `{.prototype.}` string matches 2.0.0's (drifted)
##     signature instead — stale at 1.0.0, the version the binding claims
##     validity for. The verify probe's suppression of the probed
##     symbol's own vendored decl (extending the existing existence-probe
##     suppression) is what keeps this `verified` (checked against the
##     header alone) instead of a false `mismatch` from the stale
##     scaffolding conflicting with the header at file scope. Carries the
##     same closing gate + `until: "2.0.0"` as `corpuslib_gated_until`
##     (its own true signature drifts at 2.0.0 too), doubling as a second
##     gated-drift proof.
##
## RFC-0003 slice B2b adds ONE more proc, the Gap B (parameter-drift) end-
## to-end fixture — originally UNGATED (no verifyWhen/since/until), to
## isolate Gap B from Gap A on purpose:
##   - `corpuslib_param_drift`     pinned to its TRUE 1.0.0 signature
##     (`int corpuslib_param_drift(int *p)` — `ptr cint` here). 2.0.0's
##     header changes ONLY the parameter's pointee type, to
##     `unsigned char *` (RETURN type held fixed — the nim-z3
##     `Z3_fpa_get_numeral_sign` shape, RFC-0003 §1/§7 B2b). The return-
##     type-only call-based assert has nothing to catch here; only the
##     dummy call's own argument-passing diagnostic does (Gap B), pinned to
##     a hard error by `defaultHarvestOptions`'s `-Werror=incompatible-
##     pointer-types` (slice B2a) and reclassified `fkMismatch` by the
##     isolation argument (RFC-0003 §5.2 ii) — see tests/tharvest.nim's
##     "corpuslib_param_drift" suite for the full classification proof,
##     including the pinned-vs-permissive-toolchain counterfactual.
##
## RFC-0003 slice C1 (the confirmation loop, end to end) COMPOSES a hand
## `{.verifyWhen.}` gate + `{.until: "2.0.0".}` onto THIS SAME symbol —
## deliberately reusing B2b's already-decisively-mismatched param-drift
## fixture rather than inventing a fourth from-scratch drift symbol (RFC-
## 0003 §7 C1: "no fourth from-scratch drift symbol"). The gate is the
## IDENTICAL closing shape `corpuslib_gated_until` already uses
## (`CORPUSLIB_VERSION < 200`), composed for the first time onto a Gap B
## (parameter-only) drift rather than a Gap A (return-type) one — proving
## ground truth's gate-defeat (§4) generalizes to a symbol whose drift only
## Gap B's fix (the `-Werror=incompatible-pointer-types` pin + isolation
## reclassify) can even see: the HARVEST facts stay byte-for-byte identical
## to B2b's ungated shape (`fkVerified@1.0.0`, decisive `fkMismatch@2.0.0`
## — see tests/tharvest.nim's classification-matrix suite, which asserts
## this explicitly as a regression proof), because ground truth defeats the
## gate in the probe TU regardless of which fix (A or B) is what makes the
## drift decisive underneath it. What's NEW at the RUNTIME/manifest-
## consumption layer is that `until: "2.0.0"` is now a real, checkable
## claim: `checkUntil` POSITIVELY CONFIRMS it against the real harvested
## manifest (tests/tharvest.nim's "checkUntil confirms the declared bound
## for corpuslib_param_drift" test) — a decisive `fkMismatch` AT the bound
## is rule (b)/(b′)'s expected, confirming outcome, not a refusal.
##
## RFC-0003 slice B2c adds TWO more procs, tolerance REGRESSION CONTROLS
## (not drift fixtures) — both UNGATED and pinned to the SAME signature at
## every corpus version (see tests/corpus/README.md's "RFC-0003 slice B2c"
## section for the full derivation):
##   - `corpuslib_const_return`  RETURN-position GH #11 shape: header
##     declares `const char *corpuslib_const_return(void);`; bound with
##     Nim return type `cstring`. Must classify `verified` at every
##     reachable corpus version — proving the B2a/B2b `-Werror=` pins (and
##     GCC 15's own default-error promotion) do NOT reverse #11's
##     const-tolerance.
##   - `corpuslib_const_param`   PARAMETER-position tolerance shape (the
##     mirror of #11 for `verify.nim`'s OTHER const-tolerant code path —
##     the dummy-call mechanism, never previously fixture-covered): header
##     declares `int corpuslib_const_param(const char *s);`; bound with
##     Nim param type `cstring`, so the emitted (non-const) `char *` dummy
##     var is passed into the header's `const char *` parameter — a
##     standard, warning-free qualifier ADDITION. Must ALSO classify
##     `verified` at every reachable corpus version.
##
## NOT compiled by the regular `nimble test` suite — this is B3's own
## integration fixture, driven by tests/tharvest.nim via a
## `-d:softlinkDumpProbes=<dir>` dump exactly like a real harvest would be.
import softlink

dynlib "libcorpuslib.so":
  proc corpuslib_stable(a: cint, b: cint): cint {.cdecl, header: "testlib.h".}
  proc corpuslib_changed(a: cint): cint {.cdecl, header: "testlib.h".}
  proc corpuslib_added(x: cint): cint {.cdecl, header: "testlib.h".}
  proc corpuslib_protoonly(): cint
    {.cdecl, prototype: "int corpuslib_protoonly(void)".}
  proc corpuslib_crosscheck(a: cint, b: cint): cint
    {.cdecl, header: "testlib.h",
      prototype: "int corpuslib_crosscheck(int a, int b)".}
  proc corpuslib_gated_until(a: cint): cint
    {.cdecl, header: "testlib.h",
      verifyWhen: "CORPUSLIB_VERSION < 200", until: "2.0.0".}
  proc corpuslib_gated_since(a: cint): cint
    {.cdecl, header: "testlib.h",
      verifyWhen: "CORPUSLIB_VERSION >= 200", since: "2.0.0".}
  proc corpuslib_gated_crosscheck(a: cint): cint
    {.cdecl, header: "testlib.h",
      prototype: "double corpuslib_gated_crosscheck(int a)",
      verifyWhen: "CORPUSLIB_VERSION < 200", until: "2.0.0".}
  proc corpuslib_param_drift(p: ptr cint): cint
    {.cdecl, header: "testlib.h",
      verifyWhen: "CORPUSLIB_VERSION < 200", until: "2.0.0".}
  proc corpuslib_const_return(): cstring {.cdecl, header: "testlib.h".}
  proc corpuslib_const_param(s: cstring): cint {.cdecl, header: "testlib.h".}
