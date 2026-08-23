## `requireSoftlink` negative fixture (post-RFC-0011 hardening): a bound
## far above any real release must FAIL the compile with softlink's own
## floor-check message, including the shadowed-copy hint (the check's
## whole reason to exist: a stale copy baked into a toolchain image
## outranking the intended checkout). Asserted via
## `expectManifestCompileFail` in softlink.nimble; the current-version
## needle there is built from `softlinkVersion` so a release bump cannot
## stale it.

import softlink

requireSoftlink "9999.0"
