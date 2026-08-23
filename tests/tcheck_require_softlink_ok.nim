## `requireSoftlink` positive fixture (post-RFC-0011 hardening): a bound
## equal to the current release and a strictly-lower bound both compile
## clean. Compile-only (`nim c --compileOnly`) via
## `expectManifestCompileOk` in softlink.nimble — the check IS the
## compile succeeding; nothing here runs.
##
## `softlinkVersion` itself is the equal-bound operand so this fixture
## never goes stale on a release bump.

import softlink
import softlink/versions

requireSoftlink softlinkVersion
requireSoftlink "0.1.0"

echo "tcheck_require_softlink_ok: compiled"
