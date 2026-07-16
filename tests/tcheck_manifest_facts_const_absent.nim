## RFC-0001 §B.5/§9, slice B6b: with NO `compatManifest` directive attached
## to a `dynlib` block, no `softlinkCompatFacts<Base>` const is emitted at
## all — not even an empty-seq one (design guidance: an empty-seq const
## would blur "no manifest" with "manifest with zero symbols", so the
## macro simply never declares the identifier in this case). Proven here
## via `declared()`, the same primitive the #14 duplicate-block guard in
## `src/softlink.nim` already relies on for scope-accurate compile-time
## identifier checks.
##
## `{.noverify.}` on `foo`'s only proc keeps this fixture free of any
## `{.header.}`/manifest machinery — the point here is purely "no
## directive means no const," independent of everything else B6a checks.
##
## Run by the nimble test task via `runManifestChecks()`.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "libfoo.so":
  proc foo(x: cint): cint {.cdecl, noverify.}

static:
  doAssert not declared(softlinkCompatFactsFoo)
