#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-next-decide-route-test.sh で実行する。
# squad-review-next decide の判定のうち、回の種類・返事の組・書き済み・頼み直し・設計への指摘を確かめる。準備は tests/review-next-decide-common.sh にある。
set -euo pipefail
source "$(dirname "$0")/review-next-decide-common.sh"
reset

# ---- 早い止まり: 回の種類が決められない、返事が読めない。ネットワークを使わずにリーダーへ任せる。
add round-1 orchestrator $'見直しの種類: 設計の見直し\n確認するコミット: '"$sha"$'\n返事を待つ役: '"$(mentions claude-principal)"
run round-1
expect_leader '設計の見直しの回はリーダーが扱う'
expect_no_calls pr-watch-calls
reset
add round-1 orchestrator $'見直しの種類: 設計と PR の見直し\n確認するコミット: '"$sha"$'\n返事を待つ役: '"$(mentions claude-principal)"
run round-1
expect_leader '設計の見直しの回はリーダーが扱う'
reset
add round-1 orchestrator $'見直しの種類: 謎の回\n確認するコミット: '"$sha"$'\n返事を待つ役: '"$(mentions qa)"
run round-1
expect_leader '回の種類が分からない'
reset
add round-1 orchestrator $'何でもない回\n確認するコミット: '"$sha"
run round-1
expect_leader '回の種類が分からない'
reset
add round-1 orchestrator $'観点: qa（テスト）\n確認するコミット: '"$sha"$'\n返事を待つ役: なし'
run round-1
expect_leader '返事を待つ役の行がない'
reset
add round-1 orchestrator $'観点: qa（テスト）\n確認するコミット: 未定\n返事を待つ役: '"$(mentions qa)"
run round-1
expect_leader '16 進でない'
reset
review_round round-1 "$sha" code-reviewer qa
result round-1 code-reviewer ✅ "$sha" なし
run round-1
expect_leader '返事の結果がない: qa'
expect_no_calls pr-watch-calls
reset
base_round
add res-early qa $'返事の回: round-1\n確認したコミット: 0123456\n設計への指摘: なし\n\n✅ demo-qa-test: 結果' ""
run round-1
expect_leader '返事の結果がない: code-reviewer'
echo 'PASS review-next-decide: 回の種類が決められない、または返事がそろわないときは、PR を見ずにリーダーに任せる'

# ---- 返事が読めない値は、前の読める返事に戻らず止まる。
unreadable() { # 本文
	reset
	base_round
	result round-1 code-reviewer ✅ "$sha" なし
	result round-1 qa ✅ "$sha" なし
	add "bad-$n" qa "$1"
	run round-1
	expect_leader '返事の結果が読めない: qa'
}
unreadable $'返事の回: round-1\n設計への指摘: なし\n✅ demo-qa-test: 結果'
unreadable $'返事の回: round-1\n確認したコミット: 0123456\n設計への指摘: たぶん\n✅ demo-qa-test: 結果'
unreadable $'返事の回: round-1\n確認したコミット: 0123456\n設計への指摘: なし\n結果です'
unreadable $'返事の回: round-1\n確認したコミット: 0123456\n設計への指摘: なし\n✅ 結果'
echo 'PASS review-next-decide: 最新の返事が読めなければ、前の読める返事に戻らずリーダーに任せる'

# ---- 設計の見直しの回は、返事が ✅・コードの指摘・設計への指摘のどれでも、何も書かずにリーダーに任せる。
for kind in '設計の見直し' '設計と PR の見直し'; do
	for reply in '✅ 指摘なし|なし' '❌ コードの指摘|なし' '✅ 設計に指摘|あり'; do
		reset
		add pr-made orchestrator "PR を作りました ${pr_url}" ""
		add round-1 orchestrator "見直しの種類: ${kind}"$'\n'"確認するコミット: ${sha}"$'\n'"返事を待つ役: $(mentions claude-principal)"
		result round-1 claude-principal "${reply%%|*}" "$sha" "${reply##*|}"
		run round-1
		expect_leader '設計の見直しの回はリーダーが扱う'
	done
done
echo 'PASS review-next-decide: 設計の見直しの回は、返事の中身によらず書かずにリーダーに任せる'

# ---- 結果のあとに、同じ役が返事の回の行を持たない記録や知らせを書いても、返事の組は結果から選ぶ。
reset
ok_round
run round-1
expect_status 0
expected=$(posted_body)
reset
ok_round
for role in code-reviewer qa; do
	add "decision-$role" "$role" $'/note\n決める記録: 返事がそろいました\n❌ demo-'"$role"$'-test: 知らせ'
	add "notice-$role" "$role" $'使用率の待ち: 15 分後に流し直します'
done
run round-1
expect_status 0
[[ $(posted_body) == "$expected" ]] || fail "返事の回の行がない記録が、組を変えた: $(posted_body)"
echo 'PASS review-next-decide: 結果のあとの記録や知らせは、返事の組を変えない'

# ---- 書き済み: 同じ回の依頼があれば何も書かない。待ちのコメントは書き済みにしない。
reset
ok_round
add next orchestrator $'次の依頼です\n前の回: round-1'
run round-1
expect_status 0
[[ $(<"$test_dir/out") == '次の依頼: 書き済み' ]] || fail "書き済みを出していない: $(<"$test_dir/out")"
expect_nothing_written
expect_no_calls pr-watch-calls
expect_no_calls pick-calls
reset
ok_round
add next orchestrator $'/note 前の回: round-1'
run round-1
[[ $(<"$test_dir/out") == '次の依頼: 書き済み' ]] || fail "/note 付きの書き済みを見つけていない: $(<"$test_dir/out")"
for waiting in '使用率の待ち: fix を待つ。' 'マージの前の CI の待ち: 待つ。'; do
	reset
	ok_round
	add next orchestrator "${waiting}"$'\n前の回: round-1'
	run round-1
	[[ $(<"$test_dir/out") != '次の依頼: 書き済み' ]] || fail "待ちのコメントを書き済みにしている: $waiting"
done
echo 'PASS review-next-decide: 同じ回に書いた依頼があれば書かず、使用率の待ちとマージ前の CI の待ちのコメントは書き済みにしない'

# ---- 頼み直し。確認したコミットが合わない役だけを、同じコミットの新しい回で頼み直す。
reset
base_round
result round-1 code-reviewer ✅ "$sha" なし
result round-1 qa ✅ "$old" なし
run round-1
expect_posted 頼み直し "$(printf '確認するコミット: %s\n返事を待つ役: %s\nコミットが合わず頼み直す役: qa\n前の回: round-1\n対象の PR: %s' "$sha" "$(mention qa)" "$pr_url")"
expect_calls watch-calls 'watch test-issue round-1 --agent-id orchestrator qa'
expect_no_calls pick-calls
# 先頭のコミットの一部（7 文字以上の前方一致）は合う。大文字でも合う。
reset
ok_round
result round-1 qa ✅ 0123456789ABCDEF なし
run round-1
expect_status 0
[[ $(<"$test_dir/out") == $'次の依頼: 最終レビュー'* ]] || fail "前方一致を合うと読んでいない: $(<"$test_dir/out")"
# 6 文字は短すぎるので合わない。
reset
base_round
result round-1 code-reviewer ✅ "$sha" なし
result round-1 qa ✅ 012345 なし
run round-1
expect_posted 頼み直し "$(printf '確認するコミット: %s\n返事を待つ役: %s\nコミットが合わず頼み直す役: qa\n前の回: round-1\n対象の PR: %s' "$sha" "$(mention qa)" "$pr_url")"
# 2 つの役が合わなければ、キーを「、」でつなぎ、見張りに両方を渡す。
reset
base_round
result round-1 code-reviewer ✅ "$old" なし
result round-1 qa ✅ "$old" なし
run round-1
expect_posted 頼み直し "$(printf '確認するコミット: %s\n返事を待つ役: %s %s\nコミットが合わず頼み直す役: code-reviewer、qa\n前の回: round-1\n対象の PR: %s' "$sha" "$(mention code-reviewer)" "$(mention qa)" "$pr_url")"
expect_calls watch-calls 'watch test-issue round-1 --agent-id orchestrator code-reviewer qa'
echo 'PASS review-next-decide: 確認したコミットが合わない役だけを、同じコミットの新しい回で頼み直す'

# 頼み直しの回の返事が合えば、前の回の返事とあわせて次へ進む（ここでは最終レビュー）。
retry_round() { # 回の ID 役 前の回
	add "$1" orchestrator "確認するコミット: $sha"$'\n'"返事を待つ役: $(mention "$2")"$'\n'"コミットが合わず頼み直す役: $2"$'\n'"前の回: $3"$'\n'"対象の PR: ${pr_url}"
}
reset
base_round
result round-1 code-reviewer ✅ "$sha" なし
result round-1 qa ✅ "$old" なし
retry_round round-2 qa round-1
result round-2 qa ✅ "$sha" なし
set_principal_pick claude-principal
run round-2
expect_posted 最終レビュー "$(final_request_body 'PR の差分全体' | sed 's/前の回: round-1/前の回: round-2/')" round-2
# 前の回の返事の古い（合わない）ものは、頼み直した役の分を新しい回の返事に置き換えるので読み直さない。
# 頼み直した回でも合わなければ、リーダーに任せる。
reset
base_round
result round-1 code-reviewer ✅ "$sha" なし
result round-1 qa ✅ "$old" なし
retry_round round-2 qa round-1
result round-2 qa ✅ "$old" なし
run round-2
expect_leader '前の回でも合わなかった役がいる: qa'
# 頼み直しの回の返事が ❌ なら、前の回の ✅ とあわせて修正の依頼になる。
reset
base_round
result round-1 code-reviewer ✅ "$sha" なし
result round-1 qa ✅ "$old" なし
retry_round round-2 qa round-1
result round-2 qa ❌ "$sha" なし
run round-2
expect_status 0
[[ $(<"$test_dir/out") == $'次の依頼: 修正'* ]] || fail "修正の依頼でない: $(<"$test_dir/out")"
grep -q '直す指摘: qa（' <<<"$(posted_body)" || fail "直す指摘が qa でない: $(posted_body)"
# 名簿にない役の返事が合わなければ、頼み直せないのでリーダーに任せる。
reset
add pr-made orchestrator "PR を作りました ${pr_url}" ""
add round-1 orchestrator "確認するコミット: $sha"$'\n'"返事を待つ役: $(mentions qa) [@ghost](mention://agent/ghost)"$'\n'"観点: qa（テスト）"
result round-1 qa ✅ "$sha" なし
result round-1 ghost ✅ "$old" なし
run round-1
expect_leader '名簿にない: ghost'
echo 'PASS review-next-decide: 返事の組は前の回をたどって作り、頼み直した回でも合わなければリーダーに任せる'

# ---- 設計への指摘: あり は、PR の確認のあとでリーダーに任せる。
reset
base_round
result round-1 code-reviewer ✅ "$sha" なし
result round-1 qa ⚠️ "$sha" あり
run round-1
expect_leader '設計への指摘: あり（qa）'
expect_call_has pr-watch-calls 'link-check test-issue'
# 設計への指摘: あり が ❌ と同じ回にあっても、修正より先にリーダーに任せる。
reset
base_round
result round-1 code-reviewer ❌ "$sha" あり
result round-1 qa ✅ "$sha" なし
run round-1
expect_leader '設計への指摘: あり（code-reviewer）'
expect_no_calls pick-calls
# 紐付けの判定は設計への指摘より先なので、紐付けが止まる値ならその理由で止まる。
reset
base_round
result round-1 code-reviewer ✅ "$sha" あり
result round-1 qa ✅ "$sha" なし
echo '紐付け: 別のタスクに紐付いている pr: https://github.com/demo/project/pull/7' >"$test_dir/link-out"
run round-1
expect_leader '紐付け: 別のタスクに紐付いている'
echo 'PASS review-next-decide: 設計への指摘があれば、修正より先にリーダーに任せる'
