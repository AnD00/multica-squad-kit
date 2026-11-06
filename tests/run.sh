#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
for test in tests/*-test.sh; do
	bash "$test"
done
echo 'PASS suite: すべてのテスト'
