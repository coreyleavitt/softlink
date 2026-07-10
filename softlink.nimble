# Package
version       = "0.5.0"
author        = "Corey Leavitt"
description   = "Type-safe optional dynamic library bindings for Nim"
license       = "Apache-2.0"
srcDir        = "src"

# Dependencies
requires "nim >= 2.0.0"

task test, "Run tests":
  # testlib.c is compiled under several names to exercise deriveLibPattern:
  #   libtestlib.*  — explicit-pattern block (verbatim escape hatch)
  #   libmagic.*    — bare logical name "magic" resolves here
  #   libvern.so.3  — runtime-only versioned soname (Linux; no bare symlink)
  when defined(windows):
    exec "gcc -shared -o tests/testlib.dll tests/testlib.c"
    exec "gcc -shared -o tests/libmagic.dll tests/testlib.c"
    exec "nim c -r --path:src --passC:-I. tests/test_softlink.nim"
    # Regression matrix for #12: cpp backend must also pass.
    exec "nim cpp -r --path:src --passC:-I. tests/test_softlink.nim"
  elif defined(macosx):
    exec "cc -shared -fPIC -o tests/libtestlib.dylib tests/testlib.c"
    exec "cc -shared -fPIC -o tests/libmagic.dylib tests/testlib.c"
    exec "nim c -r --path:src --passC:-I. tests/test_softlink.nim"
    exec "nim cpp -r --path:src --passC:-I. tests/test_softlink.nim"
  else:
    exec "gcc -shared -fPIC -o tests/libtestlib.so tests/testlib.c"
    exec "gcc -shared -fPIC -o tests/libmagic.so tests/testlib.c"
    # Versioned soname with NO bare libvern.so — forces the major fallback.
    exec "gcc -shared -fPIC -o tests/libvern.so.3 tests/testlib.c"
    exec "LD_LIBRARY_PATH=./tests nim c -r --path:src --passC:-I. tests/test_softlink.nim"
    exec "LD_LIBRARY_PATH=./tests nim cpp -r --path:src --passC:-I. tests/test_softlink.nim"
