#!/usr/bin/env bash
# squad_cli_normalize の契約のうち、gh-check-runs の応答を確かめる。
# 検証の本体は tests/squad-cli-lib-contract.py、ほかの応答は tests/squad-cli-lib-test.sh と tests/squad-cli-lib-gh-test.sh にある。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
mkdir -p tmp
test_dir=$(mktemp -d "$PWD/tmp/cli-lib-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
python3 - "$test_dir" check-runs <"$root/tests/squad-cli-lib-contract.py"
