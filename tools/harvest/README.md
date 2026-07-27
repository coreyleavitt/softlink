# softlink harvest — verified version compatibility (RFC-0001 Stage B)

This directory is the **harvester**: the tooling that turns a versioned C
header corpus into a committed `<lib>.compat.json` manifest, which a
`dynlib`/`verifyProcs` block can then attach via `compatManifest` to get
compile-time drift detection against a library's real release history —
not just today's headers.

It exists because softlink's core promise (§ top-level README) is "your
Nim signature matches THIS header, right now." That says nothing about
whether it still matched last year's release, or will match next year's.
The harvester is how a binding author finds out, on a schedule, before a
consumer does at runtime.

This document is written for a **binding author** adopting Stage B end to
end — it does not assume you've read RFC-0001. The RFC
(`../../docs/RFC-0001-verified-version-compat.md`) is the normative spec if
you need more depth than "how do I use this."

## Contents

- [Producer side: `softlink_harvest`](#producer-side-softlink_harvest)
  - [What it does](#what-it-does)
  - [What a harvested fact means](#what-a-harvested-fact-means)
  - [Classification table](#classification-table)
  - [Calibration preflight](#calibration-preflight)
  - [Fast path](#fast-path)
  - [Drift alarm and exit codes](#drift-alarm-and-exit-codes)
  - [Manifest schema](#manifest-schema)
  - [CLI usage](#cli-usage)
  - [Package layout / local dependency resolution](#package-layout--local-dependency-resolution)
  - [The one-screen happy path](#the-one-screen-happy-path)
- [The B.6 CI template](#the-b6-ci-template)
- [Consumer side: `compatManifest`](#consumer-side-compatmanifest)
  - [`checkUntil`: validating a declared `until` against the corpus](#checkuntil-validating-a-declared-until-against-the-corpus)

## Producer side: `softlink_harvest`

### What it does

`softlink_harvest` recompiles **your real binding module** against each
version snapshot in a header corpus, using two harvest-only compile modes
the `dynlib`/`verifyProcs` macros already understand
(`-d:softlinkProbeOnly=...` / `-d:softlinkProbeExistence`), and records,
per symbol per version, one of four classifications. It never parses your
binding's source — it locates your module via the probe-facts dump you
generate in a first, separate step (see [CLI usage](#cli-usage)), and
drives the *real compiler* against it.

**Corpus layout, precisely**: `<corpusDir>/<version>/` is passed directly
as a compiler include directory (`-I <corpusDir>/<version>`, or `/I` under
MSVC) — headers must sit directly under each version directory and
resolve exactly the way your binding's `header: "..."` names expect (as
`tests/corpus/1.0.0/testlib.h` does for this project's own fixture). If
upstream itself ships its public headers under its own `include/`
subdirectory, your fetch script should copy *that directory's contents*
into `<corpusDir>/<version>/`, not preserve the `include/` wrapper —
otherwise `#include "yourlib.h"` won't resolve against the snapshot.

### What a harvested fact means

Every fact this tool records — `verified`, `absent`, `mismatch`, `unknown`
— is **ground truth about that version's installed headers**, independent
of any compatibility scaffolding (`since`/`until`/`verifyWhen` gates,
vendored `{.prototype.}` declarations) the binding itself carries so that
*user compiles and runtime loads* work across versions (RFC-0003 §2). This
is not a mode and there is no flag to select it: every probe compile this
tool issues defeats the gates and prototype declarations it would otherwise
respect. `verified` means the header, read alone, matches the declared C
signature — not "your binding, with its particular gates, happened to
build."

**Why gates and prototypes are defeated (the bug this closes).** Before
RFC-0003, a probe TU carried the same `#if (verifyWhen)` wraps a user
compile does. At a version where the gate evaluates false, the whole
verification apparatus vanished under the preprocessor, the probe compiled
trivially, and the harvester recorded `verified` at exactly the version the
gate exists to protect against — the gate that makes user compiles safe was
precisely what made the corpus fact for that version worthless. A vendored
`{.prototype.}` declaration has the same failure shape for removals: a
`prototype`+`header` proc's TU-presence survives a header dropping the
symbol, so a naive probe never notices it's gone. Defeating both,
unconditionally, is what makes a harvested fact trustworthy standalone — you
can hand a `.compat.json` to `checkUntil` without also auditing which gates
happened to be open when it was produced.

**Feature-gated symbols are a corpus-baseline concern, not a pragma
question.** A hand-written `{.verifyWhen.}` might guard a library version,
or it might guard a compile-time feature flag (`#if defined
(MBEDTLS_SSL_PROTO_TLS1_3)`); softlink can't tell these apart mechanically,
and there is no sound way to defeat only the "version" ones. Ground truth
therefore defeats **all** gates uniformly. If a symbol is genuinely
feature-gated, the fix is on the corpus side: your harvest baseline build
must enable the feature the same way your real deployment does (RFC-0001's
baseline-build contract already covers this). With the feature off,
`absent` at that version is simply true of those headers as configured. A
symbol that must never be corpus-audited at all already has its own
pragma: `{.noverify.}`.

**The honest residual: non-pointer scalar drift.** The verify assert stays
call-based and const-tolerant (issue #11's founding decision) rather than
comparing full function-pointer types, so a parameter drift that is a
*valid implicit C conversion* — `int` widening to `long`, an enum growing a
member — converts silently and is never caught, on any toolchain, by
construction. A variadic-ness change is the same story. Closing this would
require the full-type assert the design explicitly rejects (it would
false-mismatch every `cstring`-vs-`const char *` binding — issue #11 again).
If your binding has a parameter shape like this, `{.until.}` still gets you
*declared* protection: `checkUntil` cross-checks a bound you assert, it just
can't discover that bound for you the way it now does for pointer-shaped
drift.

**Do not hand-edit a committed manifest.** When a harvest run looks wrong,
it's tempting to patch the JSON directly. The nim-z3 workstream that
produced RFC-0003 considered and rejected this: a hand edit is invisible to
`git diff` against the next real harvest, so it either silently reverts on
the next scheduled regeneration or silently diverges from what a fresh
harvest would actually find — either way defeating the point of the living
CI guard below. If a fact looks wrong, fix it upstream of the manifest (the
corpus, the calibration, or the binding's own gate) and re-harvest.

**The living CI guard.** A committed manifest, kept honest by the two fixes
above, is exactly what [`ci-template.yaml`](#the-b6-ci-template) turns into
a standing regression test: regenerate on a schedule, `git diff --exit-code`
against the committed copy, fail the job on any difference. A new drift at
a version the corpus didn't previously flag now shows up as a decisive
`mismatch`/`absent`, not a silent `unknown` a human has to notice by hand.

**`checkUntil` rule (b′) fires less often now.** Rule (b′) — an `unknown`
fact at or above a declared `until` is itself a hard error, because it's
neither confirmation nor contradiction — exists specifically because
parameter-only drift used to be *unclassifiable*: the harvester couldn't
decide `mismatch` for it, so the honest fallback was `unknown`, and rule
(b′) is what stopped that non-answer from silently passing as a confirmed
bound. RFC-0003's parameter-drift fix means the case rule (b′) was written
for — a real signature drift landing on `unknown` instead of `mismatch` —
now correctly lands on `mismatch` and is caught by rule (a)/(c) directly.
Rule (b′) still exists and still fires (a broken baseline build at the
corpus tip still yields `unknown` for everything), just for a narrower set
of cases than before this fix.

**`since` and `until` compose on one proc.** The harvester's gate-defeat
doesn't care which pragma produced a proc's gate string — it's an opaque C
predicate either way — so a proc carrying both a `since` and an `until`
(bounding a window on both sides) defeats correctly and classifies exactly
like a one-sided bound would. RFC-0003 slice C1 proves this end to end
against a real corpus.

**MSVC.** `/we4133` (escalating the pointer-parameter-mismatch warning to an
error) is not accepted as a pin spelling the way `-Werror=...` is for
GCC/Clang — nothing in this tool auto-detects or special-cases it. That's
fine in practice: the calibration preflight already refuses to harvest
under MSVC in every flag configuration this project tests, because the
fourth calibration symbol (parameter-only drift) requires a live,
teeth-having verification tier, and MSVC's default mode either has no tier
(the `_Generic` fallback) or a tier that doesn't escalate C4133. That's a
*principled* refusal (exit code 2, no manifest written) — never a silently
wrong fact — not a gap you need to work around. A caller could in
principle restore MSVC teeth by supplying `/we4133` in their own extra
flags; this is unsupported and untested, but calibration will tell you
immediately whether it worked.

### Classification table

For each `(version, symbol)` pair, up to three real `nim c --noLinking`
compiles run, each with the corpus version's headers shadowing any
system-installed copy (`-I <corpusDir>/<version>` prepended) plus
`-Werror=implicit-function-declaration` (an absent symbol must be a hard
compile error, never a warning a lenient toolchain shrugs off),
`-Werror=incompatible-pointer-types` (RFC-0003 §5.2(i): a pointer-parameter
drift must be a hard verify failure on every GCC/Clang version, not just
GCC≥14's own default — this is what makes parameter-only drift decisively
`mismatch`; the clang CI leg's `clangHarvestOptions()` additionally pins
Clang's separate `-Werror=incompatible-function-pointer-types`) and
`-d:softlinkStrictVerify` (RFC-0003 §5.2(iii): turns an otherwise-silent
"verification unsupported on this compiler/mode" no-op into a hard compile
failure the harvester can recognize, so a degraded toolchain is loud
instead of a silent hole):

| baseline (`ProbeOnly=-`) | existence probe | verify (full assert) | classification |
|---|---|---|---|
| fail | — | — | `unknown` — this version's headers are broken/missing for this module |
| ok | fail | — | `absent` — the header doesn't declare the symbol at all |
| ok | ok | ok | `verified` — the pinned Nim signature matches |
| ok | ok | fail, deterministic (reproduced on a retry), verification tier available | `mismatch` — a real signature drift |
| ok | ok | fail, but the strict-mode needle shows this compile's verification tier was structurally unavailable, OR the failure did not reproduce on retry (flaky) | `unknown` — no trustworthy signature evidence either way |

A `verify`-stage failure is never recorded on the strength of a single
compile (RFC-0003 §5.2(ii), "decisive requires deterministic" — a
corpus×symbol harvest is thousands of subprocess invocations, and a
transient failure — an OOM-killed `cc1`, a compiler crash — must never be
misread as a signature fact): a failing verify probe is retried once
before its failure is recorded, and output matching a known
infrastructure-failure shape (an internal compiler error, a
signal-terminated compiler process) aborts the entire harvest with no
manifest written at all, rather than ever recording a poisoned fact.

Every structural step (compiles either succeed or fail) is complemented by
a SMALL, fixed set of textual checks on a `verify`-stage failure's
output — never a substitute for the structural decision, only refinements
of it once a failure has already been structurally identified: confirming
softlink's own fixed `"... signature mismatch vs ..."` assert message
(confirming evidence for `mismatch`, not required for it — RFC-0003 §5.2(ii)
narrowed the older design, where its absence alone forced `unknown`);
recognizing the strict-mode `"...signature verification unavailable
here..."` needle (this compile's verification tier could not run at all);
and recognizing known infrastructure-failure shapes (the loud-abort guard
above). Older revisions of this document claimed assert-message
confirmation was the *only* place compiler output is ever inspected — that
claim predates RFC-0003 and is corrected here.

A proc whose only declaration source is `{.prototype.}` (no `{.header.}`)
verifies against a vendored, corpus-**invariant** declaration — there is
nothing version-shaped to record, so the harvester skips it (visible in
`softlink_harvest`'s report and in each `HarvestResult.skipped`). A
`{.noverify.}` proc has no verification apparatus emitted at all and is
skipped for the identical reason.

### Calibration preflight

Before touching your real corpus, the harvester compiles a small, built-in
known-answer quad (one symbol that should classify `verified`, one
`absent`, one `mismatch` via return-type drift, one `mismatch` via
parameter-only pointer drift) through the *identical* pipeline. If even one
of the four doesn't come out as expected, the run **aborts with no
manifest written** and a toolchain diagnosis — the structural guard against
a degraded verification tier (default-mode MSVC's no-op
`_Generic`/`__typeof__` fallback silently "verifies" everything,
unconditionally), a misconfigured toolchain (implicit-declaration-as-warning
instead of error), or a diagnostics-severity pin
(`-Werror=incompatible-pointer-types`) that's absent, stripped, or
ineffective for parameter-only pointer drift — poisoning a manifest with
false `verified` facts. The fourth symbol also proves this last case is not
merely theoretical: MSVC under `/std:clatest` treats pointer-parameter
mismatch as a warning by default and understands none of the GCC/Clang
`-Werror=` spellings, so calibration refuses there too — MSVC harvest
refuses in every flag configuration this project ships an opts literal
for, never silently misclassifying. This is exit code 2 (see
[below](#drift-alarm-and-exit-codes)).

### Fast path

`--fast-path` tries one plain, define-free compile of your module per
corpus version *first*. Success at that version means every probed symbol
is `verified` there — literally the shipped verification succeeding — no
further compiles needed. On failure, the harvester still needs the
baseline probe (headers-broken-or-not), and then **bisects**: it recompiles
with progressively smaller comma-joined symbol lists
(`-d:softlinkProbeOnly=<a,b,c>`), recursing into failing halves until it
isolates the failing singleton(s), each of which then runs the standard
three-probe pipeline. There is never any attempt to read *which* symbol
failed out of a group compile's output — only bisection ever attributes
a group failure to an individual symbol.

The fast path produces **identical facts** to the standard path, always —
it is a pure optimization, sound because per-symbol `_Static_assert`s are
independent statements in the verify translation unit. At small corpus/
symbol-count scale (this project's own fixture corpus) it can cost *more*
real compiles than the standard path, because of the define-free compile's
own up-front cost; the win is asymptotic (`O(k·log n)` for `k` drifted
symbols among `n`), and shows up at real-corpus scale (hundreds of
symbols, a handful drifted).

### Drift alarm and exit codes

`softlink_harvest` exits nonzero the moment anything is wrong — the RFC's
whole point is catching drift in CI, before any process loads anything:

| exit code | meaning |
|---|---|
| `0` | ok — manifest written, no `mismatch` inside the support range |
| `1` | **drift alarm** — at least one symbol has a `mismatch` classification inside the (optionally `--support-range`-narrowed) claimed support range |
| `2` | **calibration refused** — the toolchain failed the built-in preflight quad; **no manifest was written** |
| `3` | **usage/input error** — bad flags, missing dump/corpus, malformed manifest inputs |

When the drift alarm trips, the diagnosis names *every* offending symbol
together with *every* in-range mismatched version, followed by the RFC's
own sentence verbatim: *"one Nim signature cannot be sound across this
range — narrow the range or split the binding."* The manifest is still
written before the alarm is evaluated — Stage B's artifact is honest
either way (mismatch intervals recorded right alongside everything else);
the alarm is a CI tripwire layered on top, not a filter on what gets
recorded.

`--support-range:<lo>..<hi>` narrows which versions the alarm considers
(either bound omissible: `--support-range:..2.0.0`, `--support-range:1.0.0..`).
Default: the entire harvested corpus — every version you chose to
harvest is, by default, a version you're claiming to support.

### Manifest schema

```json
{
  "schema": 1,
  "lib": "z3",
  "harvest": { "toolchain": "gcc 14.2", "tier": "builtin-compat",
               "abi": "linux-lp64", "date": "2026-07-15",
               "harvesterVersion": "0.10.0" },
  "corpus": [{ "version": "4.15.0", "source": "git:z3prover/z3@<sha>" }],
  "symbols": {
    "Z3_replace_re_all": { "header": { "absent":   [{ "hi": "4.15.8" }],
                                       "verified": [{ "lo": "4.15.8" }] } }
  }
}
```

- `harvest.harvesterVersion` (RFC-0003 §2, slice C1) is the softlink
  package version that performed the harvest — provenance metadata, not a
  behavior switch. OPTIONAL: a manifest committed before this field
  existed simply omits it and continues to attach and behave identically;
  `checkSince`/`checkUntil` prepend a short re-harvest note to a
  contradiction message when it's absent (absence of the field is the
  sole trigger — nothing compares its value). This tool always stamps it
  going forward.

- Intervals are half-open (`lo` inclusive, `hi` exclusive); either bound
  omitted means unbounded in that direction. Omitting both means "every
  harvested version" — ranges never extrapolate past the corpus.
- Only non-empty fact keys (`absent`/`verified`/`mismatch`/`unknown`) are
  emitted per symbol; the four are disjoint and exhaustive over the
  harvested corpus by construction (`compressFacts` in `harvester.nim`
  groups maximal equal-classification runs, so this falls directly out of
  every version having exactly one classification).
- `harvest.abi` pins the manifest to one OS + data-model class
  (`linux-lp64`, `windows-llp64`, ...) — a manifest is only valid for
  that ABI class. Multi-platform bindings commit one manifest per ABI
  class (e.g. `z3.linux-lp64.compat.json`).
- `symbols` facts are namespaced under `"header"` deliberately — this is
  what Stage B can attest (a symbol *declared* in a version's header),
  not a binary/`.so`-symbol-table fact. The schema reserves sibling
  `binary`/`types` namespaces for future out-of-band tooling.
- Full normative schema: RFC-0001 §4 "B.3 Manifest".

### CLI usage

```
softlink_harvest <dumpFile> <corpusDir> [options]
```

1. Generate the probe-facts dump (a one-shot, dedicated compile — not
   something to leave on in normal builds). `-d:softlinkDumpProbes`
   requires an ABSOLUTE directory: the dump write shells out via
   `staticExec`, whose working directory Nim ties to the Nim file
   containing the macro call, not to your shell's cwd, so a relative
   path here silently resolves to the wrong place (a hard compile-time
   error catches it either way):

   ```sh
   nim c --compileOnly -d:softlinkDumpProbes=$PWD/probes path/to/your_binding.nim
   ```

   This writes `probes/<Base>.probes.json`, where `<Base>` is the same
   identifier your `dynlib "..."` block derives (e.g. `dynlib "z3"` →
   `Z3.probes.json`).

2. Run the harvester against your header corpus:

   ```sh
   softlink_harvest probes/Z3.probes.json corpus/ --out:z3.compat.json
   ```

Flags:

| flag | default | meaning |
|---|---|---|
| `--out:<path>` | `<lib>.compat.json` next to `<dumpFile>` | manifest output path |
| `--fast-path` | off | try a define-free whole-module compile per version first ([Fast path](#fast-path)) |
| `--support-range:<lo>..<hi>` | entire corpus | narrow the drift alarm's window; either bound omissible |
| `--nim-path:<p>` (repeatable) | *none* | extra `--path:` entries for probe compiles — see [below](#package-layout--local-dependency-resolution) for why the default is empty, not `src` |
| `--extra-flag:<f>` (repeatable) | `--passC:-Werror=implicit-function-declaration`, `--passC:-Werror=incompatible-pointer-types` | extra raw `nim c` flag for every probe compile; **appends** to the defaults unless `--no-default-flags` is also given. The harvest-reserved defines (`softlinkStrictVerify`, `softlinkProbeGroundTruth`, `softlinkHarvestSession`, `softlinkProbeOnly`, `softlinkProbeExistence`) cannot be set this way — any spelling of `-d`/`--define` naming one of them, under the same case/underscore-insensitive switch and identifier rules the real `nim` CLI itself accepts (e.g. `-D:`, `--Define=`, `--de_fine:softlink_probe_ground_truth=false`), is refused with a hard error (exit 3); they are harvest-session invariants the harvester itself controls on every probe compile |
| `--no-default-flags` | off | drop the built-in default extra flags; only explicit `--extra-flag` values (if any) apply |
| `--include-prefix:<p>` | `-I` | include-dir flag spelling for the target C toolchain (`/I` for MSVC) |
| `--help` | — | usage text, exit 0 |

`--nim-path` defaults to **empty**, not the `@["src"]` this repo's own dev
loop uses internally: a real binding module resolves `import softlink`
(and its own other imports) through its *own* nimble project's already-
installed packages, exactly like any other compile of that module — no
extra `--path:` needed. The flag exists for genuine edge cases (a vendored
or unusual layout), not as a required default. If you're pointing
`softlink_harvest` at a binding module inside an *uninstalled* local
checkout (e.g. developing the binding itself before it's ever been
`nimble install`ed anywhere), pass `--nim-path:src` (or wherever that
checkout's sources live) explicitly.

### Package layout / local dependency resolution

`softlink_harvest` is a **separate nimble package**
(`tools/harvest/softlink_harvest.nimble`, `requires "softlink >= 0.7.0"`,
`bin = @["softlink_harvest"]`) — not a `bin` section on the parent
`softlink` package. Adding `bin` there would make every downstream
*library* consumer's `nimble install softlink` also build this CLI,
coupling unrelated installs to tool compiles. Shared logic
(`FactKind`/`VersionInterval`/`SymbolFacts`, the version comparator) lives
in the public `softlink/versions` submodule instead, so no private
internals need exporting as a packaging side effect.

**Real (published) install** — completely ordinary nimble dependency
resolution, no special handling:

```sh
nimble install softlink_harvest   # transitively installs softlink too
```

**Building this package *inside the softlink monorepo itself*** (this
repo's own CI, or a contributor iterating on both packages together) is a
different problem: `requires "softlink >= 0.7.0"` would otherwise resolve
against nimble's package registry, ignoring any local, uncommitted edits
to `../../src`. This repo ships the fix: a committed
`tools/harvest/nimble.develop` —

```json
{ "version": 1, "includes": [], "dependencies": ["../.."] }
```

— nimble's own mechanism for "resolve this `requires` against a local
checkout by relative path" (the file `nimble develop -a:../.. ` from this
directory produces). With it committed, plain `nimble build`/`nimble
install` from `tools/harvest/` picks up the local `../../src` unconditionally,
reflecting whatever is currently checked out — no extra setup step, no
network fetch of "softlink" from anywhere, verified against this exact
Docker dev image. A contributor cloning a copy of *just* this
subdirectory (outside the monorepo) would delete or repoint this file;
everyone else gets it for free.

### The one-screen happy path

```sh
# 1. Dump probe facts for your binding module. Path after
#    softlinkDumpProbes= must be absolute (see "CLI usage" above).
nim c --compileOnly -d:softlinkDumpProbes=$PWD/probes src/mylib_bindings.nim

# 2. Harvest against your header corpus (see the CI template for how a
#    real corpus gets fetched from upstream on a schedule).
softlink_harvest probes/Mylib.probes.json corpus/ --out:mylib.compat.json

# 3. Commit the manifest.
git add mylib.compat.json

# 4. Attach it in your binding module.
```
```nim
dynlib "mylib":
  compatManifest "mylib.compat.json"
  proc mylib_init(): cint {.cdecl, header: "mylib.h".}
  ...
```

## The B.6 CI template

`ci-template.yaml` in this directory is a **template**, not this repo's
own workflow (`../../.github/workflows/ci.yaml` is that) — it's meant to
be copied into a *binding* repo (as `.github/workflows/harvest.yaml`, or
similar) and filled in at its `TODO(binding)` markers.

Why this needs to exist at all: a committed manifest rots exactly like a
hosted one if nothing regenerates it. The template makes regeneration a
stated, scheduled CI job rather than something someone has to remember:

1. **Triggers**: `schedule:` (cron) + `workflow_dispatch:`, plus a
   commented sketch of triggering on upstream tag detection instead of a
   bare schedule.
2. **Steps**: checkout → install Nim → `nimble install softlink_harvest`
   (an ordinary, already-published dependency at this point — no local-
   path handling needed, that's only for building *inside* this monorepo)
   → run the binding's own fetch script (a `TODO(binding)` placeholder —
   this repo doesn't know your upstream's tag scheme or header layout) →
   generate the B.1 probe-facts dump → run `softlink_harvest`, whose exit
   codes are what actually fail the job (drift alarm = 1, calibration
   refusal = 2) → `git diff --exit-code <manifest>` against the freshly
   regenerated manifest, so **silent drift also fails the job** — a
   harvest that exits 0 can still have produced a manifest that differs
   from the committed one (a new corpus version, a symbol newly gone
   `absent`, changed toolchain provenance, ...) — → a commented, optional
   PR-creation step for turning an expected drift into a reviewable change
   instead of just a red job.
3. **Supply-chain note** (also a comment in the file itself, verbatim from
   RFC-0001's own principle 4): this job fetches and compiles upstream
   content on a schedule; it runs in the *binding's* CI, never on a
   consumer machine — installing the binding never triggers any of this.

Validation: this project's Docker dev image has no `pip`/PyYAML/yamllint
available (confirmed — no network-installable Python YAML parser in this
image), so the template was validated by careful manual review (structure,
indentation, step ordering) plus a scripted no-tab/indentation sanity
pass, rather than an automated YAML-schema check. It mirrors this repo's
own `../../.github/workflows/ci.yaml` step conventions (same Nim-install
recipe) for anyone comparing the two.

## Consumer side: `compatManifest`

*(Already shipped — this section is about what a binding author does
with a manifest once it exists, not a Stage B deliverable itself.)*

Attach a manifest to a `dynlib`/`verifyProcs` block with a body directive
(not a macro parameter — a defaulted positional parameter was tried and
verified, by compilation, to break every existing `dynlib "x": ...` call
via Nim's trailing-block sugar):

```nim
dynlib "z3":
  compatManifest "z3.compat.json"
  proc Z3_get_full_version(): cstring {.cdecl, header: "z3.h".}
  ...
```

At most one `compatManifest` per block, any position. The path is a
string literal resolved **relative to the module containing the block**
(so a binding package ships its manifest alongside its module — zero
configuration for downstream consumers). `verifyProcs` accepts the same
directive (minus the `refuse` parameter, which it rejects outright — see
below) but has no library identity to check, no loaded pointers, and no
runtime footprint to refuse.

`compatManifest` also accepts an optional `refuse = true/false` named
argument on `dynlib` blocks (`compatManifest("z3.compat.json", refuse = false)`),
scoping the per-block drift-refusal escape hatch: with a `versionProbe`
also on the block, `refuse = false` disables drift refusal — no symbol is
ever refused; the recorded `mismatch` still surfaces at compile time
(above): a warning when no declared bound explains it, a hint when it is
bound-covered.
See the runtime half of this feature —
`versionProbe`, `fooCompat()`/`CompatReport`, and drift refusal itself —
in the main **[README](../../README.md#runtime-versionprobe-foocompat-and-drift-refusal)**.

With a manifest attached, at compile time:

- **`{.since: "x.y.z".}` contradiction is a hard error, no escape hatch.**
  If a proc claims `{.since: "1.2.0".}` but the manifest's own facts say
  otherwise, compilation fails. For a decisive contradiction — the header
  is `absent`, `verified`, or `mismatch` on the wrong side of the claimed
  bound — the message includes the corrected bound: this is a factual
  claim in source, and the fix is a one-line annotation edit. There is one
  exception: an `unknown` fact below the claimed bound (the harvester
  never decisively classified that version, so it can't confirm the
  symbol was actually absent there — the symmetric twin, below `since`, of
  `checkUntil` rule (b′), the decisiveness sub-case described below, at or
  above `until`) is *also* a hard error, but has no meaningful corrected
  bound to report — an unclassified version
  proves nothing about where the real bound should be. Its message instead
  names the unclassified version and says to re-harvest it, drop it from
  the corpus, or adjust the bound.
- **`{.until: "x.y.z".}` cross-check (`checkUntil`) is likewise a hard
  error, no escape hatch** — but it is *not* a mechanical mirror of the
  `since` check; it enforces three distinct rules, spelled out
  [below](#checkuntil-validating-a-declared-until-against-the-corpus).
- **Schema/lib/ABI checks.** An unsupported (newer) manifest schema is a
  compile error naming the softlink version required. A manifest whose
  `lib` doesn't match this block's own library name is an error (wrong-
  file paste protection in multi-library projects). A manifest harvested
  for a different ABI class (OS + data model) than this build's target
  **degrades to no-manifest behavior** with a warning — a manifest
  asserting confidence across the wrong platform would be worse than none.
- **Disjoint/exhaustive validation.** Every symbol/version pair must land
  in exactly one of the four fact buckets; a hand-merge that leaves a gap
  or an overlap is a compile error naming the symbol and version.
- **Mismatch warning.** A bound symbol with a recorded `mismatch`
  interval that no declared bound explains gets a compile-time warning
  pointing at `softlink harvest`/the drift alarm. A mismatch fully
  covered by a declared `{.until.}` bound (every mismatch interval at or
  above the bound — the RFC-0002 blessed path, already validated by the
  until-contradiction check) is downgraded to a "bound-covered mismatch"
  hint instead, escalated back to a warning under
  `-d:softlinkStrictVerify` for harvest audits — expected drift must not
  cry wolf on every consumer build.
- **Not-in-manifest hint.** Bound symbols absent from the manifest
  entirely produce a hint ("N symbols not in compat manifest — regenerate
  with softlink harvest") — a stale manifest stays visible instead of
  silently permissive.
- **Degraded-verification-tier warning.** If *this* compile's own
  verification tier fell back to the no-op MSVC default mode, you get a
  warning distinguishing "the manifest is green" from "this particular
  compile checked nothing" — the two facts must never blur together.
- **Compile-time interval embedding.** The per-symbol fact table is
  embedded as `softlinkCompatFacts<Base>: seq[SymbolFacts]` (the same
  pinned `softlink/versions` types the harvester uses), for future
  load-time use.

### `checkUntil`: validating a declared `until` against the corpus

`{.until: "x.y.z".}` (RFC-0002) claims a symbol's declared signature is
valid over the half-open window `[since, until)` — or `(-∞, until)` when no
`since` is declared. With a manifest attached, `checkUntil` holds that claim
against the harvested facts. Three rules plus a decisiveness sub-case,
checked in order, first violation is a compile error:

- **(a) Over-claim — the dangerous direction.** Any corpus version *inside*
  the declared-valid window with a `mismatch` fact is a hard error: you
  present the window as verified-correct, but the corpus shows the
  signature already drifted there. When `since` is also declared, an
  `absent` fact inside the window errors too. When `since` is *absent*,
  only `mismatch` counts — absence below an undeclared introduction point
  is `since`'s business, and a symbol introduced late in the corpus with
  only an `until` must not spuriously flag the versions predating it. The
  error message includes the corrected bound when the corpus can supply
  one: it scans backward through the trailing run of `mismatch` versions
  and reports `the corrected upper bound is until: "<first drifted
  version>"` (exclusive bound, so setting it there excludes every drifted
  version).
- **(b) Revert detection.** At or above `until` (the window is half-open —
  a fact *at* `until` is already outside it), the corpus must show **no
  `verified` fact**: a re-verified signature above the bound means the
  symbol drifted and then *reverted*, which the single-interval
  `[since, until)` model cannot express — the error says to drop `until`
  for that symbol and fall back to unbounded verification. If the corpus
  never reaches `until` at all (bound beyond the corpus's max harvested
  version), this rule passes **vacuously** — harmless by construction: an
  attested probe is by definition ≤ corpus max < `until`, and the region
  at or above `until` is covered by declared-bound refusal at runtime,
  which doesn't lean on corpus confirmation.
- **(b′) Non-decisive fact, at or above `until`.** A corpus version at or
  above `until` recorded as `unknown` (the harvester couldn't classify it)
  is *also* a hard error, for the same reason as (b): it is neither
  confirmation the signature drifted (`mismatch`) nor that the symbol was
  dropped (`absent`, expected per the `until` demotion) nor a contradiction
  (`verified`) — it is simply undecided, which means the corpus never
  actually confirmed the declared-invalid window holds at that version. A
  runtime probe that happens to land exactly there gets none of the
  runtime-side protection this bound is supposed to buy: the error names
  the unclassified version and says to re-harvest it, drop it from the
  corpus, or adjust the bound.
- **(c) Positive evidence.** At least one corpus version strictly below
  `until` (inside the window when `since` is present) must carry a
  `verified` fact. Without one the declaration is
  unfalsifiable-in-practice — a symbol `absent` across the entire corpus
  could carry an arbitrary `until` and pass (a) and (b) trivially. The
  error names the fix: extend the corpus below `until`, or drop the bound.

**Troubleshooting: a wave of unrelated `until` failures.** If a harvest
baseline build fails at the corpus's *newest* version, every symbol comes
back `unknown` there (the harvester couldn't classify anything against a
baseline that doesn't compile) — and rule (b′) then hard-errors on *every*
`until`-bearing proc whose bound sits at or below that version, all citing
"no decisive classification" at the same version. It looks like an
unrelated wave of breakage but traces to one bad harvest point. Fix it one
of three ways: re-harvest that version (repair the baseline build), drop
that version from the corpus, or — legitimate when the tip is genuinely
unclassifiable — declare `until` strictly beyond the corpus max, which
passes rule (b)/(b′) vacuously by construction (the region is then covered
by declared-bound refusal at runtime, not corpus confirmation).

Corpus granularity is tolerated the same way the `since` check tolerates
it: a corpus that jumps 4.15.0 → 4.17.0 with `until: "4.16.0"` declared in
the gap passes — the rules compare by version order, not exact membership.
A symbol entirely absent from the manifest is not checked at all (it counts
toward the not-in-manifest hint instead). No new manifest field is involved:
`checkUntil` consumes the same `verified`/`absent`/`mismatch` facts the
schema above already records, and the schema stays at version 1.

Everything above is compile-time-only: attaching a manifest, by itself,
changes what the compiler checks and warns about, not what `loadFoo()`
does at runtime. Runtime version probing (`versionProbe:`), the generated
`fooCompat()`/`CompatReport` load-time attestation, and drift *refusal*
(re-nilling or failing a load whose live version falls in a `mismatch`
range) are RFC-0001 Stage C — shipped, but a separate opt-in on top of
this one (a block needs its own `versionProbe` for any of it to engage;
see the README section linked above). Without a `compatManifest`
directive at all, behavior is unchanged (purely additive).
