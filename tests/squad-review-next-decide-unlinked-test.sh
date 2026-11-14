#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-next-decide-unlinked-test.sh で実行する。
# squad-review-next decide の判定のうち、紐付いていない PR の確認（その場の CI・コンフリクト）・書けないときの失敗・引数を確かめる。準備は tests/review-next-decide-common.sh にある。
set -euo pipefail
source "$(dirname "$0")/review-next-decide-common.sh"
reset

# 紐付いていないときの確認（表の 4）。
unlinked() { printf '紐付け: 紐付いていない pr: %s\n' "$pr_url" >"$test_dir/link-out"; }
reset
set_roster orchestrator code-reviewer qa claude-principal
ok_round
unlinked
set_principal_pick claude-principal
run round-1
expect_posted 最終レビュー "$(final_request_body 'PR の差分全体')"
expect_call_has pr-watch-calls 'ci-held test-issue round-1'
expect_call_has pr-watch-calls 'ci-now test-issue orchestrator round-1'
expect_call_has pr-watch-calls 'conflicts-check test-issue'
expect_call_lacks pr-watch-calls 'ci test-issue'
# 見張りの役がいれば、見張りを入れてから、見張りの役の ID を付けてその場の確認を流す。
reset
ok_round
unlinked
run round-1
expect_status 0
expect_call_has pr-watch-calls 'ci test-issue ci-monitor round-1'
expect_call_has pr-watch-calls 'ci-now test-issue orchestrator round-1 ci-monitor'
# 見張りを入れられなければ止まる。
reset
ok_round
unlinked
echo 1 >"$test_dir/ci-status"
run round-1
expect_leader 'CI の見張りを入れられない'
# マージの段で見張りの役がいれば、その場の確認（ci-now）は流さず、見張りを入れて ci-wait で CI を待つ。
reset
set_roster orchestrator code-reviewer qa ci-monitor
ok_round
unlinked
run round-1
expect_status 0
expect_call_has pr-watch-calls 'ci-held test-issue round-1'
expect_call_has pr-watch-calls 'ci test-issue ci-monitor round-1'
expect_call_has pr-watch-calls 'ci-wait test-issue orchestrator round-1'
expect_call_lacks pr-watch-calls ci-now
expect_call_has pr-watch-calls 'unlinked test-issue round-1 --leader orchestrator'
[[ $(<"$test_dir/out") == $'次の依頼: マージの依頼'* ]] || fail "CI が成功なのに、マージの依頼を書いていない: $(<"$test_dir/out")"
# その場の確認が止まる値。
reset
ok_round
unlinked
printf '紐付け: 紐付いていない pr: 不明\n' >"$test_dir/cinow-out"
run round-1
expect_leader '紐付け: 紐付いていない'
reset
ok_round
unlinked
printf 'CI 0123456: 失敗あり（lint）\n' >"$test_dir/cinow-out"
run round-1
expect_leader 'CI 0123456: 失敗あり（lint）'
reset
ok_round
unlinked
echo 1 >"$test_dir/cinow-status"
run round-1
expect_leader 'CI のその場の確認が 0 以外で終わった'
# 実装の作業中なので保留した失敗と、/note の行は、止めない。
reset
ok_round
unlinked
printf '/note\nCI 0123456: 失敗あり（lint。修正の作業中なので保留）\n/note 補足\n' >"$test_dir/cinow-out"
run round-1
expect_status 0
[[ $(<"$test_dir/out") == $'次の依頼: 最終レビュー'* ]] || fail "保留の失敗で止まっている: $(<"$test_dir/out")"
# コンフリクトで止まる。
reset
ok_round
unlinked
printf 'コンフリクト: CONFLICTING head: %s\n' "$sha" >"$test_dir/conf-out"
run round-1
expect_leader 'コンフリクト: CONFLICTING'
# 判定できないコンフリクト（UNKNOWN・空）は止めない。
reset
ok_round
unlinked
printf 'コンフリクト: UNKNOWN head: %s\n' "$sha" >"$test_dir/conf-out"
run round-1
expect_status 0
# 紐付いているときは、その場の確認もコンフリクトの確認もしない。
reset
ok_round
run round-1
expect_call_lacks pr-watch-calls ci-now
expect_call_lacks pr-watch-calls conflicts-check
expect_call_lacks pr-watch-calls 'ci '
# 依頼のコメントに書く PR は、紐付けの確認が出した URL にする。
reset
ok_round
printf '紐付け: 紐付いている pr: https://github.com/demo/project/pull/99\n' >"$test_dir/link-out"
run round-1
[[ $(posted_body) == *$'\n対象の PR: https://github.com/demo/project/pull/99' ]] || fail "対象の PR が紐付けの URL でない: $(posted_body)"
echo 'PASS review-next-decide: 紐付いていない PR は、その場の CI（見張りの役がある構成は ci-wait）とコンフリクトを確かめ、止まる値ならリーダーに任せる'

# ---- 書く前の失敗。
reset
ok_round
touch "$test_dir/comments-fail"
run round-1
expect_failure 'コメントを読めない'
reset
ok_round
echo 1 >"$test_dir/watch-status"
run round-1
expect_failure '返事の待ちの見張りを入れられない'
expect_no_calls status-calls
reset
ok_round
touch "$test_dir/post-fail"
run round-1
expect_failure 'コメントの投稿に失敗した'
reset
ok_round
run 'ないコメント'
expect_failure '返事の組を読めない'
# CI の待ちの規則があれば、書く前に消す。消せなければ何も書かない。
reset
set_metadata ci_wait_head "$sha"
ok_round
run round-1
expect_status 0
expect_call_has pr-watch-calls 'ci-wait-clear test-issue'
reset
set_metadata ci_wait_head "$sha"
ok_round
echo 1 >"$test_dir/clear-status"
run round-1
expect_failure 'CI の待ちの規則を消せない'
expect_nothing_written
reset
ok_round
run round-1
expect_call_lacks pr-watch-calls ci-wait-clear
echo 'PASS review-next-decide: 書けないときは、理由を出して失敗し、CI の待ちの規則は書く前にだけ消す'

# 引数の数。
status=0
(cd "$test_dir" && bash monitor/squad-review-next decide test-issue) >/dev/null 2>"$test_dir/err" || status=$?
[[ $status == 2 && $(<"$test_dir/err") == *使い方* ]] || fail "decide の引数の数を検査していない"
reset
ok_round
status=0
(cd "$test_dir" && bash monitor/squad-review-next decide test-issue round-1 規則) >"$test_dir/out" 2>"$test_dir/err" || status=$?
expect_status 0
echo 'PASS review-next-decide: 第 3 引数（起きた規則）は受け取り、引数が足りなければ使い方を出す'
