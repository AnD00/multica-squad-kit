#!/usr/bin/env bash
# ZIP のルートから bash tests/setup-runtimes-both-changes-test.sh で実行する。
# setup.sh と全 lib を本体のまま通し、ランタイムの選び方が both の場合の、更新の権限がない共通スキルと既存の検証スキルの差を確かめる。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
runtime_selections=both
runtime_part=changes
source "$root/tests/setup-runtimes-test-lib.sh"
