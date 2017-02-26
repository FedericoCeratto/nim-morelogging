#
# Morelogging logging library - Functional testing
#
# (c) 2017 Federico Ceratto <federico.ceratto@gmail.com>
# Released under the LGPLv3 license, see LICENSE file

# Test plan: build plain / async / threaded demo applications
# Run them, check the generated logs

import times, os
import asyncdispatch,
  osproc,
  strutils,
  unittest

import testutils

suite "functional tests - threading - performance tests":

  createDir "tmpdir"

  test "many writes":

    render_code("tmpdir/tmp.nim"):
      let log = newThreadFileLogger(
        filename_tpl = "tmpdir/test.log",
        fmtStr = "$levelname ",
        writeout_interval_ms=10,
      )
      let t0 = epochTime()
      for x in 1..2:
        for y in 1..20:
          for z in 1..200000:
            log.info(" info 123")
          os.sleep(1)
        os.sleep(10)
      os.sleep(11)
      log.close()
      echo "    Run time: " & $(epochTime() - t0)

    cleanup_compile_and_run("--threads:on")

    check count_newlines("tmpdir/test.log") == 8000000
