#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-cli-lib-body-table-test.sh で実行する。
# squad-cli-lib の本文の読み方を、設計（docs/review-next-step.md）の「本文の読み方のテスト」の表 1 の全行（tests/review-body-table.tsv）で確認する。
# 同じ入力を、制御記録の判定（analyze）、マージの依頼の確認（merge_requested）、最新の回の状態（state）の 3 つのモードに通し、同じ結果になることを見る。
# 読む側の各スクリプトが同じ入力で同じ結果を返すかは、squad-review-next-decide-body-test.sh、squad-review-wait-body-test.sh、squad-pr-watch-ci-wait-body-test.sh で確認する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
source "$root/common/monitor/squad-cli-lib"
source "$root/tests/review-body-table.sh"

round_text=$'確認するコミット: abc1234\n返事を待つ役: [@qa](mention://agent/qa)\n観点: qa（テスト）'
head=0123456789abcdef0123456789abcdef01234567

# 回 r1、決める記録、候補 x（リーダーが回のあとに書いた本文）の一覧。
comments() { # 本文の JSON 文字列
	jq -n --argjson body "$1" --arg round "$round_text" '[
		{id: "r1", author_id: "L", author_type: "agent", created_at: "2026-11-10T12:00:01Z", content: $round},
		{id: "d1", author_id: "qa", author_type: "agent", created_at: "2026-11-10T12:00:02Z", content: "/note\n返事の待ち: 次の依頼を決めます"},
		{id: "x", author_id: "L", author_type: "agent", created_at: "2026-11-10T12:00:03Z", content: $body}]'
}
fail() { printf '%s\n本文: %s\n' "$1" "$2" >&2; exit 1; }

check_analyze() { # 期待 説明 本文
	local expect=$1 label=$2 json=$3 out
	out=$(squad_cli_control analyze "$(comments "$json")" '["L"]' '["P"]' r1)
	case $expect in
	control) jq -e '[.controls[] | select(.id == "x" and .kind == "fix" and .prev == "r1")] | length == 1' <<<"$out" >/dev/null \
		&& jq -e '.blocked == null' <<<"$out" >/dev/null || fail "analyze（${label}）: 制御記録として読むはずが: $out" "$json" ;;
	notcontrol) jq -e '[.controls[] | select(.id == "x")] | length == 0' <<<"$out" >/dev/null \
		&& jq -e '.blocked == null' <<<"$out" >/dev/null || fail "analyze（${label}）: 読めて制御記録でないはずが: $out" "$json" ;;
	unreadable:*) jq -e --arg want "制御記録を読めない（x: ${expect#unreadable:}）" '.blocked == $want and ([.controls[] | select(.id == "x")] | length == 0)' <<<"$out" >/dev/null \
		|| fail "analyze（${label}）: 「${expect#unreadable:}」で読めないはずが: $out" "$json" ;;
	esac
}
check_state() { # 期待 説明 本文
	local expect=$1 label=$2 json=$3 out
	out=$(squad_cli_control state "$(comments "$json")" '["L"]' '["P"]')
	case $expect in
	unreadable:*) jq -e --arg want "制御記録を読めない（x: ${expect#unreadable:}）" '.blocked == $want' <<<"$out" >/dev/null \
		|| fail "state（${label}）: 「${expect#unreadable:}」で止まるはずが: $out" "$json" ;;
	*) jq -e '.blocked == null' <<<"$out" >/dev/null || fail "state（${label}）: 止まってはいけない: $out" "$json" ;;
	esac
}
check_merge() { # 期待 説明 本文（種類の行がマージの依頼）
	local expect=$1 label=$2 json=$3 out
	out=$(squad_cli_control merge_requested "$(comments "$json")" '["L"]' '["P"]' "$head")
	case $expect in
	control) [[ $out == yes ]] || fail "merge_requested（${label}）: 依頼済みのはずが: $out" "$json" ;;
	notcontrol) [[ $out == no ]] || fail "merge_requested（${label}）: 依頼済みでも止まりでもないはずが: $out" "$json" ;;
	unreadable:*) [[ $out == "blocked 制御記録を読めない（x: ${expect#unreadable:}）" ]] || fail "merge_requested（${label}）: 「${expect#unreadable:}」で止まるはずが: $out" "$json" ;;
	esac
}

body_table '修正の依頼: 1 回目' r1 check_analyze
rows=$body_table_count
body_table '修正の依頼: 1 回目' r1 check_state
body_table "マージの依頼: $head" r1 check_merge
[[ $rows -ge 60 ]] || { echo "表の行が足りない: $rows" >&2; exit 1; }
echo "PASS cli-lib: 本文の読み方の表 ${rows} 行を、analyze、state、merge_requested の 3 つのモードが同じ結果で読む"
