#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-next-decide-pr-test.sh で実行する。
# squad-review-next decide の判定のうち、PR の確認のうち、紐付けの判定と保留した CI の失敗を確認する。準備は tests/review-next-decide-common.sh にある。
set -euo pipefail
source "$(dirname "$0")/review-next-decide-common.sh"
reset

# ---- PR の確認。
# 紐付けの判定（表の 2）。未確認は 1 回だけ流し直す。
reset
ok_round
printf '紐付け: 未確認 pr: 不明 理由: テスト\n' >"$test_dir/link-out.1"
run round-1
expect_status 0
[[ $(grep -c '^link-check ' "$test_dir/pr-watch-calls") == 2 ]] || fail "link-check を 2 回流していない: $(<"$test_dir/pr-watch-calls")"
reset
ok_round
for i in 1 2; do printf '紐付け: 未確認 pr: 不明 理由: テスト\n' >"$test_dir/link-out.$i"; done
run round-1
expect_leader '紐付け: 未確認 pr: 不明 理由: テスト'
[[ $(grep -c '^link-check ' "$test_dir/pr-watch-calls") == 2 ]] || fail "link-check を 2 回で止めていない"
[[ $(<"$test_dir/out") != *'ホストのスクリプトが古い'* ]] || fail "古い案内が出ている"
for code in 2 127; do
	reset
	ok_round
	echo "$code" >"$test_dir/link-status"
	: >"$test_dir/link-out"
	run round-1
	expect_leader '（ホストのスクリプトが古い）'
done
# 0 以外で終わったら、行が読めても未確認にする。
reset
ok_round
echo 1 >"$test_dir/link-status"
run round-1
expect_leader '紐付け: 未確認'
[[ $(<"$test_dir/out") != *'ホストのスクリプトが古い'* ]] || fail "1 で終わったのに古い案内が出ている"
# 判定の行がなければ未確認にする。
reset
ok_round
: >"$test_dir/link-out"
run round-1
expect_leader '判定の行が出なかった'
# 紐付いている・紐付いていない以外の判定は、その行で止まる。
for line in '紐付け: 別のタスクに紐付いている pr: https://github.com/demo/project/pull/7' '紐付け: PR がない pr: 不明'; do
	reset
	ok_round
	echo "$line" >"$test_dir/link-out"
	run round-1
	expect_leader "$line"
done
# 行き先がリーダーに任せる値でも、マージの手順でも、PR の確認は先に流す。
reset
set_roster orchestrator code-reviewer qa
ok_round
echo '紐付け: 別のタスクに紐付いている pr: https://github.com/demo/project/pull/7' >"$test_dir/link-out"
run round-1
expect_leader '紐付け: 別のタスクに紐付いている'
echo 'PASS review-next-decide: 紐付けの判定が進める値でなければ、行き先によらずリーダーに任せる'

# CI の保留した失敗（表の 3）。見張りの役がいるか、PR が紐付いていないときに確認する。
reset
ok_round
printf 'CI 0123456: 失敗あり（テスト）\n' >"$test_dir/held-out"
run round-1
expect_leader '保留した CI の失敗がある'
expect_call_has pr-watch-calls 'ci-held test-issue round-1'
reset
ok_round
echo 1 >"$test_dir/held-status"
run round-1
expect_leader 'CI の保留した失敗を読めない'
# 見張りの役がなく、紐付いているなら、確認しない。
reset
set_roster orchestrator code-reviewer qa claude-principal claude-fixer
ok_round
printf 'CI 0123456: 失敗あり（テスト）\n' >"$test_dir/held-out"
run round-1
expect_status 0
expect_call_lacks pr-watch-calls ci-held
# マージの手順で、見張りの役がいるときも、保留した失敗を読み、あれば止まる。止まるときは、CI の待ちも規則の登録もしない。
reset
set_roster orchestrator code-reviewer qa ci-monitor
ok_round
printf 'CI 0123456: 失敗あり（テスト）\n' >"$test_dir/held-out"
run round-1
expect_leader '保留した CI の失敗がある'
expect_call_has pr-watch-calls 'ci-held test-issue round-1'
expect_call_lacks pr-watch-calls ci-wait
expect_call_lacks pr-watch-calls 'conflicts test-issue'
# マージの手順で、見張りの役がなく、紐付いていないなら、保留した失敗を読み、あれば止まる。
reset
set_roster orchestrator code-reviewer qa
ok_round
printf '紐付け: 紐付いていない pr: %s\n' "$pr_url" >"$test_dir/link-out"
printf 'CI 0123456: 失敗あり（テスト）\n' >"$test_dir/held-out"
run round-1
expect_leader '保留した CI の失敗がある'
expect_call_lacks pr-watch-calls 'conflicts test-issue'
echo 'PASS review-next-decide: 保留した CI の失敗は、確認する条件のときだけ読み、あればリーダーに任せる'
