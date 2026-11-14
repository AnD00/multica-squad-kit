#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-wait-report-unreadable-test.sh で実行する。
# squad-review-wait report が、最新の回の候補が読めないとき、結果は書き、決める記録を書かず、decide も流さず、理由つきの決まらない知らせでリーダーを起こすことを確かめる。
# 場面は docs/review-next-step.md の「本文の読み方のテスト」の表 2 の report の行。理由の出し方は「候補と読めないときの扱い」の表。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
source "$root/tests/review-wait-test-lib.sh"

round_ts=$((now - 120))
both='result:a:r1:5 result:b:r2:6'

# 候補は、回より後に作者がエージェントで書かれ、返事を待つ役: を含むコメント。読めない書き方で置く。
reason_body() { # 本文の JSON 文字列 理由
	local json=$1 reason=$2
	reset_calls
	build_comments $both | with_json x orchestrator agent 8 "$json" >"$test_dir/comments.1.json"
	cp "$test_dir/comments.1.json" "$test_dir/comments.2.json"
	cp "$test_dir/comments.1.json" "$test_dir/comments.json"
	bash "$script" report test-issue trigger "$test_dir/result.md" >"$test_dir/output" 2>"$test_dir/error" || { printf '終了コード 0 を期待した: %s\n' "$(<"$test_dir/error")" >&2; exit 1; }
	[[ $(jq -s length "$test_dir/posted.jsonl") == 2 ]] || { printf '結果と知らせの 2 件を期待した: %s\n' "$(<"$test_dir/posted.jsonl")" >&2; exit 1; }
	[[ $(posted_decide_count) == 0 ]] || { echo '決める記録を書いてはいけない' >&2; exit 1; }
	[[ -z $(decide_calls) ]] || { echo 'decide を流してはいけない' >&2; exit 1; }
	assert_jq -s --arg reason "$reason" '.[0].body == "/note\nqa result\n返事の回: round\n"
		and (.[1].body | startswith("[@demo-squad](mention://squad/squad-test) 返事がそろいました。\n次の依頼を決められません: " + $reason + "\n\n"))
		and (.[1].body | contains("mention://agent/") | not)
		and (.[1].args | index("--parent") as $i | .[$i+1] == "trigger")' "$test_dir/posted.jsonl"
}

reason_body "$(jq -nc '"> 返事を待つ役: [@qa](mention://agent/a)\n確認するコミット: abc"')" '制御記録を読めない（x: 引用）'
reason_body "$(jq -nc '"返事を待つ役: [@qa](mention://agent/a)\n  字下げ"')" '制御記録を読めない（x: 行頭の空白）'
reason_body "$(jq -nc '"返事を待つ役: [@qa](mention://agent/a)\n<div>"')" '制御記録を読めない（x: HTML）'
reason_body "$(jq -nc '"返事を待つ役: [@qa](mention://agent/a)\n```\n囲みが閉じない"')" '制御記録を読めない（x: 閉じない囲み）'
echo 'PASS report: 最新の回の候補が読めなければ、結果は書き、決める記録も decide も書かず、理由つきの決まらない知らせでスクワッドのリーダーを起こす'
