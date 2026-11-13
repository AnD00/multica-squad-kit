#!/usr/bin/env bash
# ZIP のルートから bash tests/setup-runtimes-codex-test.sh で実行する。
# setup.sh と全 lib を本体のまま通し、ランタイムの選び方が codex の場合を確認する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
runtime_selections=codex
source "$root/tests/setup-runtimes-test-lib.sh"
