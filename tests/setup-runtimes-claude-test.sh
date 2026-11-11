#!/usr/bin/env bash
# ZIP のルートから bash tests/setup-runtimes-claude-test.sh で実行する。
# setup.sh と全 lib を本体のまま通し、ランタイムの選び方が claude の場合を確かめる。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
runtime_selections=claude
source "$root/tests/setup-runtimes-test-lib.sh"
