# Package
version       = "0.1.0"
author        = "Corey Leavitt"
description   = "Type-safe optional dynamic library bindings for Nim"
license       = "Apache-2.0"
srcDir        = "src"

# Dependencies
requires "nim >= 2.0.0"

task test, "Run tests":
  exec "nim c -r --path:src tests/test_softlink.nim"
