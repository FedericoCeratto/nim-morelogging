#
# Morelogging logging library
#
# Testing utilities
#
# (c) 2017 Federico Ceratto <federico.ceratto@gmail.com>
# Released under the LGPLv3 license, see LICENSE file

import os,
  osproc,
  pegs,
  random,
  sets,
  strutils

proc toSeq[T](a: set[T]): seq[T] {.inline.} =
  result = @[]
  for i in a:
    result.add i

const letters = Letters.toSeq


template with_temp_dir*(tempdir_name: expr, tpl: string, body: stmt): stmt {.immediate.} =
  ## Create a temporary directory and remove it after executing code successfully
  ## The templating string supports the following keywords:
  ##   $appfn: application filename
  ##   $id: incremental numeric counter
  ##   $rand: random 8 letters string
  var tempdir_name: string
  var vtpl = tpl
  if tpl.len == 0:
    vtpl = "nimtest_$appfn_$id"
  elif tpl[0] == '/':
    raise newException(ValueError, "tpl cannot be empty or start with '/'")

  if vtpl.contains "$appfn":
    let app_fname:string = getAppFilename()
    vtpl = vtpl.replace("$appfn", app_fname)

  let basedir = getTempDir()
  if vtpl.contains "$rand":
    if vtpl.contains "$id":
      raise newException(ValueError, "tpl cannot contain both $rand and $id")

    while true:
      var token = ""
      for _ in 1..8:
        token.add letters.random()

      vtpl = vtpl.replace("$rand", token)
      tempdir_name = basedir.joinPath(vtpl)
      if not existsDir(tempdir_name):
        break

  elif vtpl.contains "$id":
    var id = 0
    while true:
      tempdir_name = vtpl.replace("$id", $id)
      tempdir_name = basedir.joinPath(tempdir_name)
      if not existsDir(tempdir_name):
        break
      id.inc

  else:
    tempdir_name = basedir.joinPath(vtpl)

  create_dir(tempdir_name)
  body
  remove_dir(tempdir_name)


template render_code*(fname: string, code: expr): stmt =
  ## Render code to a temporary file
  const header = """
  import asyncdispatch
  from strutils import align
  from times import epochTime
  import morelogging
  """
  let
    main_body = astToStr(code)
    code_as_string = header & main_body & "\n"
    dedented = code_as_string.replace("\n  ", "\n")

  writeFile(fname, dedented)


proc delete_logs() =
  ## Delete all logs
  for fn in walkFiles("tmpdir/*.log"):
    removeFile(fn)
  for fn in walkFiles("tmpdir/*.log.*"):
    if fn =~ peg"tmpdir/\w+\.log\.\d+(\.gz)?":
      # Match *.log.<number>[.gz]
      removeFile(fn)


proc cleanup_compile_and_run*(compile_opts="") =
  ## Cleanup temp files and compile
  removeFile("tmpdir/tmp")
  delete_logs()
  let cmd = "nim c -p:. -d:release $# ./tmpdir/tmp.nim > compile_out 2>&1" % compile_opts
  echo "    [compiling]"
  if execCmd(cmd) != 0:
    echo "Failed to build:\n----"
    echo "compile_out".readFile()
    echo "----"
    quit(1)

  echo "    [running]"
  doAssert execCmd("./tmpdir/tmp") == 0

