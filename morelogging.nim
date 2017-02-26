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
    buffer_size: int

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
    var hostname = cstring(newString(size))
    let success = getHostname(hostname, size)
    if success != 0.cint or hostname == nil:
      raiseOSError(osLastError())
    return $hostname
  else:
    # FIXME https://github.com/nim-lang/Nim/pull/5443
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

#FIXME: flush immediately if the buffer is filling up

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
  ## Create a file logger.
  new(result)
  assert writeout_interval_ms > 0
  assert buffer_size >= 0
  result.flush_threshold = flush_threshold
  result.fmtStr = fmtStr
  result.level_threshold = level_threshold
  if buffer_size != 0:
    result.buf = newStringOfCap(buffer_size)
  result.buffer_size = buffer_size
  result.writeout_interval_ms = writeout_interval_ms
  (result.application_dir, result.application_name) = os.getAppFilename().splitFile()

  result.log_filename_tpl = filename_tpl
  result.log_filename = generate_log_file_name(result.log_filename_tpl, getTime())
  result.f = open(result.log_filename, mode, bufSize=0)

  if result.buffer_size != 0:
    let writeout_worker = result.run_writeout_worker()

proc log(self: AsyncFileLogger, level: Level, args: varargs[string, `$`]) {.
            raises: [Exception],
            tags: [TimeEffect, WriteIOEffect, ReadIOEffect].} =
  ## Format and write log message out if the level is above theshold,
  ## or buffering is not enabled, otherwise buffer it.
  ## Flush out the buffer if it's getting full
  if level >= self.level_threshold:
    let msg = self.format_msg(self.fmtStr, level, args)
    if self.buffer_size != 0:
      if self.buf.len + msg.len + 1 >= self.buffer_size:
        self.flush_buffer()

      self.buf.add msg
      self.buf.add "\n"
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
  var src: MemFile
  try:
    src = memfiles.open(src_fname)
  except:
    echo "failed to memfiles.open $# $#" % [src_fname, getCurrentExceptionMsg()]
    return

  let dst = gzopen(compressed_fname, "w")
  discard zlib.gzwrite(dst, src.mem, src.size)
  discard dst.gzclose()
  removeFile(src_fname)

proc pick_rotation_time(now: Time, rotate_interval: string): TimeInfo =
  ## Pick a time for the next file rotation
  var
    selector: char
    timeval: int

  try:
    selector = rotate_interval[rotate_interval.len - 1]
    timeval = rotate_interval[0..<rotate_interval.len-1].parseInt
  except:
    raise newException(ValueError, "rotate_interval must be <numbers>[dhms]")

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
    raise newException(ValueError, "rotate_interval must be <numbers>[Mdhms]")

  return rotation_time


# AsyncRotatingFileLogger

type
  AsyncRotatingFileLogger* = ref object of AsyncFileLogger
    compress: bool
    next_rotation_time: TimeInfo
    rotate_interval: string

proc rotate(self: AsyncRotatingFileLogger, now: Time) =
  ## Rotate logfile, compressing it if needed
  self.next_rotation_time = pick_rotation_time(now, self.rotate_interval)
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

    if self.buffer_size != 0:
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
    rotate_interval = "1d",
    compress = false,
  ): AsyncRotatingFileLogger =
  ## Create a rotating file logger.
  new(result)
  assert writeout_interval_ms > 0
  if buffer_size != 0:
    result.buf = newStringOfCap(buffer_size)
  result.buffer_size = buffer_size
  result.compress = compress
  result.filemode = mode
  result.flush_threshold = flush_threshold
  result.fmtStr = fmtStr
  result.level_threshold = level_threshold
  result.log_filename_tpl = filename_tpl
  result.rotate_interval = rotate_interval
  result.writeout_interval_ms = writeout_interval_ms
  (result.application_dir, result.application_name) = os.getAppFilename().splitFile()
  # Perform an initial rotation to open a file
  result.rotate(getTime())
  let writeout_worker = result.run_writeout_worker()


# Threaded Loggers

when compileOption("threads"):

  import threadpool

  const thread_write_bufsize = 1_048_576

  type
    PChan = ptr Channel[string]
    ThreadFileLogger* = ref object of FileLogger
      f: File
      chan: Channel[string]
      buf: string
      running: bool

    ThreadRotatingFileLogger* = ref object of ThreadFileLogger
      compress: bool
      next_rotation_time: TimeInfo
      rotate_interval: string

  proc do_flush_buffer_cycle(self: ThreadFileLogger, n: int, pchan: PChan): int =
    ## Pop log messages from channel to a local buffer and then write it to disk
    ## Try to process up to `n` messages. Return earlier if there's any read
    ## error or we run out of buffer space.
    # Do not use self.chan in this thread.
    for cnt in 1..n:
      let msg = pchan[].recv()
      if self.buf.len + msg.len + 1 >= thread_write_bufsize:
        # Running out of buffer space
        self.f.write(self.buf)
        let write_size = self.buf.len
        self.buf.setLen(0)
        self.buf.add msg
        self.buf.add "\n"
        return write_size

      self.buf.add msg
      self.buf.add "\n"

    self.f.write(self.buf)
    let write_size = self.buf.len
    self.buf.setLen(0)
    return write_size

  proc flush_buffer(self: ThreadFileLogger, pchan: PChan) =
    ## Flush channel to file.
    # Iterate until the channel is empty
    # Peek the number of msgs it the channel.
    # This is the only proc that pops msgs so it is safe.
    while true:
      let n = pchan[].peek()
      if n == 0:
        break

      discard self.do_flush_buffer_cycle(n, pchan)

  proc run_writeout_worker(self: ThreadFileLogger, pchan: PChan) {.thread.} =
    ## Write out log messages
    # Do not use self.chan in this thread.
    self.f = open(self.log_filename, self.filemode, bufSize=0)
    while true:
      self.flush_buffer(pchan)
      os.sleep(self.writeout_interval_ms)

  proc log*(self: ThreadFileLogger, level: Level, args: varargs[string, `$`])
      {.raises: [Exception], tags: [RootEffect, TimeEffect, WriteIOEffect, ReadIOEffect].} =
    if level >= self.levelThreshold:
      let msg = self.format_msg(self.fmtStr, level, args)
      self.chan.send(msg)

  method fatal*(self: ThreadFileLogger, args: varargs[string, `$`])
      {.tags: [RootEffect, TimeEffect, WriteIOEffect, ReadIOEffect].} =
    self.log(lvlFatal, args)

  method error*(self: ThreadFileLogger, args: varargs[string, `$`])
      {.tags: [RootEffect, TimeEffect, WriteIOEffect, ReadIOEffect].} =
    self.log(lvlError, args)

  method warn*(self: ThreadFileLogger, args: varargs[string, `$`])
      {.tags: [RootEffect, TimeEffect, WriteIOEffect, ReadIOEffect].} =
    self.log(lvlWarn, args)

  method notice*(self: ThreadFileLogger, args: varargs[string, `$`])
      {.tags: [RootEffect, TimeEffect, WriteIOEffect, ReadIOEffect].} =
    self.log(lvlNotice, args)

  method info*(self: ThreadFileLogger, args: varargs[string, `$`])
      {.tags: [RootEffect, TimeEffect, WriteIOEffect, ReadIOEffect].} =
    self.log(lvlInfo, args)

  method debug*(self: ThreadFileLogger, args: varargs[string, `$`])
      {.tags: [RootEffect, TimeEffect, WriteIOEffect, ReadIOEffect].} =
    self.log(lvlDebug, args)

  proc close*(self: ThreadFileLogger) =
    ## Flush buffer and stop logger
    self.running = false
    self.flush_buffer(addr self.chan)
    self.chan.close()

  proc newThreadFileLogger*(
      filename_tpl = "$app.$y$MM$dd.log",
      fmtStr = "$datetime $levelname ",
      level_threshold = lvlAll,
      mode: FileMode = fmAppend,
      writeout_interval_ms = 100,
    ): ThreadFileLogger =
    ## Create a threaded file logger.
    new(result)
    assert writeout_interval_ms > 0
    result.buf = newStringOfCap(thread_write_bufsize)
    result.buffer_size = thread_write_bufsize
    result.filemode = mode
    result.fmtStr = fmtStr
    result.level_threshold = level_threshold
    result.log_filename_tpl = filename_tpl
    result.log_filename = generate_log_file_name(result.log_filename_tpl,
      getTime())
    result.writeout_interval_ms = writeout_interval_ms
    result.chan.open()
    result.running = true
    spawn result.run_writeout_worker(addr result.chan)


  # Rotating logger

  proc rotate(self: ThreadRotatingFileLogger, now: Time) =
    ## Rotate logfile, compressing it if needed
    self.next_rotation_time = pick_rotation_time(now, self.rotate_interval)
    if self.f != nil:
      self.f.close()

    if self.compress and self.log_filename != nil:
      self.log_filename.compress_file()

    self.log_filename = generate_log_file_name(self.log_filename_tpl, now)
    recursive_rename(self.log_filename)
    self.f = open(self.log_filename, self.filemode, bufSize=0)

  proc run_writeout_worker(self: ThreadRotatingFileLogger, pchan: PChan) =
    ## Perform log rotation and write out log messages
    while true:
      let now = getTime()
      if self.next_rotation_time.timeInfoToTime() <= now:
        self.rotate(now)

      if self.buffer_size != 0:
        self.flush_buffer(pchan)
      os.sleep(self.writeout_interval_ms)

  proc newThreadRotatingFileLogger*(
      compress = false,
      filename_tpl = "$app.$y$MM$dd.log",
      fmtStr = "$datetime $levelname ",
      level_threshold = lvlAll,
      mode: FileMode = fmAppend,
      rotate_interval = "1d",
      writeout_interval_ms = 100,
    ): ThreadRotatingFileLogger =
    ## Create a threaded rotating file logger.
    new(result)
    result.buf = newStringOfCap(thread_write_bufsize)
    result.buffer_size = thread_write_bufsize
    result.compress = compress
    result.filemode = mode
    result.fmtStr = fmtStr
    result.level_threshold = level_threshold
    result.log_filename_tpl = filename_tpl
    result.log_filename = generate_log_file_name(result.log_filename_tpl,
      getTime())
    result.rotate_interval = rotate_interval
    result.f = open(result.log_filename, result.filemode, bufSize=0)
    result.writeout_interval_ms = writeout_interval_ms
    result.chan.open()
    # Perform an initial rotation to open a file
    result.rotate(getTime())
    spawn result.run_writeout_worker(addr result.chan)
