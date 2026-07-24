# tests/corpus — RFC-0001 slice B3a fixture corpus

This directory is a small, hand-authored **header corpus** in the shape
RFC-0001 SS B.2 describes: one snapshot directory per upstream version,
each containing the public header(s) as they existed at that version.
Slice B3 (not part of this slice) recompiles a binding module against
each `<version>/` directory in turn — via `--passC:-I tests/corpus/<version>`
— to harvest a per-symbol, per-version compatibility manifest.

This slice (B3a) only builds the fixture corpus and proves, via
`nimble test`'s `runCorpusChecks()`, that it has the properties B3 will
depend on. No harvester code lives here.

## Layout

```
tests/corpus/
  corpus.json       # fetch-config + provenance stub (see below)
  1.0.0/testlib.h
  2.0.0/testlib.h
  3.0.0/testlib.h
```

Each version directory contains exactly one header, `testlib.h` — the
name is deliberate: it's the same include name a real B3 binding module
would use (`#include "testlib.h"`), so prepending a corpus version's `-I`
shadows whichever copy would otherwise resolve.

Symbols are named `corpuslib_*`, distinct from the real `tests/testlib.h`
used by the rest of the suite (`testlib_*`). The corpus headers shadow
`tests/testlib.h` in B3's harvester compiles; distinct names mean an
accidental cross-resolution between the two could never silently mask a
corpus bug.

## Classification story

RFC-0001 SS B.2's classification table has four outcomes: `unknown`,
`absent`, `verified`, `mismatch`. This corpus is built so all four are
reachable:

| symbol              | 1.0.0                        | 2.0.0                              | 3.0.0     |
|----------------------|-------------------------------|--------------------------------------|-----------|
| `corpuslib_stable`   | `int corpuslib_stable(int a, int b);` | same signature, byte-identical | unreachable (broken include) |
| `corpuslib_changed`  | `int corpuslib_changed(int a);` | `double corpuslib_changed(int a);` (return type changed, arity unchanged) | unreachable |
| `corpuslib_added`    | not declared at all | `int corpuslib_added(int x);` (newly added) | unreachable |
| `corpuslib_crosscheck` | `int corpuslib_crosscheck(int a, int b);` | same signature, byte-identical | unreachable (broken include) |

A binding pinned to `corpuslib_stable`'s signature classifies `verified`
at both 1.0.0 and 2.0.0.

Code-review Finding #19.7: `corpuslib_crosscheck` carries the IDENTICAL
classification story as `corpuslib_stable` above, but
`tests/tharvest_binding.nim` binds it with BOTH `header` AND `prototype`
together (softlink's cross-check mode, RFC-0001 SS3 A.1/A4) rather than
`header` alone. This proves the harvester probes a cross-checked symbol
exactly like a header-only one — the `header`-vs-`prototype`-only
skip rule (`p.header.len == 0 and p.prototype.len > 0` in
`tools/harvest/harvester.nim`) only ever fires when `header` is ABSENT,
so a symbol carrying both is never skipped as "corpus-invariant."

A binding pinned to `corpuslib_changed`'s **1.0.0** signature
(`int corpuslib_changed(int a)`) classifies `verified` at 1.0.0 and
`mismatch` at 2.0.0, since the header now declares a different return
type for the same C name (arity is deliberately UNCHANGED — RFC-0001
slice B3's harvester classifies a verify-stage compile failure as
`mismatch` only when softlink's own fixed assert message appears in the
output; an arity change makes the verify TU's call expression itself a
raw "too few/many arguments" compiler error that preempts the assert
entirely, which would misclassify as `unknown` instead. A return-type-
only drift is the one signature-drift shape the shipped call-based
`_Static_assert` chain can distinguish from an unrelated compile
failure, so it's the shape this fixture — and every other mismatch
fixture in this project — uses).

A binding declaring `corpuslib_added` classifies `absent` at 1.0.0 (the
header simply doesn't mention it) and `verified` at 2.0.0.

`3.0.0/testlib.h` is the fourth fixture: its first substantive line is
`#include "some_nonexistent_dep.h"`, a header that exists nowhere in this
tree. Any translation unit that includes `3.0.0/testlib.h` fails to
compile at all, regardless of which symbol is being probed — this is
exactly RFC-0001 SS B.2's baseline-compile-fails row, which classifies
**every** symbol `unknown` at that version ("this version's headers
broken or missing for this module — reported, never silently dropped").
The symbol declarations still present after the broken `#include` in that
file are never reached by a real compile; they're kept only so the three
headers read as parallel side by side.

## RFC-0003 slice A2 — `CORPUSLIB_VERSION` + hand-written-gate fixtures

RFC-0003 (ground-truth harvest) needed a version-discriminator macro this
corpus never had before (the precedent, `TESTLIB_VERSION`, lives in the
unrelated single-header `tests/testlib.h`, not here). Each version
directory's header now defines `CORPUSLIB_VERSION` (`100`/`200`/`300` for
1.0.0/2.0.0/3.0.0 respectively — 3.0.0's is unreachable, same as its
symbol declarations, kept only for parallel structure). Three new
`corpuslib_*` symbols pair this macro with a hand-written `{.verifyWhen.}`
gate on the binding side (`tests/tharvest_binding.nim`) — no
`versionMacros` synthesis machinery, no new corpus version directory; the
gated drift stories all fit the existing healthy 1.0.0/2.0.0 pair:

| symbol | 1.0.0 | 2.0.0 | gate |
|---|---|---|---|
| `corpuslib_gated_until` | `int corpuslib_gated_until(int a);` | `double corpuslib_gated_until(int a);` (return-type drift, same shape as `corpuslib_changed`) | `{.verifyWhen: "CORPUSLIB_VERSION < 200".}` + `{.until: "2.0.0".}` — CLOSES at the drift version |
| `corpuslib_gated_since` | not declared at all | `int corpuslib_gated_since(int a);` (newly added) | `{.verifyWhen: "CORPUSLIB_VERSION >= 200".}` + `{.since: "2.0.0".}` — OPENS at the version the symbol is added |
| `corpuslib_gated_crosscheck` | `int corpuslib_gated_crosscheck(int a);` | `double corpuslib_gated_crosscheck(int a);` (same return-type drift) | same closing gate as `corpuslib_gated_until`; ALSO bound with a vendored `{.prototype: "double corpuslib_gated_crosscheck(int a)".}` that matches 2.0.0's shape — STALE at 1.0.0, the version the binding claims validity for |

**`corpuslib_gated_until`** is RFC-0003's Gap A shape: the binding pins
1.0.0's signature and declares `until: "2.0.0"`, gated closed at exactly
the drift version. A gate-respecting (pre-RFC-0003) harvest elides the
verify probe's assert entirely once the gate is closed, so the probe
trivially compiles and the real drift is masked as a false `verified` at
2.0.0. Ground truth (RFC-0003 §4) defeats the gate in the probe TU, so
the drift surfaces as the correct `mismatch`.

**`corpuslib_gated_since`** is RFC-0003 §4.5's since+hand-`verifyWhen`
companion: since-only procs carry no synthesized gate, so the masked case
here is the hand gate paired with `since`. A gate-respecting harvest
elides BOTH the existence reference and the assert while the gate is
closed (below 2.0.0), so the probe at 1.0.0 trivially compiles even
though the header never declares the symbol at all — a false `verified`
where the correct fact is `absent`. Ground truth defeats the gate, so the
existence probe genuinely runs and correctly fails at 1.0.0.

**`corpuslib_gated_crosscheck`** is RFC-0003 §5.2(iv)'s stale-vendored-
prototype fixture: the binding pins 1.0.0's true signature
(`int(int)`) but its vendored `{.prototype.}` string matches 2.0.0's
signature (`double(int)`) instead — stale at 1.0.0, the version the
binding claims validity for. Without the verify probe's suppression of
the probed symbol's own vendored decl (RFC-0003 §5.2 iv, extending the
existing existence-probe suppression), the stale `extern double
corpuslib_gated_crosscheck(int a);` conflicts with the header's real
`int(int)` declaration at file scope — a hard compile error that has
nothing to do with the header's own truth, and would misclassify as a
false `mismatch`/`unknown`. With the suppression, only the header's
declaration is checked, and it matches the binding's pinned 1.0.0
signature: `verified`, from the header alone. It carries the identical
closing gate + `until: "2.0.0"` as `corpuslib_gated_until` (its own true
signature drifts at 2.0.0 too), so it doubles as a second gated-drift
proof once ground truth is applied.

## RFC-0003 slice B2b — `corpuslib_param_drift` (Gap B end-to-end)

Slice B2b adds ONE more symbol, isolating RFC-0003's Gap B (the
call-based assert audits only the RETURN type; a POINTER PARAMETER-only
drift never reaches it) from Gap A (gate-masking, A2/A3's story above).
`corpuslib_param_drift` carries no `verifyWhen`/`since`/`until` at all —
deliberately UNGATED, so nothing about this fixture depends on gate
defeat:

| symbol | 1.0.0 | 2.0.0 | gate |
|---|---|---|---|
| `corpuslib_param_drift` | `int corpuslib_param_drift(int *p);` | `int corpuslib_param_drift(unsigned char *p);` (RETURN type held fixed; only the parameter's POINTEE type drifts) | none — ungated |

This is the nim-z3 `Z3_fpa_get_numeral_sign` shape the motivating report
(§1/§2 of the RFC) named directly: same name, same return type, a
pointer parameter's base type changes. The binding
(`tests/tharvest_binding.nim`) pins the TRUE 1.0.0 signature
(`proc corpuslib_param_drift(p: ptr cint): cint`). Because the return
type never changes, softlink's own `_Static_assert`-based signature
check has nothing to catch here — the ONLY place the drift can surface
is the dummy call's own argument at the verify probe's call site,
which the C compiler diagnoses as `incompatible-pointer-types` passing
`int *` where `unsigned char *` is now declared. `unsigned char *` (not
`bool *`) is used to match this corpus's existing plain-C style — no
header here pulls in `<stdbool.h>` — RFC-0003 §7 B2b names this as an
explicitly equivalent shape.

Whether that diagnostic is DECISIVE (a hard compile error the verify
probe cannot survive, reclassified `fkMismatch` by RFC-0003 §5.2(ii)'s
isolation argument) or merely a warning (verify probe compiles anyway,
a FALSE `fkVerified`) depends on the diagnostic's severity — which is
exactly what `defaultHarvestOptions`'s `-Werror=incompatible-pointer-
types` pin (slice B2a) controls. `tests/tharvest.nim`'s
`"corpuslib_param_drift — Gap B end-to-end (RFC-0003 §7 B2b)"` suite
proves both the real end-to-end classification (`fkVerified` at 1.0.0,
decisive `fkMismatch` at 2.0.0, on BOTH the standard and fast harvest
paths) AND, as a permanent regression proof that the pin is genuinely
load-bearing, the counterfactual: a caller opts literal that downgrades
the diagnostic back to a mere warning
(`--passC:-Wno-error=incompatible-pointer-types`, simulating exactly
the "permissive toolchain" scenario `defaultHarvestOptions`'s own doc
comment names) records the WRONG fact, `fkVerified`, at 2.0.0. (On this
project's own GCC 15.2.1 CI toolchain, GCC's own GCC-14+ default
already treats `incompatible-pointer-types` as an error even without
the pin — empirically confirmed while writing this fixture — so the
pin is, in the RFC's own words, "inert against the committed corpus" on
THIS toolchain in the narrow sense that removing only the explicit
`-Werror=` flag doesn't change the outcome here; the downgrade-to-
warning counterfactual is what actually isolates the pin's severity
control, matching what an older GCC or a permissive Clang configuration
would do by default.)

## RFC-0003 slice B2c — tolerance regression controls

Slice B2c adds TWO more symbols, but unlike every fixture above they are
NOT drift fixtures at all — they are **regression controls**, proving the
opposite claim: that B2a's/B2b's `-Werror=` diagnostic-severity pins (and
GCC 15's own default-error promotion for `incompatible-pointer-types`,
the B2b finding) do NOT reverse GH #11's const-tolerance. Both are
UNGATED and declared with the BYTE-IDENTICAL signature at every corpus
version (never drift):

| symbol | 1.0.0 / 2.0.0 | 3.0.0 |
|---|---|---|
| `corpuslib_const_return` | `const char *corpuslib_const_return(void);` | unreachable (broken include, same as every other symbol) |
| `corpuslib_const_param` | `int corpuslib_const_param(const char *s);` | unreachable |

Both classify `verified` at 1.0.0 and 2.0.0 and `unknown` at 3.0.0 — the
same broken-baseline story every symbol in this corpus shares at 3.0.0,
unrelated to either symbol's own signature. If EITHER symbol had ever
classified `mismatch` at 1.0.0 or 2.0.0, that would be a genuine
RFC-0003-invalidating finding (the diagnostic pins accidentally
criminalizing a legitimate binding pattern), not something to patch
around by loosening a pin.

**Why these two shapes, specifically.** GH #11 (`docs/` — see the issue
itself, and `src/softlink/verify.nim`'s doc comments) is about a C
function's header declaring `const char *` where the Nim binding declares
`cstring` (no const marker — Nim's type system has no way to express a
const-qualified pointer type at all, for either a parameter OR a return
type). `verify.nim` has TWO independent code paths that each tolerate
this same "header adds const, Nim/C-emitted binding type doesn't" shape,
for two different signature positions:

- **Return position** (the code path GH #11 itself is about): a
  three-tier compiler-specific mechanism (C++ `strip_ptr_const`, GCC/Clang
  `__builtin_types_compatible_p` on dereferenced operands, MSVC `_Generic`
  + `__typeof__`) that dereferences the pointer return and ignores the
  qualifier on the pointee before comparing types. `corpuslib_const_return`
  is this shape, extended from `tests/testlib.h`'s existing
  `testlib_const_string`/`testlib_const_lookup` main-suite regression
  tests (RFC-0001 finding #11) into the harvest/corpus world for the first
  time — proving ground truth (which defeats every gate unconditionally)
  and the B2a/B2b pins don't make this mechanism regress under a real
  harvest.
- **Parameter position** (`verify.nim`'s dummy-var mechanism, doc
  comment: "enabling const-tolerant param checking (int* implicitly
  converts to const int* in C)") — never covered by ANY fixture in this
  repo before B2c. The verify probe's dummy variable is typed from the
  Nim-declared parameter type verbatim (`cstring` emits as plain,
  non-const `char *`); passing that non-const `char *` into a header
  parameter declared `const char *` is a standard, warning-free C
  qualifier ADDITION (C's assignment-compatibility rule: the receiving
  side may have qualifiers the source lacks). `corpuslib_const_param` is
  this shape.

**Why not a literal "discards qualifiers" fixture.** The RFC's slice
brief also names a "qualifier-discard direction" as a candidate shape:
header takes a NON-const `char *` parameter, and the binding "passes a
const-qualified pointee" as the argument — the direction that, in plain
C, would trigger `-Wdiscarded-qualifiers` (a distinct GCC diagnostic
class from `-Wincompatible-pointer-types`, never promoted to a hard error
by either of this project's pins or by GCC's own defaults). This shape is
NOT mechanically constructible with the current dummy-var mechanism:
`verify.nim` never emits a `const` qualifier onto a dummy variable's type
under ANY circumstance (confirmed by inspection — the only `const`
strings anywhere in `verify.nim` belong to the C++ `strip_ptr_const`
helper template and to doc comments; the dummy var's type is
`paramType.copy()`, the Nim-declared parameter type verbatim, and Nim's
own type system has no const-qualified pointer type to declare in the
first place). Since only ONE side of a parameter comparison can ever
carry a qualifier in this codebase (the C header side), the only
constructible "opposite direction" from the return-position case is the
parameter-position case above — which is what `corpuslib_const_param`
tests. See `tests/tharvest_binding.nim`'s doc comment and
`tests/tharvest.nim`'s "RFC-0003 B2c" test suite entries for the same
derivation, restated at the fixture site.

## RFC-0003 slice C1 — the confirmation loop, composed onto `corpuslib_param_drift`

Slice C1 adds NO new corpus symbol and NO header edits at all (the RFC's
own instruction: "no fourth from-scratch drift symbol") — it composes a
hand `{.verifyWhen: "CORPUSLIB_VERSION < 200".}` gate + `{.until:
"2.0.0".}` onto B2b's ALREADY-committed `corpuslib_param_drift` symbol
(`tests/tharvest_binding.nim`), the identical closing-gate shape
`corpuslib_gated_until` uses above. This is the first fixture to combine
Gap A's shape (a gate) with Gap B's shape (a parameter-only drift) on one
symbol.

**Facts stay unchanged.** Ground truth (RFC-0003 §4) defeats the gate
inside the probe TU unconditionally, regardless of which fix (A or B) is
what makes the underlying drift decisive — so `corpuslib_param_drift`
harvests to the exact same facts as B2b's ungated version:
`fkVerified@1.0.0`, decisive `fkMismatch@2.0.0` (Gap B: the pointer
parameter's base type changes, caught only via the dummy call's own
`-Werror=incompatible-pointer-types` diagnostic), `fkUnknown@3.0.0`
(shared broken-baseline tail). `tests/tharvest.nim`'s classification-matrix
suite asserts this explicitly as a named regression proof, and the
standard/fast-path compile-count totals (45/48 as of B2c) are UNCHANGED —
`verifyWhen`/`until` presence never participates in `harvester.nim`'s
symbol-selection or bisection-grouping logic (both are keyed on C-name
lists alone), and ground truth's gate-defeat means the probe TU's emitted
shape for this symbol is identical whether or not it carries a gate.

**What's new is at the manifest-consumption layer.** `until: "2.0.0"` is
now a real, checkable claim against the real harvested manifest:
`checkUntil` POSITIVELY CONFIRMS it — a decisive `fkMismatch` classification
AT the bound is rule (b)/(b′)'s expected, confirming outcome (not a
refusal), and `fkVerified` below it (1.0.0) is rule (c)'s required positive
evidence. This is the acceptance bullet RFC-0003 §1/§9 names directly:
"mismatch at-or-above the bound is the expected outcome, verified-below the
supporting evidence" — now demonstrated end to end against a REAL harvest
of a symbol whose drift only Gap B's fix can see, composed with a REAL Gap
A gate. See `tests/tharvest.nim`'s "checkUntil confirms the declared bound
for corpuslib_param_drift" test (same synthetic-2-version-corpus isolation
as the pre-existing `corpuslib_gated_until` confirmation test, for the
identical reason: this fixture corpus's own 3.0.0 entry never classifies
decisively for ANY symbol, which would otherwise trip rule (b′)
unconditionally and mask this acceptance bullet's actual claim).

`classifyAbsence`'s `mrExpected` acceptance bullet reuses A2's
`corpuslib_gated_since` fixture (absent@1.0.0 under ground truth, added at
2.0.0) rather than a new symbol too — see the same test file's
"classifyAbsence yields mrExpected" test, driven off the real harvested
manifest.

## `corpus.json` — fetch-config + provenance stub

`corpus.json` plays two roles a real corpus's fetch config would need,
per RFC-0001 SS B.2:

- **Provenance**: each entry records `version` and `source`
  (`git:owner/repo@<sha>`) — the upstream tag and commit hash a real
  fetch script would have snapshotted the headers from. This fixture's
  `source` values are well-formed but fake (`git:example/testlib@<40 hex
  chars>`); nothing here was actually fetched.

- **The `prepare` hook (reserved, not yet implemented)**: exactly one
  entry (`2.0.0`) carries a `prepare` command, illustrating RFC-0001 SS
  B.2's *intended* optional per-version prepare step for libraries whose
  public headers are configure/generate outputs rather than checked-in
  files (mbedtls's config-dependent headers are the motivating case
  there). **Current behavior**: the harvester does NOT run `prepare` —
  `loadCorpusProvenance` (`tools/harvest/harvester.nim`) reads only
  `version` and `source` from each entry and silently ignores `prepare`
  and `_comment`; nothing in this repo shells out to it. **Intended
  future semantics**: once wired up, a fetch script would run `prepare`
  in the library's source checkout *before* capturing that version's
  header snapshot, so generated headers are captured as they'd actually
  appear to a consumer, not as blank templates. Header-only, no-configure
  libraries (like this fixture corpus) would need no `prepare` at all,
  which is why only one of the three entries here carries one — it
  exists to give a future implementation (and any real fetch script
  modeled on this file) a concrete target, not because the harvester
  acts on it today.

JSON has no comment syntax, so the semantics above (and this stub's
purpose) are recorded both here and in `corpus.json`'s own `_comment` key.
