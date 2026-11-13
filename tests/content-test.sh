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

unset SQUAD_KIT_FORBIDDEN_FILE
if bash "$root/tests/check-content.sh" "$test_dir/package" >"$test_dir/out" 2>"$test_dir/err"; then exit 1; fi
grep -q '禁止語の一覧ファイルを指定してください' "$test_dir/err"
echo 'PASS content: 公開の指定がなければ一覧なしで通らない'

public_pass() {
 bash "$root/tests/check-content.sh" --public "$test_dir/package" >"$test_dir/out" 2>"$test_dir/err"
 [[ $(cat "$test_dir/out") == 'PASS content: 公開の検査で混入 0 件（秘密の語は見ていない）' ]]
 [[ ! -s $test_dir/err ]]
}
public_deny() {
 if bash "$root/tests/check-content.sh" --public "$test_dir/package" >"$test_dir/out" 2>"$test_dir/err"; then exit 1; fi
 [[ ! -s $test_dir/out ]]
 grep -q 'FAIL content: 混入 1 件（検出した値は表示しません）' "$test_dir/err"
 ! grep -qF "$public_uuid" "$test_dir/err"
 ! grep -qi private-canary "$test_dir/err"
}
printf '%s\n' PRIVATE-CANARY >"$test_dir/package/value"
mkdir "$test_dir/package/private-canary"
touch "$test_dir/package/private-canary/name"
public_pass
export SQUAD_KIT_FORBIDDEN_FILE="$test_dir/terms"
printf '%s\n' private-canary >"$SQUAD_KIT_FORBIDDEN_FILE"
public_pass
: >"$SQUAD_KIT_FORBIDDEN_FILE"
public_pass
export SQUAD_KIT_FORBIDDEN_FILE="$test_dir/missing-terms"
public_pass
echo 'PASS content: 公開の検査は一覧が未指定・設定済み・空・存在しない場合も語を見ない'

public_uuid=$(printf '%08x-%04x-%04x-%04x-%012x' 1 2 3 4 5)
printf '%s\n' "$public_uuid" >"$test_dir/package/value"
public_deny
printf '%s\n' safe >"$test_dir/package/value"
touch "$test_dir/package/$public_uuid"
public_deny
rm "$test_dir/package/$public_uuid"
echo 'PASS content: 公開の検査は一覧なしで内容と名前の UUID を検出し、値を表示しない'

ln -s value "$test_dir/package/link"
public_deny
rm "$test_dir/package/link"
ln -s private-canary "$test_dir/package/link"
public_deny
rm "$test_dir/package/link"
ln -s missing "$test_dir/package/link"
public_deny
rm "$test_dir/package/link"
echo 'PASS content: 公開の検査はファイル・ディレクトリ・切れたリンクを検出する'

mkdir "$test_dir/package/.git" "$test_dir/package/tmp"
for excluded in .git tmp; do
 printf '%s\n' "$public_uuid" >"$test_dir/package/$excluded/value"
 ln -s missing "$test_dir/package/$excluded/link"
done
public_pass
echo 'PASS content: 公開の検査も Git の管理領域と tmp を除く'

# 木を省略したときも、作業ディレクトリではなくスクリプトの原本を検査する。
mkdir -p "$test_dir/default/tests"
cp "$root/tests/check-content.sh" "$root/tests/check-content.py" "$test_dir/default/tests/"
printf '%s\n' "$public_uuid" >"$test_dir/default/value"
if (cd "$test_dir/package" && bash "$test_dir/default/tests/check-content.sh" --public) >"$test_dir/out" 2>"$test_dir/err"; then exit 1; fi
grep -q 'FAIL content: 混入 1 件' "$test_dir/err"
printf '%s\n' safe >"$test_dir/default/value"
(cd "$test_dir/package" && bash "$test_dir/default/tests/check-content.sh" --public) >"$test_dir/out" 2>"$test_dir/err"
[[ $(cat "$test_dir/out") == 'PASS content: 公開の検査で混入 0 件（秘密の語は見ていない）' ]]
[[ ! -s $test_dir/err ]]
echo 'PASS content: 公開の検査は木を省略すると原本を検査する'
