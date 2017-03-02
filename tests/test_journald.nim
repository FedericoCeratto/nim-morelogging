#
# Morelogging logging library - Journald tests
#
# (c) 2017 Federico Ceratto <federico.ceratto@gmail.com>
# Released under the LGPLv3 license, see LICENSE file

## Warning: Logs to Journald and requires sudo

import json,
  osproc,
  strutils,
  times,
  unittest
from logging import lvlInfo

import morelogging, testutils

const journalctl_call = "sudo journalctl -e -o json TOPIC=morelogging_functional_test -n1 --no-pager"

suite "functional tests - journald":

  test "basic":

    let msg_id = $(int(epochTime()))
    let log = newJournaldLogger()
    log.info("hello world", {
      "status": "ok",
      "test_number": "1",
      "topic": "morelogging_functional_test",
      "message_id": msg_id,
    })

    var j = execProcess(journalctl_call).parseJson()
    check j["MESSAGE"].str == "hello world"
    check j["TEST_NUMBER"].str == "1"
    check j["STATUS"].str == "ok"
    check j["MESSAGE_ID"].str == msg_id
    check j["PRIORITY"].str == "6"

    log.debug("hello world", {"test_number": "2", "topic": "morelogging_functional_test"})
    j = execProcess(journalctl_call).parseJson()
    check j["TEST_NUMBER"].str == "2"
    check j["PRIORITY"].str == "7"

    log.notice("hello world", {"test_number": "3", "topic": "morelogging_functional_test"})
    j = execProcess(journalctl_call).parseJson()
    check j["TEST_NUMBER"].str == "3"
    check j["PRIORITY"].str == "5"

  test "code line/file/func":

    let msg_id = $(int(epochTime()))
    let log = newJournaldLogger()
    log.info("hello world", {
      "status": "ok",
      "test_number": "1",
      "topic": "morelogging_functional_test",
      "message_id": msg_id,
    })

    log.notice("hello world", {"test_number": "4",
      "topic": "morelogging_functional_test",
    })
    var j = execProcess(journalctl_call).parseJson()
    check j["CODE_LINE"].str == "61"
    check j["CODE_FILE"].str == "test_journald.nim"
    check j["CODE_FUNC"].str == "test_journald"

    log.notice("hello world", {
      "test_number": "5",
      "topic": "morelogging_functional_test",
      "CODE_LINE": "123",
      "CODE_FILE": "bogus.nim",
      "CODE_FUNC": "bogus",
    })
    j = execProcess(journalctl_call).parseJson()
    check j["CODE_LINE"].str == "123"
    check j["CODE_FILE"].str == "bogus.nim"
    check j["CODE_FUNC"].str == "bogus"
