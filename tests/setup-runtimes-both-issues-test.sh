#!/usr/bin/env bash
# setup.sh と全 lib を本体のまま通し、both の最後の起票の失敗と、登録済みの状態からの復旧を確認する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
runtime_selections=both
runtime_part=issues
source "$root/tests/setup-runtimes-test-lib.sh"
