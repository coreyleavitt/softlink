## RFC-0002 §4.1/§6, slice A2: `since >= until` is a contradiction — an
## empty interval `[since, until)` (nothing is ever "in range"). Compared
## via `cmpVersion` (softlink/versions), never string comparison, so this
## is caught even when the naive string ordering would happen to agree.
## `since == until` is likewise empty (`[x, x)`) and is rejected by the
## same `>=` comparison — verified separately during this slice's TDD
## cycle via an ad hoc compile (not a second committed fixture, following
## this suite's one-error-per-fixture-file precedent: compilation aborts
## at the first macro error, so a second contradictory proc in this same
## file would never be reached).
##
## Run by the nimble test task, which expects compilation to fail with
## "is an empty interval".
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "testlib":
  proc testlib_add(a: cint, b: cint): cint
    {.cdecl, since: "2.0.0", until: "1.0.0", header: "tests/testlib.h".}
