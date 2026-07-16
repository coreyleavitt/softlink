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

A binding pinned to `corpuslib_stable`'s signature classifies `verified`
at both 1.0.0 and 2.0.0.

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

## `corpus.json` — fetch-config + provenance stub

`corpus.json` plays two roles a real corpus's fetch config would need,
per RFC-0001 SS B.2:

- **Provenance**: each entry records `version` and `source`
  (`git:owner/repo@<sha>`) — the upstream tag and commit hash a real
  fetch script would have snapshotted the headers from. This fixture's
  `source` values are well-formed but fake (`git:example/testlib@<40 hex
  chars>`); nothing here was actually fetched.

- **The `prepare` hook**: exactly one entry (`2.0.0`) carries a `prepare`
  command, illustrating RFC-0001 SS B.2's optional per-version prepare
  step for libraries whose public headers are configure/generate outputs
  rather than checked-in files (mbedtls's config-dependent headers are
  the motivating case there). **Semantics**: when present, the harvester
  runs `prepare` in the library's source checkout *before* capturing that
  version's header snapshot — the snapshot is taken *after* `prepare`
  finishes, so generated headers are captured as they'd actually appear
  to a consumer, not as blank templates. Header-only, no-configure
  libraries (like this fixture corpus) need no `prepare` at all, which is
  why only one of the three entries here carries one.

JSON has no comment syntax, so the semantics above (and this stub's
purpose) are recorded both here and in `corpus.json`'s own `_comment` key.
