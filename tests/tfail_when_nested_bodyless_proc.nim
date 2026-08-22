## RFC 0011 (softlink-authored diagnostic for conditional binding
## declarations), round-2 obligation: the SAME hazard as
## `tfail_when_bodyless_proc.nim`, but the bodyless proc sits inside a
## NESTED `when` — one `when` passing through another, ordinary Nim code
## that carries no special meaning to `dynlib`'s own body scan. The scan
## must recurse into every nesting depth, not just the outermost `when`'s
## immediate branches, or this exact shape would silently slip through as
## legitimate pass-through and fail later with Nim's own opaque
## "implementation expected" instead of naming the real mistake. Run by the
## nimble test task, which expects compilation to fail with the
## conditional-binding error.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "fakewhennested":
  when defined(linux):
    when defined(amd64):
      proc testlib_nested_bodyless(): cint {.cdecl, noverify.}
    else:
      discard
  else:
    discard
