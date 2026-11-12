#!/usr/bin/env bash
# ZIP のルートから bash tests/project-progress-test.sh で実行する。
# セットアップの作る間の一覧: 実際の prepare_project を 13 手順の一覧のまま動かし、手順の並びと値、1 件ごとの文が出ないこと、失敗の ✖ を確かめる
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/tests/project-test-lib.sh"

reset_db
TEST_STEPS=yes run
steps=$(grep -E '^  ✔ ' "$test_dir/err" | sed -E 's/^  ✔ ([^ ]+( [^ ]+)*)( {2}.*)?$/\1/' | sed -E 's/ +$//')
# 手順の行だけが、この順に出る。スクワッドのメンバーとオートパイロットは、試験で差し替えた部品の中で終わるので、ここには出ない。
printf '%s\n' ホストを準備 共通のラベルとスキル プロジェクトとリポジトリ 'エージェントの ID' スクワッド 指示とスキル エージェントを設定 エージェントを公開 Webhook 導入の確認 タスクの起票 >"$test_dir/expected-steps"
printf '%s\n' "$steps" >"$test_dir/actual-steps"
cmp "$test_dir/expected-steps" "$test_dir/actual-steps"
! grep -qE '^エージェント[0-9 ]*[0-9]+/[0-9]+|^エージェントの(設定|公開) [0-9]+/|^許可の確認:|^スクワッドの準備|ID の準備' "$test_dir/err"
# 値: ID・設定・公開は 17 役の件数と時間を添える（列をそろえる空白は幅による）。
grep -qE '^  ✔ エージェントの ID +17  [0-9]+[sm]' "$test_dir/err"
grep -qE '^  ✔ エージェントを設定 +17  [0-9]+[sm]' "$test_dir/err"
grep -qE '^  ✔ エージェントを公開 +17  [0-9]+[sm]' "$test_dir/err"
echo 'PASS project-progress: 作る間の一覧は手順の行を順に出し、1 件ごとの行と文を出さず、ID・設定・公開に件数と時間を添える'

# 手順の途中で止まると、その手順を ✖ にして、扱っていた名前を添え、同じ理由のエラーで止まる。
reset_db
TEST_STEPS=yes TEST_FAIL_STEP=yes TEST_EXCLUDED='["not-a-role"]' deny || true
grep -qF '外す役の指定が不正です。' "$test_dir/err"
grep -qE '^  ✖ プロジェクトとリポジトリ  ' "$test_dir/err"
[[ $(grep -c '✖' "$test_dir/err") == 1 ]]
echo 'PASS project-progress: 手順の途中で止まると ✖ を 1 度だけ出し、同じ理由のエラーで止まる'
