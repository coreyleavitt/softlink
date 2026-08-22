## RFC 0011 — per-block pattern-override seam: `dynlib`'s generated `loadX`
## resolves its runtime search pattern through a per-block compile-time
## override — `{.strdefine: "softlink.pattern.<IdentBase>".}` — that lets a
## consumer redirect a block's search pattern at build time (a bundled or
## renamed library, or — the motivating consumer case, RFC 0011's oyamel
## GTK4 bindings — a deliberately absent/redirected target for testing
## "library absent" scenarios) WITHOUT touching identifier derivation:
## `loadX`/`unloadX`/`xxxLoaded` names stay keyed on the block's DECLARED
## pattern/identBase always, never on the override.
##
## Every block here binds a permanently-absent library (an explicit,
## non-alternation garbage pattern, `{.noverify.}` procs) — the whole point
## is candidate naming in `LoadResult.attempts`, never a real load
## succeeding, so this fixture needs no built testlib/libmagic artifact and
## runs identically, portably, on every OS leg.
##
## Compiled and run THREE times by the nimble task:
##   - plain (no defines at all): every block's DECLARED pattern is used
##     as-is — story (a), "no define -> real pattern, no behavior change".
##   - `-d:testOverrideA -d:softlink.pattern.PatOverrideA=<garbage>`: only
##     block A's override key is set — proves the override actually
##     redirects loadX's candidate set (story b), and that block B — same
##     DECLARED PATTERN TEXT as A, but a different `identBase` — is
##     completely unaffected (story d).
##   - `-d:testOverrideC -d:softlink.pattern.Patoverridebarexyz=<garbage>`:
##     block C (no explicit `identBase` at all) — proves the override key
##     for a DERIVED-base block is the derived base itself (story c).
##
## `testOverrideA`/`testOverrideC` are this FILE's own private test-only
## defines (unrelated to softlink itself) — mirrors
## `tests/tcompat_drift_required.nim`'s `driftRefusalOverridden` trick:
## fold the ambient define into a plain compile-time bool so one test body
## can assert the correct shape under every invocation.
import std/[unittest, strutils]
import softlink

const overrideAActive = defined(testOverrideA)
const overrideCActive = defined(testOverrideC)

const declaredPatternAB = "libpatoverride_a_declared_xyz.so"
const overrideCandidateA = "libpatoverride_override_target_a.so"
const overrideCandidateC = "libpatoverride_override_target_c.so"

# Block A: explicit identBase — the override target in the second compile.
dynlib declaredPatternAB:
  identBase "PatOverrideA"
  proc patoverride_a_noop() {.cdecl, noverify: "test fixture, never loaded".}

# Block B: the IDENTICAL declared pattern text as block A, but a DIFFERENT
# identBase — legal per the `identBase` directive's own second motivating
# case (two blocks over one library needing distinct load-proc names), and
# exactly the shape story (d) needs: an override keyed on A's identBase
# must never apply here.
dynlib declaredPatternAB:
  identBase "PatOverrideB"
  proc patoverride_b_noop() {.cdecl, noverify: "test fixture, never loaded".}

# Block C: no explicit identBase — derives "Patoverridebarexyz" from the
# bare logical name below (`libNameToIdent`: capitalize-first, no "lib"
# prefix to strip, no dot to truncate at). The third compile's override key
# targets exactly this derived base.
dynlib "patoverridebarexyz":
  proc patoverride_c_noop() {.cdecl, noverify: "test fixture, never loaded".}

suite "per-block pattern-override seam (RFC 0011)":
  test "block A: declared pattern verbatim with no override; override redirects candidates when active":
    let r = loadPatOverrideA()
    check r.kind == lrLibNotFound
    check r.attempts.len == 1
    if overrideAActive:
      check r.attempts[0].candidate == overrideCandidateA
    else:
      check r.attempts[0].candidate == declaredPatternAB
    # Identifiers are unaffected by the override either way — the whole
    # point of keying the override on identBase rather than folding it into
    # pattern derivation.
    check not patoverrideaLoaded()
    check compiles(unloadPatOverrideA())

  test "block B: identical declared pattern text as A, different identBase — A's override never applies here (story d)":
    let r = loadPatOverrideB()
    check r.kind == lrLibNotFound
    check r.attempts.len == 1
    check r.attempts[0].candidate == declaredPatternAB
    if overrideAActive:
      check r.attempts[0].candidate != overrideCandidateA
    check not patoverridebLoaded()

  test "block C: derived-base block (no explicit identBase) — override, when active, is keyed on the DERIVED base (story c)":
    let r = loadPatoverridebarexyz()
    check r.kind == lrLibNotFound
    check r.attempts.len >= 1
    if overrideCActive:
      # The override is a bare (non-alternation) explicit pattern — exactly
      # one candidate, regardless of how many `deriveLibPattern` would have
      # expanded the bare logical name into on this platform.
      check r.attempts.len == 1
      check r.attempts[0].candidate == overrideCandidateC
    else:
      # Baseline: `deriveLibPattern`'s OS-specific candidates for the bare
      # name "patoverridebarexyz" are whatever this platform derives (may
      # be several, e.g. version-suffix alternations) — this fixture
      # doesn't hardcode that OS-specific text, only that the override
      # string never appears among them, proving the DECLARED (derived)
      # pattern drove candidate expansion, not the override.
      for a in r.attempts:
        check a.candidate != overrideCandidateC
    check not patoverridebarexyzLoaded()
