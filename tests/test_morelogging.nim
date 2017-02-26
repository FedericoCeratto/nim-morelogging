#
# Morelogging logging library - Functional testing
#
# (c) 2017 Federico Ceratto <federico.ceratto@gmail.com>
# Released under the LGPLv3 license, see LICENSE file

# Test plan: build plain / async / threaded demo applications
# Run them, check the generated logs

import times, os
from system import lines

import asyncdispatch,
  osproc,
  strutils,
  unittest

import testutils


suite "functional tests - async":

  createDir "tmpdir"

  test "no buffering":

    render_code("tmpdir/tmp.nim"):
      let log1 = newAsyncFileLogger(
        filename_tpl = "tmpdir/test.log",
        fmtStr = "$levelname ",
        buffer_size = 0,
      )
      log1.debug("debug")
      log1.info("info")
      #TODO: close

    cleanup_compile_and_run()
    let l = "tmpdir/test.log".readFile().splitLines()
    check l[0].endswith("DEBUG debug")
    check l[1].endswith("INFO info")


  test "simple":

    render_code("tmpdir/tmp.nim"):
      let log1 = newAsyncFileLogger(
        filename_tpl = "tmpdir/test.log",
        fmtStr = "$levelname ",
        writeout_interval_ms=10
      )
      log1.debug("debug")
      waitFor sleepAsync(5)
      log1.info("info")
      waitFor sleepAsync(5)
      log1.warn("warn")
      waitFor sleepAsync(5)
      log1.error("error")
      waitFor sleepAsync(5)
      log1.fatal("fatal")
      waitFor sleepAsync(15)

    cleanup_compile_and_run()
    let l = "tmpdir/test.log".readFile().splitLines()
    check l[0].endswith("DEBUG debug")
    check l[1].endswith("INFO info")
    check l[2].endswith("WARN warn")
    check l[3].endswith("ERROR error")
    check l[4].endswith("FATAL fatal")


  test "appname appdir datetime":

    render_code("tmpdir/tmp.nim"):
      let log = newAsyncFileLogger(
        filename_tpl = "tmpdir/test.log",
        fmtStr = "$appname $appdir $datetime $levelid $levelname ",
        writeout_interval_ms=10
      )
      log.info("info")
      waitFor sleepAsync(15)

    cleanup_compile_and_run()
    let l = "tmpdir/test.log".readFile().splitLines()
    check l.len == 2
    check l[1] == ""
    check l[0].endswith(" I INFO info")


  test "performance":

    render_code("tmpdir/tmp.nim"):
      const buftest_lines_num = 5_000_000
      when isMainModule:
        let t0 = epochTime()
        let log = newAsyncFileLogger(
          filename_tpl = "tmpdir/test.log",
          fmtStr = "",
          writeout_interval_ms=100,
        )
        for cnt in 1..buftest_lines_num:
          log.info align($cnt, 15)
        waitFor sleepAsync(150)
        echo "    Run time: " & $(epochTime() - t0)

    cleanup_compile_and_run()
    # check output: expect a sequence of consecutive numbers
    var cnt = 1
    for line in "tmpdir/test.log".lines:
      check parseint(line.strip()) == cnt
      cnt.inc
    check cnt == 5_000_001

  test "AsyncRotatingFileLogger no buffering":

    render_code("tmpdir/tmp.nim"):
      let log = newAsyncRotatingFileLogger(
        buffer_size = 0,
        compress = false,
        filename_tpl = "tmpdir/test.log",
        fmtStr = "$levelname ",
        rotateInterval="5s",
      )
      log.debug("debug")
      log.info("info")

    cleanup_compile_and_run()
    let l = "tmpdir/test.log".readFile().splitLines()
    check l[0].endswith("DEBUG debug")
    check l[1].endswith("INFO info")


  test "AsyncRotatingFileLogger filename creation":

    render_code("tmpdir/tmp.nim"):
      let log = newAsyncRotatingFileLogger(
        rotateInterval="5s",
        filename_tpl = "tmpdir/$appname.log",
        compress = false
      )

    cleanup_compile_and_run()
    check fileExists("tmpdir/tmp.log")

  test "rotation":

    render_code("tmpdir/tmp.nim"):
      # align to 500ms inside a second
      let delta = epochTime() - epochTime().int.float
      var sleeptime_ms = int((1.5 - delta) * 1000) mod 1000
      os.sleep(sleeptime_ms)

      let log = newAsyncRotatingFileLogger(
        compress = false,
        filename_tpl = "tmpdir/test.log",
        rotateInterval="1s",
        writeout_interval_ms=100
      )
      log.error("log.2 file")
      # Wait for 1s to allow rotation
      waitFor sleepAsync(1000)
      log.error("log.1 file")
      waitFor sleepAsync(1000)

    cleanup_compile_and_run()
    let l = "tmpdir/test.log".readFile().splitLines()
    check fileExists("tmpdir/test.log")
    check fileExists("tmpdir/test.log.1")

    check "tmpdir/test.log.2".readFile().endswith("log.2 file\n")
    check "tmpdir/test.log.1".readFile().endswith("log.1 file\n")
    check "tmpdir/test.log".readFile() == ""

  test "rotation and compression":

    render_code("tmpdir/tmp.nim"):
      # align to 500ms inside a second
      let delta = epochTime() - epochTime().int.float
      var sleeptime_ms = int((1.5 - delta) * 1000) mod 1000
      os.sleep(sleeptime_ms)

      let log = newAsyncRotatingFileLogger(
        compress = true,
        filename_tpl = "tmpdir/test.log",
        fmtStr = "$levelname ",
        rotateInterval="1s",
        writeout_interval_ms=100
      )
      log.error("first file")
      waitFor sleepAsync(1000)
      log.error("second file")
      waitFor sleepAsync(1000)
      log.error("third file")
      waitFor sleepAsync(1000)

    cleanup_compile_and_run()
    let l = "tmpdir/test.log".readFile().splitLines()
    check getFileSize("tmpdir/test.log") == 0
    check getFileSize("tmpdir/test.log.1.gz") > 0
    check getFileSize("tmpdir/test.log.2.gz") > 0
    # FIXME log.gz
    check getFileSize("tmpdir/test.log.gz") > 0
