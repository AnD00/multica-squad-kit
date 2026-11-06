#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/content.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
mkdir "$test_dir/package"
export SQUAD_KIT_FORBIDDEN_FILE="$test_dir/terms"
printf '%s\n' private-canary >"$SQUAD_KIT_FORBIDDEN_FILE"
printf '%s\n' safe >"$test_dir/package/value"
bash "$root/tests/check-content.sh" "$test_dir/package" >/dev/null
deny() {
 if bash "$root/tests/check-content.sh" "$test_dir/package" >"$test_dir/out" 2>"$test_dir/err"; then exit 1; fi
 [[ -s $test_dir/err ]]
 ! grep -qi private-canary "$test_dir/err"
}
printf '%s\n' PRIVATE-CANARY >"$test_dir/package/value"
deny
printf '%s\n' safe >"$test_dir/package/value"
touch "$test_dir/package/private-canary"
deny
rm "$test_dir/package/private-canary"
printf '%08x-%04x-%04x-%04x-%012x\n' 1 2 3 4 5 >"$test_dir/package/value"
deny
: >"$SQUAD_KIT_FORBIDDEN_FILE"
deny
echo 'PASS content: 大小文字・名前・UUID・空の一覧を拒否し、禁止語を表示しない'

printf 'key\n' >"$SQUAD_KIT_FORBIDDEN_FILE"
printf 'keyboard\n' >"$test_dir/package/value"
bash "$root/tests/check-content.sh" "$test_dir/package" >/dev/null
printf 'KEY_EXPORT\n' >"$test_dir/package/value"
deny
echo 'PASS content: 短い英字の名前は語の途中を誤検出せず、名前の接頭辞を検出する'
