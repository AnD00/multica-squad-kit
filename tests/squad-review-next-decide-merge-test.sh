#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-next-decide-merge-test.sh で実行する。
# squad-review-next decide のマージの依頼（確認の流れ・規則の登録・コメント・止まる値）を確かめる。準備は tests/review-next-decide-common.sh にある。
set -euo pipefail
source "$(dirname "$0")/review-next-decide-common.sh"

unlinked() { printf '紐付け: 紐付いていない pr: %s\n' "$pr_url" >"$test_dir/link-out"; }
conf_line="コンフリクト: MERGEABLE head: $sha"
final_ok() { # 最終レビューまで済んだ状態にする。回は final-1
	set_merge_roster
	ok_round
	final_round final-1 "$sha" round-1
	result final-1 claude-principal ✅ "$sha" なし
}
lines_all=('✅ demo-claude-principal-test: 結果' '✅ demo-code-reviewer-test: 結果' '✅ demo-qa-test: 結果')

# ---- 紐付いているとき。確認は head・コンフリクトだけで、CI は読まず、コンフリクトの規則だけを入れ直す。
reset
final_ok
run final-1
expect_merge_posted "$(merge_body final-1 "$sha" "$conf_line" "${lines_all[@]}")" final-1
expect_calls pr-watch-calls $'link-check test-issue\nconflicts-check test-issue\nconflicts test-issue --leader orchestrator'
expect_calls head-calls 'pr view 7 --repo demo/project --json headRefOid'
echo 'PASS review-next-decide: 紐付いているマージの依頼は、head とコンフリクトを確かめ、CI を読まず、コンフリクトの規則を入れてから書く'

# ---- 紐付いていないとき。その場の CI を読み、unlinked を入れ、紐付けの案内と見張りの行を添える。
reset
final_ok
unlinked
printf 'CI %s: 成功\n' "${sha:0:7}" >"$test_dir/cinow-out"
run final-1
expect_merge_posted "$(merge_body final-1 "$sha" "$conf_line" "CI ${sha:0:7}: 成功" "${lines_all[@]}" \
	"紐付いていないので、マージのあとにタスクを \`done\` にしてほしい（または先に紐付けてほしい）。PR: \`${pr_url}\`" \
	'見張り: 1 時間おき、2026-11-17 まで')" final-1
expect_calls pr-watch-calls $'link-check test-issue\nconflicts-check test-issue\nci-held test-issue final-1\nci-now test-issue orchestrator final-1\nconflicts test-issue --leader orchestrator\nunlinked test-issue final-1 --leader orchestrator'
echo 'PASS review-next-decide: 紐付いていないマージの依頼は、その場の CI を読み、unlinked を入れて、紐付けの案内と見張りの行を添える'

# 紐付けの失敗の段落と連携の案内は、PR を作った役の引き継ぎから写す。
reset
final_ok
unlinked
n=0
comments=$(jq 'del(.[] | select(.id == "pr-made"))' "$test_dir/comments.json")
echo "$comments" >"$test_dir/comments.json"
add pr-made claude-implementer "PR を作りました ${pr_url}"$'\n\n紐付けの失敗: PR をタスクに紐付けられなかった。\n404 で待ち切れなかったため、連携を確かめてほしい。' ""
run final-1
expect_status 0
body=$(posted_body)
[[ $body == *$'\n紐付けの失敗: PR をタスクに紐付けられなかった。'* ]] || fail "紐付けの失敗の段落がない: $body"
echo 'PASS review-next-decide: 紐付けの失敗の段落を、PR を作った役の引き継ぎから写す'

# ---- unlinked の出力。
reset
final_ok
unlinked
printf '紐付け: 紐付いていない pr: 不明\n' >"$test_dir/unlinked-out"
run final-1
expect_leader '紐付け: 紐付いていない'
reset
final_ok
unlinked
echo 1 >"$test_dir/unlinked-status"
run final-1
expect_status 0
body=$(posted_body)
[[ $body == *'登録できませんでした。ホストでセットアップを流し直してください。'* ]] || fail "登録できなかった旨がない: $body"
[[ $body != *'見張り:'* ]] || fail "見張りの行を書いてはいけない: $body"
reset
final_ok
unlinked
printf '{"id": "rule-1"}\n' >"$test_dir/unlinked-out"
run final-1
expect_status 0
[[ $(posted_body) == *'登録できませんでした。ホストでセットアップを流し直してください。'* ]] || fail "見張りの行がないのに、登録できなかった旨がない: $(posted_body)"
# 紐付いているときは、unlinked を流さない。
reset
final_ok
run final-1
expect_status 0
expect_call_lacks pr-watch-calls unlinked
expect_call_lacks pr-watch-calls ci-now
expect_call_lacks pr-watch-calls ci-held
echo 'PASS review-next-decide: unlinked は、紐付け: の行なら止まり、0 以外や行なしなら見張りなしで進み、紐付いていれば流さない'

# ---- 規則の登録とコンフリクトと CI の止まる値。止まるときは、書かず、状態も変えない。
reset
final_ok
echo 1 >"$test_dir/conflicts-status"
run final-1
expect_leader 'コンフリクトの規則を入れ直せない'
reset
final_ok
printf 'コンフリクト: CONFLICTING head: %s\n' "$sha" >"$test_dir/conf-out"
run final-1
expect_leader 'コンフリクト: CONFLICTING'
expect_call_lacks pr-watch-calls 'conflicts test-issue'
reset
final_ok
unlinked
printf 'CI %s: 失敗あり（lint）\n' "${sha:0:7}" >"$test_dir/cinow-out"
run final-1
expect_leader "CI ${sha:0:7}: 失敗あり（lint）"
expect_call_lacks pr-watch-calls 'conflicts test-issue'
reset
final_ok
unlinked
printf 'CI %s: 失敗あり（テスト）\n' "${sha:0:7}" >"$test_dir/held-out"
run final-1
expect_leader '保留した CI の失敗がある'
reset
final_ok
unlinked
echo 1 >"$test_dir/cinow-status"
run final-1
expect_leader 'CI のその場の確認が 0 以外で終わった'
# コンフリクトの行が出なければ、未確認として書く。
reset
final_ok
: >"$test_dir/conf-out"
run final-1
expect_status 0
[[ $(posted_body) == *$'\nコンフリクト: 未確認 head: '"$sha"$' 理由: 判定の行が出なかった\n'* ]] || fail "未確認の行がない: $(posted_body)"
echo 'PASS review-next-decide: マージの依頼の確認で止まる値は、書かず、状態も変えずにリーダーに任せる'

# ---- head の照合。
reset
final_ok
printf '{"headRefOid": "%s"}\n' "$old" >"$test_dir/head.json"
run final-1
expect_leader "PR の今の head（${old}）が最終レビューの確認したコミット（${sha}）と違う"
expect_call_lacks pr-watch-calls 'conflicts test-issue'
# 確認したコミットが短い SHA でも、head の先頭と合えば一致とする。
reset
final_ok
add res-short claude-principal $'/note\n返事の回: final-1\n確認したコミット: '"${sha:0:7}"$'\n設計への指摘: なし\n\n✅ demo-claude-principal-test: 結果' final-1
run final-1
expect_status 0
reset
final_ok
echo 1 >"$test_dir/head-fail"
run final-1
expect_failure 'PR の今の head を読めない'
reset
final_ok
printf '{"headRefOid": "short"}\n' >"$test_dir/head.json"
run final-1
expect_failure 'PR の今の head を読めない'
# 最上位の役が名簿になければ照合せず、マージの依頼の head は PR の今の head にする。
reset
set_roster orchestrator code-reviewer qa
ok_round
printf '{"headRefOid": "%s"}\n' "$old" >"$test_dir/head.json"
run round-1
expect_merge_posted "$(merge_body round-1 "$old" "コンフリクト: MERGEABLE head: $sha" '✅ demo-code-reviewer-test: 結果' '✅ demo-qa-test: 結果')"
echo 'PASS review-next-decide: 最上位の役があれば、PR の今の head を最終レビューの確認したコミットと照合し、一致しなければ書かない'

# ---- QA の確認。QA が選ばれる変更なのに、組に QA の結果がなければ、確認を流さずにリーダーに任せる。
reset
set_merge_roster
base_round_without_qa() {
	add pr-made orchestrator "PR を作りました ${pr_url}" ""
	review_round round-1 "$sha" code-reviewer
	all_ok round-1 "$sha" code-reviewer
	set_principal_pick claude-principal
}
base_round_without_qa
final_round final-1 "$sha" round-1
result final-1 claude-principal ✅ "$sha" なし
run final-1
expect_leader 'QA が選ばれる変更なのに、組に QA の結果がない'
expect_no_calls pr-watch-calls
expect_no_calls head-calls
# 画面に触れない変更なら、QA が選ばれないので、結果がなくても進む。
set_changed_files README.md
run final-1
expect_merge_posted "$(merge_body final-1 "$sha" "$conf_line" '✅ demo-claude-principal-test: 結果' '✅ demo-code-reviewer-test: 結果')" final-1
# 画面に触れる変更なら、QA が選ばれるので、結果がなければ止まる。
reset
set_merge_roster
base_round_without_qa
final_round final-1 "$sha" round-1
result final-1 claude-principal ✅ "$sha" なし
set_changed_files web/App.tsx
run final-1
expect_leader 'QA が選ばれる変更なのに、組に QA の結果がない'
# 印「重要」があれば、有効な観点がすべて選ばれる。
reset
set_merge_roster
base_round_without_qa
final_round final-1 "$sha" round-1
result final-1 claude-principal ✅ "$sha" なし
set_changed_files README.md
set_issue_labels label-imp
run final-1
expect_leader 'QA が選ばれる変更なのに、組に QA の結果がない'
# QA の役が名簿になければ、確かめない。
reset
set_roster orchestrator code-reviewer claude-principal
add pr-made orchestrator "PR を作りました ${pr_url}" ""
review_round round-1 "$sha" code-reviewer
all_ok round-1 "$sha" code-reviewer
set_principal_pick claude-principal
final_round final-1 "$sha" round-1
result final-1 claude-principal ✅ "$sha" なし
run final-1
expect_status 0
[[ $(<"$test_dir/out") == $'次の依頼: マージの依頼'* ]] || fail "QA の役がないのに止まっている: $(<"$test_dir/out")"
echo 'PASS review-next-decide: QA が選ばれる変更で組に QA の結果がなければ、確認を流さずにリーダーに任せる'

# ---- 状態と書けないとき。
reset
final_ok
touch "$test_dir/post-fail"
run final-1
expect_failure 'コメントの投稿に失敗した'
expect_no_calls status-calls
echo 'PASS review-next-decide: 書けないときはタスクの状態を変えない'
