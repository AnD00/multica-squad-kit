#!/usr/bin/env bash
# 質問の入口から実際の拡張を読み、確認前に紐付け先を照合する。
source "$(dirname "$0")/setup-fixture.sh"
cp "$root/lib/extensions.py" "$test_dir/package/lib/extensions.py"
mkdir -p "$test_dir/extension"
cp "$root/VERSION" "$test_dir/extension/kit-version"
printf '["EXAMPLE/TWO"]\n' >"$test_dir/extension/link-repositories.json"
manifest
run() { { printf '%s\n' "$test_dir/extension"; cat "$test_dir/input"; } | /bin/bash "$test_dir/package/setup.sh" >"$test_dir/out" 2>"$test_dir/err"; }
printf '1\n1\ndemo\n1\nmembera\n0\n1\n0\n\nno\n' >"$test_dir/input"
deny
no_state
grep -qxF '    + example/two  紐付けだけ' "$test_dir/err"
grep -qxF '    + Dependabot の PR の週次の確認 demo example/one' "$test_dir/err"
! grep -qF 'Dependabot の PR の週次の確認 demo example/two' "$test_dir/err"
! grep -q 'TEST-project-prepared' "$test_dir/out"
echo 'PASS scope questions: コード作業先とは別に紐付け先を示し、確認を断ると保存も登録もしない'

printf '["example/unregistered"]\n' >"$test_dir/extension/link-repositories.json"
deny
no_state
grep -q 'ワークスペースに登録済み' "$test_dir/err"
! grep -q '答えの一覧（まだ変更していません）' "$test_dir/err"
echo 'PASS scope questions: 未登録の紐付け先は確認・保存・ホスト準備より前に拒否する'
