#!/usr/bin/env bash
# squad_cli_normalize の契約のうち、gh-check-runs を除く gh と codex の応答を確かめる。見本のない Status と Codex の secondary も確かめる。
# 検証の本体は tests/squad-cli-lib-contract.py、multica の応答は tests/squad-cli-lib-test.sh、gh-check-runs は tests/squad-cli-lib-check-runs-test.sh にある。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
mkdir -p tmp
test_dir=$(mktemp -d "$PWD/tmp/cli-lib-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
python3 - "$test_dir" gh <"$root/tests/squad-cli-lib-contract.py"
