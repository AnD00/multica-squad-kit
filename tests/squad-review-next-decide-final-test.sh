#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-next-decide-final-test.sh で実行する。
# squad-review-next decide の判定のうち、最終レビューの依頼・範囲・最終レビューの回の返事を確かめる。準備は tests/review-next-decide-common.sh にある。
set -euo pipefail
source "$(dirname "$0")/review-next-decide-common.sh"
reset

# ---- 最終レビュー。
# 実装の系統は、完了した実装・修正の実行の数で決める。
run_item=$(fixture issue-runs)
set_runs() { # 役:状態...
	jq -n --argjson base "$run_item" --args '[$ARGS.positional[] | split(":") as $p | $base + {agent_id: $p[0], status: $p[1]}]' -- "$@" >"$test_dir/runs.json"
}
final_pick_call() { printf 'pick test-issue principal%s --round round-1' "${1:+ $1}"; }
reset
ok_round
set_runs claude-implementer:completed claude-fixer:completed codex-fixer:completed claude-implementer:failed codex-implementer:failed
set_principal_pick codex-principal
run round-1
expect_posted 最終レビュー "$(final_request_body 'PR の差分全体' codex-principal)"
expect_calls pick-calls "$(final_pick_call Claude)"
expect_calls watch-calls 'watch test-issue round-1 --agent-id orchestrator codex-principal'
# 同数なら系統を指定しない。
reset
ok_round
set_runs claude-implementer:completed codex-fixer:completed
run round-1
expect_calls pick-calls "$(final_pick_call)"
# Codex が多ければ Codex を指定する。
reset
ok_round
set_runs codex-implementer:completed codex-fixer:completed claude-fixer:completed
run round-1
expect_calls pick-calls "$(final_pick_call Codex)"
# 実行がなければ設計の役の系統を使う。
reset
ok_round
run round-1
expect_calls pick-calls "$(final_pick_call Claude)"
reset
ok_round
set_designer_model gpt-5.5
run round-1
expect_calls pick-calls "$(final_pick_call Codex)"
# 実行を読めなければ、系統を指定せずに選ぶ。
reset
ok_round
touch "$test_dir/runs-fail"
run round-1
expect_status 0
expect_calls pick-calls "$(final_pick_call)"
echo 'PASS review-next-decide: 最終レビューは、実装の系統を実行の数から決めて、最上位の役を選ぶ'

# 範囲。前の最終レビューの最上位の役の結果の確認したコミットが祖先なら、そこからの差分にする。
prev_final() { # 確認したコミット
	final_round prev-final "$old" older-round
	result prev-final claude-principal ✅ "$1" なし
}
reset
prev_final fedcba9
ok_round
set_principal_pick claude-principal
run round-1
expect_posted 最終レビュー "$(final_request_body "fedcba9..$sha")"
expect_calls compare-calls "fedcba9...$sha"
# 同じコミットの比較（identical）も祖先にする。
reset
prev_final fedcba9
ok_round
fixture gh-compare | jq '.status = "identical"' >"$test_dir/compare.json"
run round-1
[[ $(posted_body) == *"見る範囲: fedcba9..$sha"* ]] || fail "identical を祖先にしていない: $(posted_body)"
# 祖先でない（diverged・behind）なら全体にする。
for state in diverged behind; do
	reset
	prev_final fedcba9
	ok_round
	fixture gh-compare | jq --arg state "$state" '.status = $state' >"$test_dir/compare.json"
	run round-1
	[[ $(posted_body) == *'見る範囲: PR の差分全体'* ]] || fail "$state を全体にしていない: $(posted_body)"
done
# 比較に失敗したら全体にする。
reset
prev_final fedcba9
ok_round
touch "$test_dir/compare-fail"
run round-1
expect_posted 最終レビュー "$(final_request_body 'PR の差分全体')"
# 前の結果のコミットが読めなければ、比較せずに全体にする。
reset
prev_final なし
ok_round
run round-1
expect_posted 最終レビュー "$(final_request_body 'PR の差分全体')"
expect_no_calls compare-calls
# 前の結果が複数なら、最新の結果を使う。
reset
final_round prev-final "$old" older-round
result prev-final claude-principal ✅ 1111111 なし
result prev-final claude-principal ✅ fedcba9 なし
ok_round
run round-1
[[ $(posted_body) == *"見る範囲: fedcba9..$sha"* ]] || fail "最新の結果を使っていない: $(posted_body)"
# 前の最終レビューがなければ全体にする。
reset
ok_round
run round-1
expect_posted 最終レビュー "$(final_request_body 'PR の差分全体')"
expect_no_calls compare-calls
echo 'PASS review-next-decide: 最終レビューの範囲は、前の最終レビューのコミットが祖先のときだけ差分にする'

# 最上位の役が名簿になければ、最終レビューを書かずにマージの段へ進む（このスクリプトでは未実装）。
reset
set_roster orchestrator code-reviewer qa ci-monitor
ok_round
run round-1
expect_leader 'マージの依頼'
expect_no_calls pick-calls
# 同じコミットの最終レビューがすでにあるなら、もう一度は頼まない。
reset
final_round final-1 "$sha" older
ok_round
run round-1
expect_leader 'マージの依頼'
expect_no_calls pick-calls
# 違うコミットの最終レビューは、同じコミットのものと見なさない。
reset
final_round final-0 "$old" older
ok_round
run round-1
expect_status 0
[[ $(<"$test_dir/out") == $'次の依頼: 最終レビュー'* ]] || fail "違うコミットの最終レビューを同じと見なしている: $(<"$test_dir/out")"
echo 'PASS review-next-decide: 最終レビューが要らないとき、または済んでいるときは、マージの段（未実装）に進む'

# 最終レビューの回の返事。
reset
ok_round
final_round final-1 "$sha" round-1
result final-1 claude-principal ✅ "$sha" なし
run final-1
expect_leader 'マージの依頼'
# 最上位の役が ❌ なら修正の依頼にする。
reset
ok_round
final_round final-1 "$sha" round-1
result final-1 claude-principal ❌ "$sha" なし
run final-1
expect_status 0
[[ $(<"$test_dir/out") == $'次の依頼: 修正'* ]] || fail "最上位の役の ❌ が修正でない: $(<"$test_dir/out")"
grep -q '直す指摘: claude-principal（' <<<"$(posted_body)" || fail "直す指摘が最上位の役でない: $(posted_body)"
# 最上位の役の確認したコミットが合わなければ、最終レビューの形で頼み直す。
final_retry_body() { # 範囲 振り分け 役
	printf '見直しの種類: 最終レビュー\n確認するコミット: %s\n見る範囲: %s\n返事を待つ役: %s\n振り分け: %s\nコミットが合わず頼み直す役: %s\n前の回: final-1\n対象の PR: %s' "$sha" "$1" "$(mention "$3")" "$2" "$3" "$pr_url"
}
reset
ok_round
final_round final-1 "$sha" round-1 "$old..$sha"
result final-1 claude-principal ✅ "$old" なし
run final-1
expect_posted 頼み直し "$(final_retry_body "$old..$sha" 'Claude で足りる。工程: principal' claude-principal)" final-1
expect_calls watch-calls 'watch test-issue final-1 --agent-id orchestrator claude-principal'
expect_no_calls pick-calls
# 最上位の役以外の合わないものが混じれば、最終レビューの形では頼み直せないのでリーダーに任せる。
reset
base_round
result round-1 code-reviewer ✅ "$old" なし
result round-1 qa ✅ "$sha" なし
final_round final-1 "$sha" round-1
result final-1 claude-principal ✅ "$old" なし
run final-1
expect_leader '最上位の役以外の確認したコミットが合わない'
# 見る範囲: か 振り分け: の行が回になければ、書き写せないのでリーダーに任せる。
reset
ok_round
add final-1 orchestrator "見直しの種類: 最終レビュー"$'\n'"確認するコミット: $sha"$'\n'"返事を待つ役: $(mentions claude-principal)"$'\n'"前の回: round-1"
result final-1 claude-principal ✅ "$old" なし
run final-1
expect_leader '見る範囲: か 振り分け: の行がない'
echo 'PASS review-next-decide: 最終レビューの回の返事は、マージの段・修正・最終レビューの形の頼み直しに分ける'
