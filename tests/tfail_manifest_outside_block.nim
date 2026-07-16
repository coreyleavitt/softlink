## RFC-0001 §B.5, slice B6a: `compatManifest` is a body directive of
## `dynlib`/`verifyProcs` blocks. Calling it OUTSIDE either block must
## resolve to softlink's exported erroring stub (`{.error.}` pragma) and
## produce a softlink-authored diagnostic — never a bare "undeclared
## identifier" (the #14 lesson, reapplied). Run by the nimble test task,
## which expects compilation to fail with "compatManifest is a body
## directive".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

compatManifest("manifests/testlib.compat.json")
