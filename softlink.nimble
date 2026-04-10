# Package
version       = "0.3.3"
author        = "Corey Leavitt"
description   = "Type-safe optional dynamic library bindings for Nim"
license       = "Apache-2.0"
srcDir        = "src"

# Dependencies
requires "nim >= 2.0.0"

task test, "Run tests":
  when defined(windows):
    exec "gcc -shared -o tests/testlib.dll tests/testlib.c"
    exec "nim c -r --path:src --passC:-I. tests/test_softlink.nim"
  elif defined(macosx):
    exec "cc -shared -fPIC -o tests/libtestlib.dylib tests/testlib.c"
    exec "nim c -r --path:src --passC:-I. tests/test_softlink.nim"
  else:
    exec "gcc -shared -fPIC -o tests/libtestlib.so tests/testlib.c"
    exec "LD_LIBRARY_PATH=./tests nim c -r --path:src --passC:-I. tests/test_softlink.nim"
