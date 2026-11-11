#!/usr/bin/env bash
# 読み取りだけを実行する。書き込み応答は、別途採取したファイルを渡す。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
exec python3 "$root/tests/capture-cli-fixtures.py" "$@"
