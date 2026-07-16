# Package
version       = "0.1.0"
author        = "Corey Leavitt"
description   = "CLI: harvest a versioned C header corpus into a softlink compat manifest (RFC-0001 Stage B)"
license       = "Apache-2.0"
srcDir        = "."
bin           = @["softlink_harvest"]

# Dependencies
requires "nim >= 2.0.0"
# RFC-0001 SS4 B.2 packaging note: a SEPARATE nimble package (own .nimble in
# tools/, requires "softlink") rather than a `bin` section on the parent
# softlink package — adding `bin` there would make every downstream LIBRARY
# consumer's `nimble install softlink` also build this CLI, coupling
# unrelated installs to tool compiles. See tools/harvest/README.md's
# "Package layout" section for the real-user vs. this-repo's-own-CI
# dependency-resolution story (a real, published install resolves this
# ordinarily; building this package IN PLACE inside a softlink checkout
# needs `nimble develop` run once at the repo root — see that section).
requires "softlink >= 0.7.0"
