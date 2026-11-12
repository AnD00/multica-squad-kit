#!/usr/bin/env bash
# squad_cli_normalize と squad_cli_read の契約のうち、multica の応答を確かめる。ページごとの検証、CLI のスタブでの読み取り・失敗の境界も確かめる。
# 検証の本体は tests/squad-cli-lib-contract.py、gh と codex の応答は tests/squad-cli-lib-gh-test.sh と tests/squad-cli-lib-check-runs-test.sh にある。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
mkdir -p tmp
test_dir=$(mktemp -d "$PWD/tmp/cli-lib-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
python3 - "$test_dir" multica <"$root/tests/squad-cli-lib-contract.py"
