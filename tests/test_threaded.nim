#
# Morelogging logging library - Functional testing
#
# (c) 2017 Federico Ceratto <federico.ceratto@gmail.com>
# Released under the LGPLv3 license, see LICENSE file

# Test plan: build plain / async / threaded demo applications
# Run them, check the generated logs

import asyncdispatch,
  os,
  strutils,
  unittest

import testutils

suite "functional tests - threading":

  createDir "tmpdir"

  test "simple":

    render_code("tmpdir/tmp.nim"):
      let log = newThreadFileLogger(
        filename_tpl = "tmpdir/test.log",
        fmtStr = "$levelname ",
        writeout_interval_ms=10,
      )
      log.debug("debug")
      log.info("info")
      log.warn("warn")
      log.error("error")
      log.fatal("fatal")
      os.sleep(11)
      log.debug("debug")
      log.info("info")
      log.warn("warn")
      log.error("error")
      log.fatal("fatal")
      os.sleep(11)

    cleanup_compile_and_run("--threads:on")
    let l = "tmpdir/test.log".readFile().splitLines()
    check l[0].endswith("DEBUG debug")
    check l[1].endswith("INFO info")
    check l[2].endswith("WARN warn")
    check l[3].endswith("ERROR error")
    check l[4].endswith("FATAL fatal")
    check l.len == 11

  test "ThreadRotatingFileLogger filename creation":

    render_code("tmpdir/tmp.nim"):
      let log = newThreadRotatingFileLogger(
        rotate_interval="5s",
        filename_tpl = "tmpdir/$appname.log",
        compress = false
      )

    cleanup_compile_and_run("--threads:on")
    check fileExists("tmpdir/tmp.log")

  test "rotation":

    render_code("tmpdir/tmp.nim"):
      # align to 500ms inside a second
      let delta = epochTime() - epochTime().int.float
      var sleeptime_ms = int((1.5 - delta) * 1000) mod 1000
      os.sleep(sleeptime_ms)

      let t0 = epochTime()
      let log = newThreadRotatingFileLogger(
        compress = false,
        filename_tpl = "tmpdir/test.log",
        rotate_interval="1s",
        writeout_interval_ms=100
      )
      log.error("log.2 file")
      # Wait for 1s to allow rotation
      os.sleep(1000)
      log.error("log.1 file")
      os.sleep(1000)
      log.close()
      echo "    Run time: " & $(epochTime() - t0)

    cleanup_compile_and_run("--threads:on")
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

      let log = newThreadRotatingFileLogger(
        compress = true,
        filename_tpl = "tmpdir/test.log",
        fmtStr = "$levelname ",
        rotate_interval="1s",
        writeout_interval_ms=100,
      )
      log.error("first file")
      os.sleep(1000)
      log.error("second file")
      os.sleep(1000)
      log.error("third file")
      os.sleep(1000)
      log.close()

    cleanup_compile_and_run("--threads:on")
    let l = "tmpdir/test.log".readFile().splitLines()
    check getFileSize("tmpdir/test.log") == 0
    check getFileSize("tmpdir/test.log.1.gz") > 0
    check getFileSize("tmpdir/test.log.2.gz") > 0
    # FIXME log.gz
    check getFileSize("tmpdir/test.log.gz") > 0
