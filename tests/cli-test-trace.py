"""比較用の呼び出し記録。ランダムな作業先と本文ファイル名だけを正規化する。

補助（tests/cli-stub.py）から関数 trace を読み込む。スクリプトとしても使える。
"""

import json
import os
import sys
from pathlib import Path


def trace(work, command, args):
    target = os.environ.get("SQUAD_CLI_TEST_TRACE_FILE")
    if not target:
        return
    work = str(work)
    args = list(args)
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


if __name__ == "__main__":
    trace(*sys.argv[1:3], sys.argv[3:])
