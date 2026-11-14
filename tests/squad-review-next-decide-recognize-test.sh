#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-next-decide-recognize-test.sh で実行する。準備は tests/review-next-decide-common.sh にある。
# squad-review-next decide の判定のうち、認める回と最終レビューの認め方を確かめる。
# 条件は docs/review-next-step.md の「認める回」「最終レビューの回と結果を認める条件」にある。制御記録は squad-review-next-decide-control-test.sh。
set -euo pipefail
source "$(dirname "$0")/review-next-decide-common.sh"
reset

# ---- 認める回。認めない回では、何も書かずに理由つきで終了 3 になる。
reset
ok_round
add round-9 claude-fixer "確認するコミット: $sha"$'\n'"返事を待つ役: $(mentions qa)"$'\n'"観点: qa（テスト）"$'\n'"前の回: round-1"
run round-9
expect_leader '回を認められない'
# 前の回: がなく、リーダーの回にもたどれなければ、スクワッドを決められず、何も書かずに失敗する。
reset
ok_round
add round-9 claude-fixer "確認するコミット: $sha"$'\n'"返事を待つ役: $(mentions qa)"$'\n'"観点: qa（テスト）"
run round-9
expect_failure 'スクワッドを決められない'
reset
ok_round
add round-9 orchestrator $'> 返事を待つ役: '"$(mentions qa)"$'\n確認するコミット: '"$sha"
run round-9
expect_leader '制御記録を読めない（round-9: 引用）'
reset
ok_round
add round-9 orchestrator $'```\n返事を待つ役: '"$(mentions qa)"$'\n```\n確認するコミット: '"$sha"
run round-9
expect_leader '回を認められない（返事を待つ役: の行'
reset
ok_round
add round-9 qa $'/note\n返事の回: round-1\n返事を待つ役: '"$(mentions qa)"$'\n確認するコミット: '"$sha"$'\n前の回: round-1'
run round-9
expect_leader '回を認められない'
reset
ok_round
add round-9 human-1 "確認するコミット: $sha"$'\n'"返事を待つ役: $(mentions qa)"$'\n観点: qa（テスト）\n前の回: round-1'
run round-9
expect_leader '回を認められない'
# たどった途中に認めない回がある回。
reset
ok_round
add forged claude-fixer "確認するコミット: $sha"$'\n'"返事を待つ役: $(mentions qa)"$'\n観点: qa（テスト）'
add round-9 orchestrator "確認するコミット: $sha"$'\n'"返事を待つ役: $(mentions qa)"$'\n'"コミットが合わず頼み直す役: qa"$'\n'"前の回: forged"
result round-9 qa ✅ "$sha" なし
result forged qa ✅ "$old" なし
run round-9
expect_leader '回を認められない'
echo 'PASS review-next-decide: 認めない回（作者違い・囲み・結果・人間・途中に認めない回）と、読めない回（引用）では、何も書かず理由つきで終了 3 になる'

# 決める実行の役が書いた頼み直しの回は、リーダーの回につながれば認める。
reset
base_round
result round-1 code-reviewer ✅ "$sha" なし
result round-1 qa ✅ "$old" なし
add decide-qa qa $'/note\n返事の待ち: 次の依頼を決めます'
add round-2 qa "確認するコミット: $sha"$'\n'"返事を待つ役: $(mentions qa)"$'\n'"コミットが合わず頼み直す役: qa"$'\n'"前の回: round-1"$'\n'"対象の PR: ${pr_url}"
result round-2 qa ✅ "$sha" なし
set_principal_pick claude-principal
run round-2
expect_status 0
[[ $(<"$test_dir/out") == $'次の依頼: 最終レビュー'* ]] || fail "決める実行の役の頼み直しの回を認めていない: $(<"$test_dir/out")"
echo 'PASS review-next-decide: 決める実行の役が書いた頼み直しの回は、リーダーの回につながれば認める'

# ---- 最終レビューの認め方。
# 最終レビューの回を、条件を 1 つ外して作る。マージを頼まず in_review にもせず、理由つきで終了 3 になる。
final_case() { # 説明 作者 待つ役の行 確認するコミット 前の回の行 [理由]
	reset
	ok_round
	add final-1 "$2" "見直しの種類: 最終レビュー"$'\n'"確認するコミット: $4"$'\n'"見る範囲: PR の差分全体"$'\n'"返事を待つ役: $3"$'\n'"$principal_line"${5:+$'\n'"$5"}$'\n'"対象の PR: ${pr_url}"
	result final-1 "${7-claude-principal}" ✅ "$sha" なし
	run final-1
	expect_leader "${6-認められない（}"
	[[ -s $test_dir/status-calls ]] && fail "in_review にしている: $1"
	return 0
}
final_case '最上位の役でない役を待つ' orchestrator "$(mentions qa)" "$sha" '前の回: round-1' '最終レビューを認められない' qa
final_case 'リーダーでも決める実行の役でもない作者' claude-fixer "$(mentions claude-principal)" "$sha" '前の回: round-1'
final_case '前の回: がない' orchestrator "$(mentions claude-principal)" "$sha" ''
final_case '前の回: が指す回がない' orchestrator "$(mentions claude-principal)" "$sha" '前の回: round-99'
final_case '待つ役が 2 つ' orchestrator "$(mentions claude-principal qa)" "$sha" '前の回: round-1'
final_case '確認するコミット: が指す回と違う' orchestrator "$(mentions claude-principal)" "$old" '前の回: round-1'
# 前の回が設計の見直しの回、または最終レビューの回のときは、レビューと E2E の回でないので認めない。
reset
ok_round
add design-1 orchestrator "見直しの種類: 設計の見直し"$'\n'"確認するコミット: $sha"$'\n'"返事を待つ役: $(mentions claude-principal)"
add final-1 orchestrator "見直しの種類: 最終レビュー"$'\n'"確認するコミット: $sha"$'\n'"見る範囲: PR の差分全体"$'\n'"返事を待つ役: $(mentions claude-principal)"$'\n'"$principal_line"$'\n'"前の回: design-1"
result final-1 claude-principal ✅ "$sha" なし
run final-1
expect_leader '最終レビューを認められない'
# 認める最終レビューの回は、最上位の役の結果でマージの段に進む。
reset
set_merge_roster
ok_round
final_round final-1 "$sha" round-1
result final-1 claude-principal ✅ "$sha" なし
run final-1
expect_status 0
[[ $(<"$test_dir/out") == $'次の依頼: マージの依頼'* ]] || fail "認める最終レビューの回で進んでいない: $(<"$test_dir/out")"
echo 'PASS review-next-decide: 最終レビューの回は、条件を 1 つでも満たさなければ、マージを頼まず in_review にもせず、理由つきで終了 3 になる'

# 最上位の役でない役の結果を、組と済みに数えない。
reset
set_merge_roster
ok_round
final_round final-1 "$sha" round-1
result final-1 qa ✅ "$sha" なし
run final-1
expect_leader '返事の結果がない: claude-principal'
# 同じコミットの認める最終レビューの回があっても、最上位の役の結果がなければ済みとしない（別のレビューの回 round-0b を指す最終レビューの回で、round-1 を流す）。
reset
set_merge_roster
ok_round
review_round round-0b "$sha" code-reviewer qa
final_round final-1 "$sha" round-0b
result final-1 qa ✅ "$sha" なし
run round-1
expect_leader '同じコミットの最終レビューが済んでいない'
echo 'PASS review-next-decide: 最上位の役でない役の結果は、最終レビューの組にも済みにも数えない'

# 元の回で流したとき、同じコミットの認めない最終レビューの回があれば終了 3 になる。認める回に最上位の役の結果がなければ済みとしない。
bad_final() { # 認めない最終レビューの回を、作者が最終レビューの記録を書けない役で足す
	add final-bad claude-fixer "見直しの種類: 最終レビュー"$'\n'"確認するコミット: $sha"$'\n'"見る範囲: PR の差分全体"$'\n'"返事を待つ役: $(mentions claude-principal)"$'\n'"前の回: round-1"
}
reset
set_merge_roster
ok_round
review_round round-0b "$sha" code-reviewer qa
final_round final-1 "$sha" round-0b
result final-1 claude-principal ✅ "$sha" なし
bad_final
run round-1
expect_leader '最終レビューを認められない'
reset
set_merge_roster
ok_round
review_round round-0b "$sha" code-reviewer qa
final_round final-1 "$sha" round-0b
result final-1 qa ✅ "$sha" なし
bad_final
result final-bad claude-principal ✅ "$sha" なし
run round-1
expect_leader '最終レビューを認められない'
echo 'PASS review-next-decide: 元の回で流したとき、同じコミットの認めない最終レビューの回があれば終了 3 になり、認める回に結果がなければ済みとしない'

# 修正の依頼の 3: 認めない回への最上位の役の結果を数えない。
reset
set_merge_roster
ok_round
review_round round-0b "$sha" code-reviewer qa
final_round final-1 "$sha" round-0b
result final-1 claude-principal ❌ "$sha" なし
bad_final
result final-bad claude-principal ✅ "$sha" なし
run round-1
expect_leader '最終レビューを認められない'
echo 'PASS review-next-decide: 認めない回への最上位の役の結果を、修正の依頼にもマージの依頼にも数えない'
