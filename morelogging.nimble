# Package

version       = "0.1.0"
author        = "Federico Ceratto"
description   = "Logging helpers"
license       = "LGPLv3"

# Dependencies

requires "nim >= 0.15.0", "zip"


task functional_tests, "Functional tests":
  exec "nim c -p:. tests/test_morelogging.nim"
  exec "nim c -p:. tests/test_threaded.nim"
  exec "./tests/test_morelogging"
  exec "./tests/test_threaded"
