"""テストの gh・multica・curl のスタブが 1 回の呼び出しで使う補助。

使い方: cli-stub.py 種類 作業先 コマンド 記録先 操作 [名前 [ファイルまたは値]] -- スタブの引数...

呼び出しの記録と、見本を重ねて返す処理を、1 つの python3 で済ませる。
- 比較用の記録（cli-test-trace.py の行）を、SQUAD_CLI_TEST_TRACE_FILE があるときだけ足す
- 記録先が - でなければ、作業先のその名前のファイルへ、引数の JSON の配列を 1 行で足す
- 操作が record なら、ここまで。それ以外は、種類の見本のファイルの関数 run で見本を返す
  種類: gh（gh-fixture.py）、multica（multica-fixture.py）、pr-watch（pr-watch-fixture.py）、
  review-wait（review-wait-fixture.py）、none（見本なし）
"""

import json
import os
import runpy
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
fixture_files = {
    "gh": "gh-fixture.py",
    "multica": "multica-fixture.py",
    "pr-watch": "pr-watch-fixture.py",
    "review-wait": "review-wait-fixture.py",
}


def load(file):
    return runpy.run_path(str(root / "tests" / file))


def main(argv):
    split = argv.index("--")
    (kind, work, command, calls, action, *spec), args = argv[:split], argv[split + 1:]
    if os.environ.get("SQUAD_CLI_TEST_TRACE_FILE"):
        load("cli-test-trace.py")["trace"](work, command, args)
    if calls != "-":
        with (Path(work) / calls).open("a") as stream:
            stream.write(json.dumps(args, ensure_ascii=False, separators=(",", ":")) + "\n")
    if action != "record":
        load(fixture_files[kind])["run"](work, action, *spec)


if __name__ == "__main__":
    main(sys.argv[1:])
