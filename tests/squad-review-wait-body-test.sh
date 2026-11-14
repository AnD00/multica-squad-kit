#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-wait-body-test.sh で実行する。
# squad-review-wait の status と proceed が、設計（docs/review-next-step.md）の「本文の読み方のテスト」の表 1 の全行（tests/review-body-table.tsv）を、共通の部品と同じ結果で読むかを確かめる。
# 入力は、回 round のあとにリーダーが書いたコメント 1 件。読めない行は、何も書かず、理由を標準エラーに出して終了 1 になる。読める行は、止まらない。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
source "$root/tests/review-wait-test-lib.sh"
source "$root/tests/review-body-table.sh"

round_ts=$((now - 120))
both='result:a:r1:5 result:b:r2:6'

# 何も書かず、標準出力を空にし、標準エラーに理由を出して終了 1 になる。
expect_blocked() { # 説明 終了コード 標準出力 標準エラー 理由 本文
	[[ $2 == 1 ]] || { printf '（%s）終了コード 1 を期待したが %s（出力: %s）\n本文: %s\n' "$1" "$2" "$3" "$6" >&2; exit 1; }
	[[ -z $3 ]] || { printf '（%s）何も出してはいけない: %s\n' "$1" "$3" >&2; exit 1; }
	[[ $4 == *"制御記録を読めない（x: $5）"* ]] || { printf '（%s）標準エラーに「制御記録を読めない（x: %s）」がない: %s\n' "$1" "$5" "$4" >&2; exit 1; }
	[[ ! -s $test_dir/posted.jsonl ]] || { printf '（%s）コメントを書いてはいけない: %s\n' "$1" "$(<"$test_dir/posted.jsonl")" >&2; exit 1; }
}
expect_not_blocked() { # 説明 終了コード 標準エラー 本文
	[[ $2 == 0 ]] || { printf '（%s）終了コード 0 を期待したが %s（標準エラー: %s）\n本文: %s\n' "$1" "$2" "$3" "$4" >&2; exit 1; }
	[[ $3 != *'制御記録を読めない'* ]] || { printf '（%s）止まってはいけない: %s\n' "$1" "$3" >&2; exit 1; }
}

check_status_row() { # 期待 説明 本文の JSON 文字列
	local expect=$1 label=$2 json=$3 out code=0
	reset_calls
	build_comments $both decide:a:d1:90 | with_json x orchestrator agent 95 "$json" >"$test_dir/comments.json"
	out=$(REVIEW_WAIT_TEST_NOW=$((now + 870)) bash "$script" status test-issue 2>"$test_dir/err") || code=$?
	case $expect in
	unreadable:*) expect_blocked "status: $label" "$code" "$out" "$(<"$test_dir/err")" "${expect#unreadable:}" "$json" ;;
	*) expect_not_blocked "status: $label" "$code" "$(<"$test_dir/err")" "$json" ;;
	esac
}

# proceed は、知らせを書く前の読み取り（comments.1.json）と、書いたあとの読み取り（comments.json）の 2 回で同じ候補を読む。
check_proceed_row() { # 期待 説明 本文の JSON 文字列
	local expect=$1 label=$2 json=$3 out code=0
	reset_calls
	build_comments $both ready:orch:k1:7 | with_json x orchestrator agent 8 "$json" >"$test_dir/comments.1.json"
	build_comments $both ready:orch:k1:7 claim:orch:posted-1:9 | with_json x orchestrator agent 8 "$json" >"$test_dir/comments.json"
	out=$(bash "$script" proceed test-issue k1 2>"$test_dir/err") || code=$?
	case $expect in
	unreadable:*)
		expect_blocked "proceed: $label" "$code" "$out" "$(<"$test_dir/err")" "${expect#unreadable:}" "$json"
		[[ $out != *'回ごと済み'* && $out != *'次に進む'* ]] || { printf '（proceed: %s）進んではいけない: %s\n' "$label" "$out" >&2; exit 1; } ;;
	*) expect_not_blocked "proceed: $label" "$code" "$(<"$test_dir/err")" "$json" ;;
	esac
}

body_table '修正の依頼: 1 回目' round check_status_row
rows=$body_table_count
body_table '修正の依頼: 1 回目' round check_proceed_row
[[ $rows -ge 60 ]] || { echo "表の行が足りない: $rows" >&2; exit 1; }
echo "PASS review-wait: 本文の読み方の表 ${rows} 行で、status と proceed が、読めない候補を何も書かず終了 1 で止め、読める行は止めない"
