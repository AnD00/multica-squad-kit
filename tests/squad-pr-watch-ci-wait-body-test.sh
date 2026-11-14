#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-pr-watch-ci-wait-body-test.sh で実行する。
# squad-pr-watch ci-wait が、設計（docs/review-next-step.md）の「本文の読み方のテスト」の表 1 の全行（tests/review-body-table.tsv）を、共通の部品と同じ結果で読むかを確認する。
# 入力は、principal が最終レビューの回 final-1 のあとに書いたコメント 1 件。種類の行は「マージの依頼: <head>」。
#   control = 依頼済みと読み、待ちを解除する。notcontrol = 依頼済みと読まず、実行中として待つ。
#   unreadable = 依頼済みと読まず、何も書かず、規則と待ちの記録を残し、理由を標準エラーに出して終了 1 になる。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
source "$root/tests/pr-watch-ci-wait-lib.sh"
source "$root/tests/review-body-table.sh"

check_ci_wait_row() { # 期待 説明 本文の JSON 文字列
	local expect=$1 label=$2 json=$3
	wait_fixture
	old_wait
	requested_chain_json principal agent 2026-01-01T00:02:00Z "$json"
	case $expect in
	control)
		wait_output "CI $head: マージを依頼済み"
		assert_cleared ;;
	notcontrol)
		wait_output "CI $head: 実行中"
		assert_jq '.metadata.ci_wait_head == "'"$head"'" and (.metadata | has("ci_wait_since") and has("ci_wait_rule"))' "$test_dir/task.json"
		[[ ! -s $test_dir/posted.jsonl ]] || { printf '（%s）コメントを書いてはいけない\n' "$label" >&2; exit 1; } ;;
	unreadable:*)
		wait_blocked "制御記録を読めない（merge-1: ${expect#unreadable:}）" || { printf '（%s）の確認で失敗: %s\n' "$label" "$json" >&2; exit 1; } ;;
	esac
}

body_table "マージの依頼: $head" final-1 check_ci_wait_row
rows=$body_table_count
[[ $rows -ge 60 ]] || { echo "表の行が足りない: $rows" >&2; exit 1; }
echo "PASS ci-wait: 本文の読み方の表 ${rows} 行で、制御記録だけを依頼済みと読み、読めない候補は何も書かず規則と記録を残して終了 1 で止まる"
