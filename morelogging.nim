#
# Morelogging logging library
#
# (c) 2017 Federico Ceratto <federico.ceratto@gmail.com>
# Released under the LGPLv3 license, see LICENSE file

## Messages with level below level_threshold are ignored.
## If buffer_size is positive, messages are buffered internally up to writeout_interval_ms
## Messages with level >= flush_threshold are flushed out immediately.

from logging import addHandler, Level, LevelNames, Logger, defaultFilename, defaultFmtStr
from logging import info, debug
from posix import gethostname
import asyncdispatch,
  memfiles,
  os,
  strutils,
  times,
  zip.zlib

# Base class

type
  FileLogger* = ref object of Logger
    application_name*, application_dir*: string
    filemode: FileMode
    flush_threshold: Level
    # log_filename is generated from log_filename_tpl
    log_filename, log_filename_tpl*: string
    writeout_interval_ms*: int
    buffering_enabled: bool

# Logging utility functions

proc format_msg(l: FileLogger, frmt: string, level: Level, args: varargs[string, `$`]): string =
  ## Format log message
  ## The following formatters are supported:
  ##
  ## date
  ## time
  ## datetime
  ## app
  ## appdir
  ## appname
  ## levelid
  ## levelname
  ##
  var msgLen = 0
  for arg in args:
    msgLen += arg.len
  result = newStringOfCap(frmt.len + msgLen + 20)
  var i = 0
  while i < frmt.len:
    if frmt[i] != '$':
      result.add(frmt[i])
      inc(i)
    else:
      inc(i)
      var v = ""
      while frmt[i] in IdentChars:
        v.add(frmt[i])
        inc(i)
      # TODO: configurable datetime, support milliseconds
      case v
      of "date": result.add(getDateStr())
      of "time": result.add(getClockStr())
      of "datetime": result.add(getDateStr() & "T" & getClockStr())
      of "appdir": result.add(l.application_dir)
      of "appname": result.add(l.application_name)
      of "levelid": result.add(LevelNames[level][0])
      of "levelname": result.add(LevelNames[level])
      else: discard
  for arg in args:
    result.add(arg)


proc get_hostname(): string =
  ## Get hostname
  when defined(Posix):
    const size = 64
    var s = cstring(newString(size))
    discard s.getHostname(size)
    return $s
  else:
    # FIXME
    return "unknown"


proc generate_log_file_name(tpl: string, current_time: Time): string =
  ## Generate log file name dynamically.
  ## The following formatters are supported:
  ##
  ## $y         year
  ## $MM        month
  ## $dd        day
  ## $hh        hour
  ## $mm        minute
  ## $ss        second
  ## $hostname  hostname
  ## $appname   application name
  ##
  let ts = current_time.getGMTime()
  let appname = os.getAppFilename().splitFile()[1]
  result = tpl
    .replace("$y", ts.format("yyyy"))
    .replace("$MM", ts.format("MM"))
    .replace("$dd", ts.format("dd"))
    .replace("$hh", ts.format("HH"))
    .replace("$mm", ts.format("mm"))
    .replace("$ss", ts.format("ss"))
    .replace("$hostname", get_hostname())
    .replace("$appname", appname)


# AsyncFileLogger

type
  AsyncFileLogger* = ref object of FileLogger
    f: File
    buf: string

proc flush_buffer(self: AsyncFileLogger) =
  ## Write log messages
  if self.buf.len != 0:
    self.f.write(self.buf)
    self.buf.setLen(0)

proc run_writeout_worker(self: AsyncFileLogger) {.async.} =
  ## Write log messages
  while true:
    self.flush_buffer()
    await sleepAsync(self.writeout_interval_ms)

proc newAsyncFileLogger*(
    filename_tpl = "$app.$y$MM$dd.log",
    flush_threshold = lvlError,
    fmtStr = "$datetime $levelname ",
    level_threshold = lvlAll,
    mode: FileMode = fmAppend,
    writeout_interval_ms = 100,
    buffer_size = 1_048_576
  ): AsyncFileLogger =
  ## Creates a new file logger.
  new(result)
  assert writeout_interval_ms > 0
  assert buffer_size >= 0
  result.flush_threshold = flush_threshold
  result.fmtStr = fmtStr
  result.level_threshold = level_threshold
  if buffer_size != 0:
    result.buf = newStringOfCap(buffer_size)
  result.buffering_enabled = (buffer_size != 0)
  result.writeout_interval_ms = writeout_interval_ms
  (result.application_dir, result.application_name) = os.getAppFilename().splitFile()

  result.log_filename_tpl = filename_tpl
  result.log_filename = generate_log_file_name(result.log_filename_tpl, getTime())
  result.f = open(result.log_filename, mode, bufSize=0)

  if result.buffering_enabled:
    let writeout_worker = result.run_writeout_worker()


proc log(self: AsyncFileLogger, level: Level, args: varargs[string, `$`]) {.
            raises: [Exception],
            tags: [TimeEffect, WriteIOEffect, ReadIOEffect].} =
    if level >= self.level_threshold:
      let msg = self.format_msg(self.fmtStr, level, args)
      if self.buffering_enabled:
        self.buf.add (msg & "\n")
        if level >= self.flush_threshold:
          self.flush_buffer()
      else:
        self.f.write(msg & "\n")

method fatal*(self: AsyncFileLogger, args: varargs[string, `$`])
    {.tags: [TimeEffect, WriteIOEffect, ReadIOEffect].} =
  self.log(lvlFatal, args)

method error*(self: AsyncFileLogger, args: varargs[string, `$`])
    {.tags: [TimeEffect, WriteIOEffect, ReadIOEffect].} =
  self.log(lvlError, args)

method warn*(self: AsyncFileLogger, args: varargs[string, `$`])
    {.tags: [TimeEffect, WriteIOEffect, ReadIOEffect].} =
  self.log(lvlWarn, args)

method notice*(self: AsyncFileLogger, args: varargs[string, `$`])
    {.tags: [TimeEffect, WriteIOEffect, ReadIOEffect].} =
  self.log(lvlNotice, args)

method info*(self: AsyncFileLogger, args: varargs[string, `$`])
    {.tags: [TimeEffect, WriteIOEffect, ReadIOEffect].} =
  self.log(lvlInfo, args)

method debug*(self: AsyncFileLogger, args: varargs[string, `$`])
    {.tags: [TimeEffect, WriteIOEffect, ReadIOEffect].} =
  self.log(lvlDebug, args)


# File rotation functions

proc recursive_rename(fname: string, max_renames=14) =
  ## Rename logfiles:
  ##   <fname> to <fname>.1 or
  ##   <fname>.<num> to <fname>.<num+1>
  ##   <fname>.<num>.gz to <fname>.<num+1>.gz
  ## Files are renamed up to max_renames

  if not existsFile(fname):
    return

  var
    num = 0
    dst_fname: string

  let tokens = fname.split('.')
  if fname.endswith(".gz"):
    try:
      num = tokens[tokens.len-2].parseInt
      # matched <basename>.<num>.gz
      let basename = tokens[0..<tokens.len-2].join(".")
      dst_fname = "$#.$#.gz" % [basename, $(num + 1)]

    except:
      # matched <basename>.gz
      dst_fname = "$#.1.gz" % fname[0..<fname.len-3]

  else:
    try:
      num = tokens[tokens.len-1].parseInt
      # matched <basename>.<num>
      let basename = tokens[0..<tokens.len-1].join(".")
      dst_fname = "$#.$#" % [basename, $(num + 1)]

    except:
      # matched <basename>
      dst_fname = fname & ".1"

  if max_renames > 0:
    recursive_rename(dst_fname, max_renames - 1)

  moveFile(fname, dst_fname)

proc compress_file(src_fname: string) =
  ## Compress file to a .gz file, recursively rename previous files
  let t0 = epochTime()
  let compressed_fname = "$#.gz" % src_fname
  recursive_rename(compressed_fname)
  let src = memfiles.open(src_fname)
  let dst = gzopen(compressed_fname, "w")
  discard zlib.gzwrite(dst, src.mem, src.size)
  discard dst.gzclose()
  removeFile(src_fname)
  let ms = (epochTime() - t0) * 1000

proc pick_rotation_time(now: Time, rotateInterval: string): TimeInfo =
  ## Pick a time for the next file rotation
  var
    selector: char
    timeval: int

  try:
    selector = rotateInterval[rotateInterval.len - 1]
    timeval = rotateInterval[0..<rotateInterval.len-1].parseInt
  except:
    raise newException(ValueError, "rotateInterval must be <numbers>[dhms]")

  var rotation_time = now.getGMTime()
  case selector
  of 'd':
    rotation_time.monthday += (timeval - rotation_time.monthday mod timeval)
    rotation_time.hour = 0
    rotation_time.minute = 0
    rotation_time.second = 0
  of 'h':
    rotation_time.hour += (timeval - rotation_time.hour mod timeval)
    rotation_time.minute = 0
    rotation_time.second = 0
  of 'm':
    rotation_time.minute += (timeval - rotation_time.minute mod timeval)
    rotation_time.second = 0
  of 's':
    rotation_time.second += (timeval - rotation_time.second mod timeval)
  else:
    raise newException(ValueError, "rotateInterval must be <numbers>[Mdhms]")

  return rotation_time


# AsyncRotatingFileLogger

type
  AsyncRotatingFileLogger* = ref object of AsyncFileLogger
    compress: bool
    next_rotation_time: TimeInfo
    rotateInterval: string

proc rotate(self: AsyncRotatingFileLogger, now: Time) =
  ## Rotate logfile, compressing it if needed
  self.next_rotation_time = pick_rotation_time(now, self.rotateInterval)
  if self.f != nil:
    self.f.close()

  if self.compress and self.log_filename != nil:
    self.log_filename.compress_file()

  self.log_filename = generate_log_file_name(self.log_filename_tpl, now)
  recursive_rename(self.log_filename)
  self.f = open(self.log_filename, self.filemode, bufSize=0)

proc flush_buffer(self: AsyncRotatingFileLogger) =
  ## Write log messages
  if self.buf.len != 0:
    self.f.write(self.buf)
    self.buf.setLen(0)

proc run_writeout_worker(self: AsyncRotatingFileLogger) {.async.} =
  ## Perform log rotation and write out log messages
  while true:
    let now = getTime()
    if self.next_rotation_time.timeInfoToTime() <= now:
      self.rotate(now)

    if self.buffering_enabled:
      self.flush_buffer()
    await sleepAsync(self.writeout_interval_ms)

proc newAsyncRotatingFileLogger*(
    filename_tpl = "$app.$y$MM$dd.log",
    flush_threshold = lvlError,
    fmtStr = "$datetime $levelname ",
    level_threshold = lvlAll,
    mode: FileMode = fmAppend,
    writeout_interval_ms = 100,
    buffer_size = 1_048_576,
    rotateInterval = "1d",
    compress = false,
  ): AsyncRotatingFileLogger =
  ## Creates a new rotating file logger.
  new(result)
  assert writeout_interval_ms > 0
  if buffer_size != 0:
    result.buf = newStringOfCap(buffer_size)
  result.buffering_enabled = (buffer_size != 0)
  result.compress = compress
  result.filemode = mode
  result.flush_threshold = flush_threshold
  result.fmtStr = fmtStr
  result.level_threshold = level_threshold
  result.log_filename_tpl = filename_tpl
  result.rotateInterval = rotateInterval
  result.writeout_interval_ms = writeout_interval_ms
  (result.application_dir, result.application_name) = os.getAppFilename().splitFile()
  # Perform an initial rotation to open a file
  result.rotate(getTime())
  let writeout_worker = result.run_writeout_worker()
