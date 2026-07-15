## Compile-diagnostic test: a {.noverify: "reason".} proc's justification
## string must be read and folded into the existing unverified-symbols hint
## (RFC-0001 §3 A.2, slice A7) — "The current parser already accepts and
## silently discards the colon form — A7 makes it read the string." A bare
## {.noverify.} proc (no reason) must still show up, with a
## "(no justification)" placeholder (A.2: "Bare {.noverify.} remains legal").
## Run by the nimble test task, which compiles this file and greps the
## compiler output for both the justification text and the placeholder.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "libfoo.so":
  proc foo(x: cint): cint
    {.cdecl, noverify: "private symbol, no public header at any version".}
  proc bar(): cint {.cdecl, optional, noverify.}
