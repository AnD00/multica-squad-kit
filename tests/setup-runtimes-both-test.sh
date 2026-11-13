#!/usr/bin/env bash
# ZIP のルートから bash tests/setup-runtimes-both-test.sh で実行する。
# setup.sh と全 lib を本体のまま通し、ランタイムの選び方が both の場合の初回・再実行・配置した見張りを確かめる。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
runtime_selections=both
runtime_part=main
source "$root/tests/setup-runtimes-test-lib.sh"
