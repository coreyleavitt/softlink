## `requireSoftlink` unparseable-bound fixture (post-RFC-0011 hardening):
## a bound with no digit or letter runs at all cannot be compared under
## the B0 order (`parseVersion` -> none), and silently passing or
## silently failing such a bound would both be wrong — it must FAIL the
## compile with a message naming the bound itself. Asserted via
## `expectManifestCompileFail` in softlink.nimble.

import softlink

requireSoftlink "..."
