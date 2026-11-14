#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-pr-watch-ci-wait-unreadable-test.sh で実行する。
# squad-pr-watch ci-wait が、読める依頼と読めない候補が同じ head に同時にあるとき、読めない候補を優先することを確認する。
# 設計は docs/review-next-step.md の「候補と読めないときの扱い」の表と、「本文の読み方のテスト」の表 2 の ci-wait の行。
# 依頼済みと読まず、マージの依頼も書かず、待ちの規則と metadata を残したまま、理由を標準エラーに出して終了 1 になる。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
source "$root/tests/pr-watch-ci-wait-lib.sh"

# 読める依頼（リーダーが書いた `マージの依頼: <head>`）に、同じ head を含む 2 つ目のコメント merge-2 を足す。
# order は、読めない候補が読める依頼の前（before）か後（after）か。
with_second() { # 本文の JSON 文字列 作者 前後
	local json=$1 author=$2 order=$3
	requested_chain_json orchestrator agent 2026-01-01T00:02:00Z "$(jq -nc --arg head "$head" '"マージの依頼: " + $head')"
	jq --slurpfile base "$test_dir/comment-prototype.json" --arg author "$author" --arg order "$order" --argjson text "$json" '
		($base[0] + {id: "merge-2", author_id: $author, author_type: "agent", content: $text,
			created_at: (if $order == "before" then "2026-01-01T00:01:30Z" else "2026-01-01T00:03:00Z" end)}) as $second
		| (. + [$second]) | sort_by(.created_at)' "$test_dir/comments.json" >"$test_dir/updated.json"
	mv "$test_dir/updated.json" "$test_dir/comments.json"
}

# 読める依頼だけなら、依頼済みと読む。比べる基準になる。
wait_fixture
old_wait
requested_chain_json orchestrator agent 2026-01-01T00:02:00Z "$(jq -nc --arg head "$head" '"マージの依頼: " + $head')"
wait_output "CI $head: マージを依頼済み"
assert_cleared

for author in orchestrator principal; do
	for order in before after; do
		while IFS=$'\t' read -r reason body; do
			wait_fixture
			old_wait
			with_second "$(jq -nc --arg body "$body" --arg head "$head" '$body | gsub("{H}"; $head) | gsub("\\\\n"; "\n")')" "$author" "$order"
			wait_blocked "制御記録を読めない（merge-2: ${reason}）" || { printf '（%s・%s・%s）の確認で失敗\n' "$author" "$order" "$reason" >&2; exit 1; }
		done <<'ROWS'
引用	> マージの依頼: {H}
行頭の空白	  マージの依頼: {H}
HTML	マージの依頼: {H}\n<div>
閉じない囲み	マージの依頼: {H}\n```\n囲みが閉じない
ROWS
	done
done
echo 'PASS ci-wait: 読める依頼と読めない候補が同じ head にあるとき、依頼済みと読まず、何も書かず規則と記録を残して終了 1 で止まる'
