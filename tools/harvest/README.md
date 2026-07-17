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

### Classification table

For each `(version, symbol)` pair, up to three real `nim c --noLinking`
compiles run, each with the corpus version's headers shadowing any
system-installed copy (`-I <corpusDir>/<version>` prepended) plus
`-Werror=implicit-function-declaration` (an absent symbol must be a hard
compile error, never a warning a lenient toolchain shrugs off):

| baseline (`ProbeOnly=-`) | existence probe | verify (full assert) | classification |
|---|---|---|---|
| fail | — | — | `unknown` — this version's headers are broken/missing for this module |
| ok | fail | — | `absent` — the header doesn't declare the symbol at all |
| ok | ok | ok | `verified` — the pinned Nim signature matches |
| ok | ok | fail, softlink's own assert text present | `mismatch` — a real signature drift |
| ok | ok | fail, softlink's assert text ABSENT | `unknown` — some other compile failure, not evidence of a signature mismatch |

Every step is structural (compiles either succeed or fail) — the *only*
place any compiler output is textually inspected is confirming softlink's
own fixed `"... signature mismatch vs ..."` assert message appears, and
only as a second opinion on a `verify`-stage failure the pipeline has
already structurally identified.

A proc whose only declaration source is `{.prototype.}` (no `{.header.}`)
verifies against a vendored, corpus-**invariant** declaration — there is
nothing version-shaped to record, so the harvester skips it (visible in
`softlink_harvest`'s report and in each `HarvestResult.skipped`). A
`{.noverify.}` proc has no verification apparatus emitted at all and is
skipped for the identical reason.

### Calibration preflight

Before touching your real corpus, the harvester compiles a small, built-in
known-answer trio (one symbol that should classify `verified`, one
`absent`, one `mismatch`) through the *identical* pipeline. If even one of
the three doesn't come out as expected, the run **aborts with no manifest
written** and a toolchain diagnosis — the structural guard against a
degraded verification tier (default-mode MSVC's no-op `_Generic`/`__typeof__`
fallback silently "verifies" everything, unconditionally) or a
misconfigured toolchain (implicit-declaration-as-warning instead of
error) poisoning a manifest with false `verified` facts. This is exit code
2 (see [below](#drift-alarm-and-exit-codes)).

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
| `2` | **calibration refused** — the toolchain failed the built-in preflight trio; **no manifest was written** |
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
               "abi": "linux-lp64", "date": "2026-07-15" },
  "corpus": [{ "version": "4.15.0", "source": "git:z3prover/z3@<sha>" }],
  "symbols": {
    "Z3_replace_re_all": { "header": { "absent":   [{ "hi": "4.15.8" }],
                                       "verified": [{ "lo": "4.15.8" }] } }
  }
}
```

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
| `--extra-flag:<f>` (repeatable) | `--passC:-Werror=implicit-function-declaration` | extra raw `nim c` flag for every probe compile; **appends** to the default unless `--no-default-flags` is also given |
| `--no-default-flags` | off | drop the built-in default extra flag; only explicit `--extra-flag` values (if any) apply |
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
ever refused; the recorded `mismatch` still warns at compile time (above).
See the runtime half of this feature —
`versionProbe`, `fooCompat()`/`CompatReport`, and drift refusal itself —
in the main **[README](../../README.md#runtime-versionprobe-foocompat-and-drift-refusal)**.

With a manifest attached, at compile time:

- **`{.since: "x.y.z".}` contradiction is a hard error, no escape hatch.**
  If a proc claims `{.since: "1.2.0".}` but the manifest's own facts say
  otherwise, compilation fails with a message that includes the corrected
  bound — this is a factual claim in source, and the fix is a one-line
  annotation edit.
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
- **Mismatch warning.** Any bound symbol with a recorded `mismatch`
  interval anywhere gets a compile-time warning pointing at
  `softlink harvest`/the drift alarm.
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

Everything above is compile-time-only: attaching a manifest, by itself,
changes what the compiler checks and warns about, not what `loadFoo()`
does at runtime. Runtime version probing (`versionProbe:`), the generated
`fooCompat()`/`CompatReport` load-time attestation, and drift *refusal*
(re-nilling or failing a load whose live version falls in a `mismatch`
range) are RFC-0001 Stage C — shipped, but a separate opt-in on top of
this one (a block needs its own `versionProbe` for any of it to engage;
see the README section linked above). Without a `compatManifest`
directive at all, behavior is unchanged (purely additive).
