## RFC 0011 (softlink-authored diagnostic for conditional binding
## declarations): the diagnostic's necessary counterpart — a `when` whose
## branches contain only BODIED helper procs (ordinary pass-through code,
## RFC 0011 S0a item 4) must stay untouched, exactly as before this
## diagnostic existed. `--compileOnly` is sufficient (this is a macro-
## expansion-time pin, not a runtime behavior); the real binding declared
## alongside the `when` proves the block as a whole still expands normally.
## Run by the nimble test task via `expectManifestCompileOk`.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "fakewhenpassthrough":
  when defined(linux):
    proc helperLinux(): cint = 42
  else:
    proc helperOther(): cint = 1

  proc testlib_wp_real(): cint {.cdecl, noverify.}
