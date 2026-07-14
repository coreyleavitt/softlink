## Compile-diagnostic test: a dynlib block containing {.noverify.} procs must
## emit a compile-time hint enumerating the unverified symbols (upgraded to a
## warning under -d:softlinkStrictVerify) so audits can find trust points
## without grepping source. Run by the nimble test task, which compiles this
## file and greps the compiler output for "not header-verified" — plainly and
## with -d:softlinkStrictVerify.
##
## NOT compiled by the regular test suite; see the `nimble test` task.
import softlink

dynlib "libfoo.so":
  proc foo(x: cint): cint {.cdecl, noverify.}
  proc bar(): cint {.cdecl, optional, noverify.}
