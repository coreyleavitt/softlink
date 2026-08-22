## RFC 0011 (softlink-authored diagnostic for conditional binding
## declarations): a top-level `when` inside a `dynlib` block whose branches
## contain a BODYLESS proc declaration — the shape a user reaches for when
## trying to make a binding conditional on a compile-time flag. Statement
## pass-through (RFC 0011 S0a item 4) treats a `when` as one opaque
## statement to splice through verbatim, so without this diagnostic the
## flat body-scan loop that recognizes bindings never sees either proc here
## at all: neither gets a function-pointer var, a wrapper, or a `loadX`
## resolution slot, and the re-emitted `when` (still containing a bodyless
## proc, exactly as written) fails with Nim's own bare "implementation
## expected" the moment the generated code is compiled — not a softlink
## diagnostic pointing at the real mistake. Run by the nimble test task,
## which expects compilation to fail with the conditional-binding error.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "fakewhenbodyless":
  when defined(linux):
    proc testlib_when_linux(): cint {.cdecl, noverify.}
  else:
    proc testlib_when_other(): cint {.cdecl, noverify.}
