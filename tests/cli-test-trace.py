"""比較用の呼び出し記録。ランダムな作業先と本文ファイル名だけを正規化する。"""

import json
import os
import sys
from pathlib import Path

target = os.environ.get("SQUAD_CLI_TEST_TRACE_FILE")
if target:
    work, command, *args = sys.argv[1:]
    if command == "result":
        args[2] = "stdout:" + Path(args[2]).read_text().replace(work, "<work>")
    for index, arg in enumerate(args):
        if index and args[index - 1] in ("--content-file", "--description-file", "--instruction-file", "--body-file"):
            args[index] = "file:" + Path(arg).read_text()
        else:
            args[index] = arg.replace(work, "<work>")
            if index and args[index - 1] == "--output-file":
                args[index] = "<output>"
    with Path(target).open("a") as stream:
        stream.write(json.dumps([command, *args], ensure_ascii=False) + "\n")
