#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-wait-report-test.sh で実行する。
# CLI を差し替え、実際のタスク・規則・エージェントには書き込まない。report と proceed の知らせ・次へ回す記録を確認する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

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

# すぐの読み直しでそろったときは、結果、同じ役の決める記録、決めるスクリプトの順に進む。知らせは書かない。
# 取得の順は、1 回目が結果の投稿前、2 回目が結果の投稿後、3 回目が決める記録の投稿後の読み直し。
both='result:a:r1:5 result:b:r2:6'
own_record='decide:a:posted-2:90'
reset_calls
build_comments $both >"$test_dir/comments.1.json"
cp "$test_dir/comments.1.json" "$test_dir/comments.2.json"
build_comments $both $own_record >"$test_dir/comments.json"
bash "$script" report test-issue trigger "$test_dir/result.md"
[[ $(list_count) == 3 && -z $(slept) && $(posted_ready_count) == 0 && $(posted_decide_count) == 1 ]]
[[ $(decide_calls) == 'decide test-issue round' && $(<"$test_dir/decide-posted-at") == 2 ]]
assert_jq -s 'length == 2 and .[0].body == "/note\nqa result\n返事の回: round\n" and .[1].body == "/note\n返事の待ち: 次の依頼を決めます\n"' "$test_dir/posted.jsonl"
assert_jq -s 'all(.[]; .args | index("--parent") as $i | .[$i+1] == "trigger")' "$test_dir/posted.jsonl"
echo 'PASS report: 結果、同じ役の決める記録、決めるスクリプトの順に進み、知らせは書かない'

# 役が `返事の回:` の行を書いていても、スクリプトが付ける 1 行だけにする。/note のない結果には /note を足す。
reset_calls
printf '確かめたコミット: abc\n返事の回: other\n結果です' >"$test_dir/plain-result.md"
build_comments $both ready:orch:k1:7 >"$test_dir/comments.json"
bash "$script" report test-issue trigger "$test_dir/plain-result.md"
assert_jq -s '.[0].body == "/note\n確かめたコミット: abc\n結果です\n返事の回: round\n"' "$test_dir/posted.jsonl"
echo 'PASS report: 返事の回の行は、スクリプトが 1 行だけ付ける'

# すぐの読み直しで相手が見えず、待ってからの読み直しで見えたときは、そこで決める記録を書いて決める。
reset_calls
build_comments result:a:r1:5 >"$test_dir/comments.1.json"
cp "$test_dir/comments.1.json" "$test_dir/comments.2.json"
build_comments $both >"$test_dir/comments.3.json"
build_comments $both $own_record >"$test_dir/comments.json"
bash "$script" report test-issue trigger "$test_dir/result.md"
[[ $(slept) == 20 && $(list_count) == 4 && $(posted_decide_count) == 1 && $(decide_calls) == 'decide test-issue round' ]]
echo 'PASS report: 待ってからの読み直しで相手が見えれば、決める記録を書いて決める'

# 待っても返していない役がいれば、記録も知らせも書かず、決めない。読み直しは 1 回だけ。待つ秒数は REVIEW_WAIT_RECHECK_SECONDS に従う。
reset_calls
build_comments result:a:r1:5 >"$test_dir/comments.json"
bash "$script" report test-issue trigger "$test_dir/result.md"
[[ $(slept) == 20 && $(list_count) == 3 && $(jq -s length "$test_dir/posted.jsonl") == 1 && -z $(decide_calls) ]]
REVIEW_WAIT_RECHECK_SECONDS=7 bash "$script" report test-issue trigger "$test_dir/result.md"
[[ $(slept) == 20,7 ]]
echo 'PASS report: 待っても返していない役がいれば何も書かず決めない。待つ秒数は REVIEW_WAIT_RECHECK_SECONDS に従う'

# すでに知らせ・次の依頼・次へ回す記録・ほかの実行の決める記録があれば、決める記録を書かず、決めず、待たない。
for existing in ready:orch:k1:7 next:orch:n1:7 claim:orch:c1:7 decide:b:d1:7; do
	reset_calls
	build_comments $both "$existing" >"$test_dir/comments.json"
	bash "$script" report test-issue trigger "$test_dir/result.md"
	[[ $(jq -s length "$test_dir/posted.jsonl") == 1 && -z $(decide_calls) && -z $(slept) && $(list_count) == 2 ]]
done
echo 'PASS report: 知らせ・次の依頼・次へ回す記録・ほかの決める記録があれば、記録を書かず決めない'

# 決める記録が重なったら、決めるのは最も早い記録の実行だけ。同じ時刻は ID の順。
for race in decide:b:other:80:0 decide:b:other:95:1 decide:b:a0:90:0 decide:b:zz:90:1; do
	IFS=: read -r kind who id sec expect <<<"$race"
	reset_calls
	build_comments $both >"$test_dir/comments.1.json"
	cp "$test_dir/comments.1.json" "$test_dir/comments.2.json"
	build_comments $both $own_record "$kind:$who:$id:$sec" >"$test_dir/comments.json"
	bash "$script" report test-issue trigger "$test_dir/result.md"
	[[ $(posted_decide_count) == 1 && $(jq -s length "$test_dir/posted.jsonl") == 2 ]]
	if [[ $expect == 1 ]]; then [[ $(decide_calls) == 'decide test-issue round' ]]; else [[ -z $(decide_calls) ]]; fi
done
echo 'PASS report: 決める記録が重なったら、最も早い記録の実行だけが決める（同じ時刻は ID の順）'

# 記録を書いたあとに、次の依頼や次へ回す記録が見えたら、決めない。
for later in next:orch:n1:95 claim:orch:c1:95; do
	reset_calls
	build_comments $both >"$test_dir/comments.1.json"
	cp "$test_dir/comments.1.json" "$test_dir/comments.2.json"
	build_comments $both $own_record "$later" >"$test_dir/comments.json"
	bash "$script" report test-issue trigger "$test_dir/result.md"
	[[ -z $(decide_calls) && $(jq -s length "$test_dir/posted.jsonl") == 2 ]]
done
echo 'PASS report: 記録のあとに次の依頼や次へ回す記録が見えたら決めない'

# 自分の決める記録が読み直しで見えなければ、待って読み直し、見えたら決める。2 回待っても見えなければ、ID を添えて失敗する。
reset_calls
for n in 1 2 3; do build_comments $both >"$test_dir/comments.$n.json"; done
build_comments $both $own_record >"$test_dir/comments.json"
bash "$script" report test-issue trigger "$test_dir/result.md"
[[ $(slept) == 20 && $(list_count) == 4 && $(decide_calls) == 'decide test-issue round' && $(posted_decide_count) == 1 ]]
reset_calls
build_comments $both >"$test_dir/comments.json"
if bash "$script" report test-issue trigger "$test_dir/result.md" >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
[[ ! -s $test_dir/output && $(<"$test_dir/error") == '決める記録が読み直しで見えません: コメント posted-2' && $(slept) == '20,20' && $(list_count) == 5 ]]
[[ $(posted_decide_count) == 1 && -z $(decide_calls) ]]
echo 'PASS report: 自分の決める記録が見えなければ待って読み直し、2 回待っても見えなければ ID を添えて失敗する'

# 決められないとき（終了コード 3）は、理由を 2 行目に置いた知らせで、スクワッドのリーダーを起こす。
# 設計の見直しの回は、結果が ✅ でもコードの指摘でも、決める側が理由つきで決められないと返す。report は結果の中身を見ない。
for reason in '設計の見直しの回はリーダーが扱う' '設計への指摘: あり（設計のずれ）' '最上位の役の結果がタスクにない'; do
	reset_calls
	build_comments $both >"$test_dir/comments.1.json"
	cp "$test_dir/comments.1.json" "$test_dir/comments.2.json"
	build_comments $both $own_record >"$test_dir/comments.json"
	printf '次の依頼を決められません: %s\n' "$reason" >"$test_dir/decide-out"
	echo 3 >"$test_dir/decide-status"
	bash "$script" report test-issue trigger "$test_dir/result.md"
	[[ $(posted_ready_count) == 1 && $(jq -s length "$test_dir/posted.jsonl") == 3 ]]
	jq -s -e --arg reason "$reason" '.[2].body == "[@demo-squad](mention://squad/squad-test) 返事がそろいました。\n次の依頼を決められません: " + $reason + "\n\n待っていた役の結果が、すべてそろいました。\n\n返した役:\n- demo-code-reviewer-test\n- demo-qa-test\n"
		and (.[2].body | contains("mention://agent/") | not)
		and (.[2].args | index("--parent") as $i | .[$i+1] == "trigger")' "$test_dir/posted.jsonl" >/dev/null
done
echo 'PASS report: 決められないときは、理由の行を足した知らせでスクワッドのリーダーを起こす'

# 決める実行が失敗したとき（終了コード 1 など）は、標準エラーの最後の行を理由にする。空なら終了コードを書く。長い理由は 300 字で切る。
for failure in stderr empty long exit3; do
	reset_calls
	build_comments $both >"$test_dir/comments.1.json"
	cp "$test_dir/comments.1.json" "$test_dir/comments.2.json"
	build_comments $both $own_record >"$test_dir/comments.json"
	echo 1 >"$test_dir/decide-status"
	case $failure in
	stderr) printf '途中の経過\n次の依頼を書けません: コメントの投稿に失敗した\n\n' >"$test_dir/decide-err"; expect='コメントの投稿に失敗した' ;;
	empty) expect='squad-review-next decide が 1 で終わった' ;;
	long) printf '次の依頼を書けません: %s\n' "$(printf 'あ%.0s' $(seq 1 400))" >"$test_dir/decide-err"; expect="$(printf 'あ%.0s' $(seq 1 300))…" ;;
	exit3) echo 3 >"$test_dir/decide-status"; printf '別の出力\n' >"$test_dir/decide-out"; expect='squad-review-next decide が 3 で終わった' ;;
	esac
	bash "$script" report test-issue trigger "$test_dir/result.md"
	jq -s -e --arg reason "$expect" '.[2].body | startswith("[@demo-squad](mention://squad/squad-test) 返事がそろいました。\n次の依頼を決められません: " + $reason + "\n\n")' "$test_dir/posted.jsonl" >/dev/null
done
echo 'PASS report: 決める実行が失敗したときは、標準エラーの最後の行か終了コードを理由にして知らせる'

# 決めて書けたときは、スクリプトが書いたので知らせを書かない。
reset_calls
build_comments $both >"$test_dir/comments.1.json"
cp "$test_dir/comments.1.json" "$test_dir/comments.2.json"
build_comments $both $own_record >"$test_dir/comments.json"
printf '次の依頼: 修正\n' >"$test_dir/decide-out"
bash "$script" report test-issue trigger "$test_dir/result.md"
[[ $(posted_ready_count) == 0 && $(jq -s length "$test_dir/posted.jsonl") == 2 ]]
echo 'PASS report: 決めて書けたときは知らせを書かない'

# 回がなければ投稿せずエラー。
reset_calls
printf '[]' >"$test_dir/comments.json"
if bash "$script" report test-issue trigger "$test_dir/result.md" 2>"$test_dir/error"; then exit 1; fi
[[ ! -s $test_dir/posted.jsonl && -z $(slept) && -z $(decide_calls) ]]
echo 'PASS report: 回がなければ投稿しない'

# 知らせるスクワッドは、回の作者がリーダーのスクワッド。決める実行が書いた回は、役が作者なので、
# `前の回:` をたどってリーダーが書いた回のスクワッドを使う。たどるのは 10 回まで。たどれなければ、結果も書かずに失敗する。
chain_comments() { # 前の回をたどる回数 [リーダーが書いた回の作者]
	local hops=$1 leader=${2:-orchestrator}
	jq -n --slurpfile comment "$test_dir/comment-prototype.json" --arg a "$a" --arg b "$b" --arg leader "$leader" --argjson ts "$round_ts" --argjson hops "$hops" '
		def round($id; $author; $at; $prev): $comment[0] + {id: $id, author_type: "agent", author_id: $author, created_at: ($at | todateiso8601),
			content: ((if $prev == "" then "" else "前の回: " + $prev + "\n" end) + "返事を待つ役: [@review](mention://agent/" + $a + ") [@qa](mention://agent/" + $b + ")")};
		[round("r0"; $leader; $ts - 3600; "")]
		+ [range(1; $hops + 1) | round("r\(.)"; $a; $ts - 3600 + .; "r\(. - 1)")]
		+ [$comment[0] + {id: "x1", author_type: "agent", author_id: $a, created_at: (($ts + 5) | todateiso8601), content: "result"},
			$comment[0] + {id: "x2", author_type: "agent", author_id: $b, created_at: (($ts + 6) | todateiso8601), content: "result"}]'
}
for hops in 1 10; do
	reset_calls
	chain_comments "$hops" >"$test_dir/comments.json"
	echo 3 >"$test_dir/decide-status"
	printf '次の依頼を決められません: テスト\n' >"$test_dir/decide-out"
	jq --slurpfile comment "$test_dir/comment-prototype.json" --arg a "$a" --argjson ts "$round_ts" \
		'. + [$comment[0] + {id: "posted-2", author_type: "agent", author_id: $a, created_at: (($ts + 90) | todateiso8601), content: "/note\n返事の待ち: 次の依頼を決めます"}]' \
		"$test_dir/comments.json" >"$test_dir/comments.tmp"
	cp "$test_dir/comments.json" "$test_dir/comments.1.json"
	cp "$test_dir/comments.json" "$test_dir/comments.2.json"
	mv "$test_dir/comments.tmp" "$test_dir/comments.json"
	bash "$script" report test-issue trigger "$test_dir/result.md"
	jq -s -e --arg round "r$hops" '.[0].body | endswith("返事の回: " + $round + "\n")' "$test_dir/posted.jsonl" >/dev/null
	jq -s -e '.[2].body | startswith("[@demo-squad](mention://squad/squad-test) 返事がそろいました。\n")' "$test_dir/posted.jsonl" >/dev/null
done
echo 'PASS report: 役が書いた回は、前の回を 10 回までたどり、リーダーが書いた回のスクワッドで知らせる'
for broken in 11 leaderless; do
	reset_calls
	case $broken in
	11) chain_comments 11 >"$test_dir/comments.json" ;;
	leaderless) chain_comments 3 not-a-leader >"$test_dir/comments.json" ;;
	esac
	if bash "$script" report test-issue trigger "$test_dir/result.md" >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
	[[ ! -s $test_dir/output && $(<"$test_dir/error") == '知らせるスクワッドを決められません'* ]]
	[[ ! -s $test_dir/posted.jsonl && -z $(slept) && -z $(decide_calls) && $(list_count) == 1 ]]
done
echo 'PASS report: 前の回を 10 回たどってもリーダーの回に着かなければ、何も投稿せずに失敗する'

# 結果投稿後の失敗は、未返答とは区別して返す。結果は再投稿しない。決める実行は流さない。
# 2 回目の取得は結果の投稿直後、3 回目は決める記録の投稿後の読み直し。
for read_at in 2 3; do
	for failure in cli json round; do
		reset_calls
		build_comments $both >"$test_dir/comments.json"
		case $failure in
		cli) echo "$read_at" >"$test_dir/fail-list-at" ;;
		json) printf 'invalid json' >"$test_dir/comments.$read_at.json" ;;
		round) jq '.[0].content = null' "$test_dir/comments.json" >"$test_dir/comments.$read_at.json" ;;
		esac
		if bash "$script" report test-issue trigger "$test_dir/result.md" >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
		[[ -s $test_dir/error && ! -s $test_dir/output && $(list_count) == "$read_at" && -z $(decide_calls) && -z $(slept) ]]
		if [[ $failure == cli ]]; then [[ $(<"$test_dir/error") == 'CLI mock comment list failure' ]]; fi
		assert_jq -s --argjson n "$((read_at - 1))" 'length == $n and .[0].body == "/note\nqa result\n返事の回: round\n"' "$test_dir/posted.jsonl"
		echo "PASS report: 読み直し ${read_at} 回目の ${failure} 失敗を返し、結果を再投稿せず、決めない"
	done
done

# 決める記録の投稿の失敗と、知らせの投稿の失敗も、そのまま返す。再投稿しない。
reset_calls
build_comments $both >"$test_dir/comments.json"
echo 2 >"$test_dir/fail-add-at"
if bash "$script" report test-issue trigger "$test_dir/result.md" >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
[[ $(<"$test_dir/error") == 'CLI mock comment add failure' && ! -s $test_dir/output && $(list_count) == 2 && -z $(decide_calls) && -z $(slept) ]]
assert_jq -s 'length == 1 and .[0].body == "/note\nqa result\n返事の回: round\n"' "$test_dir/posted.jsonl"
assert_jq -s '[.[] | select(.[0:3] == ["issue", "comment", "add"])] | length == 2' "$test_dir/calls.jsonl"
echo 'PASS report: 決める記録の投稿の失敗を返し、再投稿せず、決めない'

reset_calls
build_comments $both >"$test_dir/comments.1.json"
cp "$test_dir/comments.1.json" "$test_dir/comments.2.json"
build_comments $both $own_record >"$test_dir/comments.json"
echo 3 >"$test_dir/decide-status"
printf '次の依頼を決められません: テスト\n' >"$test_dir/decide-out"
echo 3 >"$test_dir/fail-add-at"
if bash "$script" report test-issue trigger "$test_dir/result.md" >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
[[ $(<"$test_dir/error") == 'CLI mock comment add failure' && ! -s $test_dir/output && $(decide_calls) == 'decide test-issue round' ]]
assert_jq -s 'length == 2' "$test_dir/posted.jsonl"
echo 'PASS report: 知らせの投稿の失敗を返し、再投稿しない'

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

# proceed: 決める記録から 15 分たっていなければ、知らせがなくても、決める実行の途中なので何も書かず、見張りも消さない。
reset_calls
build_comments $both decide:a:d1:90 >"$test_dir/comments.json"
output=$(bash "$script" proceed test-issue watch-trigger)
[[ $output == $'/note\n返事の待ち: スクリプトが次の依頼を決めている' && ! -s $test_dir/posted.jsonl && -z $(slept) && $(deleted_rules) == 0 && $(list_count) == 1 ]]
output=$(REVIEW_WAIT_TEST_NOW=$((now + 869)) bash "$script" proceed test-issue watch-trigger)
[[ $output == $'/note\n返事の待ち: スクリプトが次の依頼を決めている' && ! -s $test_dir/posted.jsonl ]]
echo 'PASS proceed: 決める記録から 15 分たっていなければ、何も書かずに待つ'

# proceed: 決める記録から 15 分以上たち、知らせがなければ、拾い直しの知らせと次へ回す記録を書いて進む。
# 決める記録は、次へ回す記録として数えない。自分の記録だけが次へ回す記録になる。
reset_calls
build_comments $both decide:a:d1:90 >"$test_dir/comments.1.json"
build_comments $both decide:a:d1:90 ready:orch:posted-1:91 claim:orch:posted-2:92 >"$test_dir/comments.json"
output=$(REVIEW_WAIT_TEST_NOW=$((now + 870)) bash "$script" proceed test-issue watch-trigger)
[[ $output == '返事の待ち: 次に進む' && $(posted_ready_count) == 1 && $(posted_claim_count) == 1 && $(posted_decide_count) == 0 ]]
echo 'PASS proceed: 15 分以上たった決める記録は拾い直しを止めず、自分の次へ回す記録だけが数えられる'

# proceed: 決める記録が新しくても、そろった知らせがあれば（決められなかった回）、次へ回す記録を書いて進む。
reset_calls
build_comments $both decide:a:d1:90 ready:orch:k1:95 >"$test_dir/comments.1.json"
build_comments $both decide:a:d1:90 ready:orch:k1:95 claim:orch:posted-1:96 >"$test_dir/comments.json"
output=$(bash "$script" proceed test-issue k1)
[[ $output == '返事の待ち: 次に進む' && $(posted_ready_count) == 0 && $(posted_claim_count) == 1 ]]
echo 'PASS proceed: 決める記録が新しくても、知らせで起きた実行は次へ回す記録を書いて進む'

# proceed: 次の依頼が書かれた回（前の回で回を指すコメントがある）は、決める記録の経過によらず、何も書かずに回ごと済み。
reset_calls
build_comments $both decide:a:d1:90 next:orch:n1:95 >"$test_dir/comments.json"
for at in "$now" $((now + 870)); do
	output=$(REVIEW_WAIT_TEST_NOW=$at bash "$script" proceed test-issue watch-trigger)
	[[ $output == $'/note\n返事の待ち: 回ごと済み' && ! -s $test_dir/posted.jsonl && $(deleted_rules) == 0 ]]
done
echo 'PASS proceed: 次の依頼が書かれた回は、何も書かずに回ごと済み'
