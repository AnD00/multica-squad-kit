#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-wait-report-test.sh で実行する。
# CLI を差し替え、実際のタスク・規則・エージェントには書き込まない。report と proceed の知らせ・次へ回す記録を確かめる。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
if [[ ${SQUAD_CLI_TEST_COMPARING:-} != 1 ]]; then
	source "$root/tests/cli-mode-test-lib.sh"
	cli_test_compare_modes "$0" "$@"
	exit $?
fi

source "$root/tests/review-wait-test-lib.sh"

round_ts=$((now - 120))
round_time=$(jq -nr --argjson ts "$round_ts" '$ts | todateiso8601')

# /note 付きとふつうのコメントで返した 2 役がそろい、知らせがない回を拾い直す。
reset_calls
build_comments result:a:r1:5 plain-result:b:r2:6 >"$test_dir/comments.json"
printf '[]' >"$test_dir/runs.json"
check_status '返事の待ち: 返事がそろっていて、まだ次へ回していない'
[[ ! -s $test_dir/posted.jsonl ]]
echo 'PASS status: /note 付きとふつうのコメントで返した回も、知らせがなければ拾い直す'

# 同じ状態で proceed を流すと、拾い直しの知らせと次へ回す記録を 1 つずつ書いて進む。
reset_calls
build_comments result:a:r1:5 plain-result:b:r2:6 >"$test_dir/comments.1.json"
build_comments result:a:r1:5 plain-result:b:r2:6 ready:orch:posted-1:90 claim:orch:posted-2:91 >"$test_dir/comments.json"
output=$(bash "$script" proceed test-issue r2)
[[ $output == '返事の待ち: 次に進む' && $(posted_ready_count) == 1 && $(posted_claim_count) == 1 ]]
assert_jq -s 'length == 2 and (.[0].body | startswith("返事がそろいました（見張りで拾い直しました）。\n"))' "$test_dir/posted.jsonl"
echo 'PASS proceed: /note 付きとふつうのコメントの回を拾い直し、知らせを 1 つ書いて次に進む'

# 同じ秒に始まる形: 2 役が回と同じ秒に始まり、返した役のほかに失敗した役がいる。
reset_calls
build_comments result:a:r1:5 >"$test_dir/comments.json"
for state in failed cancelled; do
	{
		run_fixture "$a" completed "$round_ts"
		run_fixture "$b" "$state" "$round_ts" '利用上限'
	} | jq -s 'map(. + {trigger_comment_id: "round"})' >"$test_dir/runs.json"
	check_status "返事の待ち: 人間を呼ぶ"$'\n'"- demo-qa-test: ${state}（利用上限）"
done
echo 'PASS status: 同じ秒に始まった 2 役のうち、返した役を除いて失敗・取り消しの役だけを人間へ'

# 返した役がいても、同じ秒の前の回の失敗では人間を呼ばない。
{
	run_fixture "$a" completed "$round_ts" | jq '. + {trigger_comment_id: "round"}'
	run_fixture "$b" failed "$round_ts" | jq '. + {trigger_comment_id: "previous-round"}'
} | jq -s '.' >"$test_dir/runs.json"
check_status $'/note\n返事の待ち: 返っていない役は待ちか実行中なので何もしない'
echo 'PASS status: 同じ秒に始まった役が返し済みでも、前の回の失敗を除外'

# すぐの読み直しでそろったときは、待たずに知らせを書く。
reset_calls
build_comments result:a:r1:5 result:b:r2:6 >"$test_dir/comments.json"
bash "$script" report test-issue trigger "$test_dir/result.md"
[[ $(posted_ready_count) == 1 && -z $(slept) ]]
assert_jq -s 'length == 2 and .[0].body == "/note\nqa result\n"' "$test_dir/posted.jsonl"
assert_jq -s '.[1].body | startswith("[@demo-squad](mention://squad/squad-test) 返事がそろいました。\n\n") and (contains("mention://agent/") | not)' "$test_dir/posted.jsonl"
assert_jq -s 'all(.[]; .args | index("--parent") as $i | .[$i+1] == "trigger")' "$test_dir/posted.jsonl"
echo 'PASS report: すぐの読み直しでそろえば、待たずに知らせを書く'

# すぐの読み直しで相手が見えず、待ってからの読み直しで見えたときは、知らせが 1 つ出る。
reset_calls
build_comments result:a:r1:5 >"$test_dir/comments.1.json"
build_comments result:a:r1:5 >"$test_dir/comments.2.json"
build_comments result:a:r1:5 result:b:r2:6 >"$test_dir/comments.json"
bash "$script" report test-issue trigger "$test_dir/result.md"
[[ $(posted_ready_count) == 1 && $(slept) == 20 && $(list_count) == 3 ]]
echo 'PASS report: 待ってからの読み直しで相手が見えれば、知らせを 1 つ書く'

# 待っても返していない役がいれば、知らせを書かず、読み直しは 1 回だけ。
reset_calls
build_comments result:a:r1:5 >"$test_dir/comments.json"
bash "$script" report test-issue trigger "$test_dir/result.md"
[[ $(posted_ready_count) == 0 && $(slept) == 20 && $(list_count) == 3 ]]
echo 'PASS report: 待っても返していない役がいれば知らせを書かず、読み直しは 1 回だけ'

# 待つ秒数は REVIEW_WAIT_RECHECK_SECONDS に従う。
reset_calls
REVIEW_WAIT_RECHECK_SECONDS=7 bash "$script" report test-issue trigger "$test_dir/result.md"
[[ $(slept) == 7 ]]
echo 'PASS report: 待つ秒数は REVIEW_WAIT_RECHECK_SECONDS に従う'

# すでに知らせがあれば、書かず、待たない。
reset_calls
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 >"$test_dir/comments.json"
bash "$script" report test-issue trigger "$test_dir/result.md"
[[ $(posted_ready_count) == 0 && $(jq -s length "$test_dir/posted.jsonl") == 1 && -z $(slept) ]]
echo 'PASS report: 知らせがすでにあれば書かない'

# 回がなければ投稿せずエラー。
reset_calls
printf '[]' >"$test_dir/comments.json"
if bash "$script" report test-issue trigger "$test_dir/result.md" 2>"$test_dir/error"; then exit 1; fi
[[ ! -s $test_dir/posted.jsonl && -z $(slept) ]]
echo 'PASS report: 回がなければ投稿しない'

# 結果投稿後の失敗は、未返答とは区別して返す。結果は再投稿しない。
# 2 回目の取得は結果投稿の直後、3 回目は待ってからの読み直し。
for read_at in 2 3; do
	for failure in cli json round; do
		reset_calls
		build_comments result:a:r1:5 >"$test_dir/comments.json"
		case $failure in
		cli) echo "$read_at" >"$test_dir/fail-list-at" ;;
		json) printf 'invalid json' >"$test_dir/comments.$read_at.json" ;;
		round) jq '.[0].content = null' "$test_dir/comments.json" >"$test_dir/comments.$read_at.json" ;;
		esac
		if bash "$script" report test-issue trigger "$test_dir/result.md" >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
		[[ -s $test_dir/error && ! -s $test_dir/output && $(list_count) == "$read_at" ]]
		if [[ $failure == cli ]]; then [[ $(<"$test_dir/error") == 'CLI mock comment list failure' ]]; fi
		assert_jq -s 'length == 1 and .[0].body == "/note\nqa result\n"' "$test_dir/posted.jsonl"
		if [[ $read_at == 2 ]]; then [[ -z $(slept) ]]; else [[ $(slept) == 20 ]]; fi
		echo "PASS report: 読み直し ${read_at} 回目の ${failure} 失敗を返し、結果を再投稿しない"
	done

	reset_calls
	if [[ $read_at == 3 ]]; then
		build_comments result:a:r1:5 >"$test_dir/comments.2.json"
	fi
	build_comments result:a:r1:5 result:b:r2:6 >"$test_dir/comments.json"
	echo 2 >"$test_dir/fail-add-at"
	if bash "$script" report test-issue trigger "$test_dir/result.md" >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
	[[ $(<"$test_dir/error") == 'CLI mock comment add failure' && ! -s $test_dir/output && $(list_count) == "$read_at" ]]
	assert_jq -s 'length == 1 and .[0].body == "/note\nqa result\n"' "$test_dir/posted.jsonl"
	assert_jq -s '[.[] | select(.[0:3] == ["issue", "comment", "add"])] | length == 2' "$test_dir/calls.jsonl"
	if [[ $read_at == 2 ]]; then [[ -z $(slept) ]]; else [[ $(slept) == 20 ]]; fi
	echo "PASS report: 読み直し ${read_at} 回目の知らせ投稿の失敗を返し、再投稿しない"
done

# proceed: 知らせがなければ、拾い直しの知らせと記録を書き、いちばん早い記録なので進む。
reset_calls
build_comments result:a:r1:5 result:b:r2:6 >"$test_dir/comments.1.json"
build_comments result:a:r1:5 result:b:r2:6 ready:orch:posted-1:90 claim:orch:posted-2:91 >"$test_dir/comments.json"
output=$(bash "$script" proceed test-issue watch-trigger)
[[ $output == '返事の待ち: 次に進む' && $(slept) == 20 && $(deleted_rules) == 2 ]]
assert_jq -s 'length == 2 and all(.[]; .args | index("--parent") as $i | .[$i+1] == "watch-trigger")
	and (.[0].body | startswith("返事がそろいました（見張りで拾い直しました）。\n\n待っていた役の結果が、すべてそろいました。\n\n返した役:\n"))
	and (.[0].body | contains("mention://") | not)
	and .[1].body == "/note\n返事の待ち: この回を次へ回します\n"' "$test_dir/posted.jsonl"
echo 'PASS proceed: 知らせがなければ拾い直しの知らせと記録を書き、見張りを消して次に進む'

# proceed: 知らせで起きた実行は、記録だけを書いて進む。
reset_calls
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 >"$test_dir/comments.1.json"
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 claim:orch:posted-1:8 >"$test_dir/comments.json"
output=$(bash "$script" proceed test-issue k1)
[[ $output == '返事の待ち: 次に進む' && $(posted_ready_count) == 0 && $(posted_claim_count) == 1 && $(slept) == 20 && $(deleted_rules) == 2 ]]
echo 'PASS proceed: 知らせで起きた実行は、記録だけを書いて次に進む'

# proceed: 1 回目は次に進み、記録が残った 2 回目は書かず、待たずに回ごと済み。
reset_calls
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 claim:orch:posted-1:8 >"$test_dir/comments.json"
output=$(bash "$script" proceed test-issue k1)
[[ $output == $'/note\n返事の待ち: 回ごと済み' && ! -s $test_dir/posted.jsonl && -z $(slept) && $(deleted_rules) == 0 ]]
echo 'PASS proceed: 記録が残った回では、書かずに回ごと済み'

# proceed: 2 つの実行がほぼ同時に記録を書いたら、進むのは早い記録の実行だけ。
reset_calls
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 >"$test_dir/comments.1.json"
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 claim:orch:c0:8 claim:orch:posted-1:9 >"$test_dir/comments.json"
output=$(bash "$script" proceed test-issue k1)
[[ $output == $'/note\n返事の待ち: 回ごと済み' && $(deleted_rules) == 0 ]]
echo 'PASS proceed: 記録が重なったら、早い記録の実行だけが進む'

# proceed: 同じ時刻の記録は ID の順で選ぶ。
reset_calls
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 >"$test_dir/comments.1.json"
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 claim:orch:posted-1:8 claim:orch:zz:8 >"$test_dir/comments.json"
[[ $(bash "$script" proceed test-issue k1) == '返事の待ち: 次に進む' ]]
reset_calls
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 >"$test_dir/comments.1.json"
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 claim:orch:posted-1:8 claim:orch:a0:8 >"$test_dir/comments.json"
[[ $(bash "$script" proceed test-issue k1) == $'/note\n返事の待ち: 回ごと済み' ]]
echo 'PASS proceed: 同じ時刻の記録は ID の順'

# proceed: 書いた記録が 2 回とも見えなければ、ID を添えて失敗する。
reset_calls
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 >"$test_dir/comments.json"
if bash "$script" proceed test-issue k1 >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
[[ ! -s $test_dir/output && $(<"$test_dir/error") == *'posted-1'* && $(slept) == '20,20' && $(list_count) == 3 ]]
[[ $(posted_claim_count) == 1 && $(deleted_rules) == 0 ]]
echo 'PASS proceed: 記録が 2 回とも見えなければ、ID を添えて失敗する'

# proceed: 返していない役がいる回と、回がないときは何もしない。
reset_calls
build_comments result:a:r1:5 >"$test_dir/comments.json"
output=$(bash "$script" proceed test-issue watch-trigger)
[[ $output == $'/note\n返事の待ち: 返っていない役がいるので何もしない' && ! -s $test_dir/posted.jsonl && -z $(slept) && $(deleted_rules) == 0 ]]
printf '[]' >"$test_dir/comments.json"
output=$(bash "$script" proceed test-issue watch-trigger)
[[ $output == $'/note\n返事の待ち: 回がないので何もしない' && -z $(slept) ]]
echo 'PASS proceed: 返していない役がいる回と回なしでは何もしない'

# proceed: 待つ間に新しい回が書かれたら、前の回の知らせでは進まない。
reset_calls
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 >"$test_dir/comments.1.json"
# build_comments は comments.json を書いて読むので、同じファイルへのリダイレクトとパイプでつながない。
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 >"$test_dir/comments.base.json"
jq --slurpfile comment "$test_dir/comment-prototype.json" --arg a "$a" --arg time "$(jq -nr --argjson ts "$((round_ts + 30))" '$ts | todateiso8601')" \
	'. + [$comment[0] + {id: "round2", author_type: "agent", author_id: "orchestrator", created_at: $time, content: ("返事を待つ役: [@review](mention://agent/" + $a + ")")}]' "$test_dir/comments.base.json" >"$test_dir/comments.json"
output=$(bash "$script" proceed test-issue k1)
[[ $output == $'/note\n返事の待ち: 新しい回があるので何もしない' && $(deleted_rules) == 0 && $(posted_claim_count) == 1 ]]
echo 'PASS proceed: 待つ間に新しい回が書かれたら何もしない'

# proceed: CLI の失敗では、進むと答えずにエラー。
reset_calls
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 >"$test_dir/comments.1.json"
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 claim:orch:posted-1:8 >"$test_dir/comments.json"
printf 'issue wakeup list' >"$test_dir/fail"
if bash "$script" proceed test-issue k1 >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
[[ ! -s $test_dir/output ]]
rm "$test_dir/fail"
echo 'PASS proceed: CLI 失敗では次に進むと答えずエラー'
