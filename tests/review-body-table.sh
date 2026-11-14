# 本文の読み方の表（tests/review-body-table.tsv）を、1 行ずつコールバックへ渡す。source して使う。単独では実行しない。
# bash 3.2 でも動くよう、連想配列と mapfile は使わない。コールバックが標準入力を読んでも表を壊さないよう、表は fd 3 から読む。
# body_table <種類の行> <回の ID> <コールバック> [readable|unreadable]
#   4 つ目を渡すと、読める行（control、notcontrol）か読めない行（unreadable:…）だけを流す。遅いテストを 2 つのファイルに分けるため。
#   コールバックは <期待> <説明> <本文の JSON 文字列> を受ける。期待は control、notcontrol、unreadable:<理由>。
#   本文は {K}（種類の行）、{R}（回の ID）、{B}（種類の行と前の回: の 2 行）を置き換え済み。NUL を含むことがあるので、JSON のまま扱う。
body_table_file="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/review-body-table.tsv"
body_table() {
	local kind=$1 round=$2 callback=$3 only=${4-} expect label json count=0
	while IFS=$'\t' read -r -u 3 expect label json; do
		[[ -n $expect && $expect != '#'* ]] || continue
		case $only:$expect in readable:unreadable:* | unreadable:control | unreadable:notcontrol) continue ;; esac
		json=$(jq -nc --argjson text "$json" --arg kind "$kind" --arg round "$round" \
			'$text | gsub("\\{B\\}"; "{K}\n前の回: {R}") | gsub("\\{K\\}"; $kind) | gsub("\\{R\\}"; $round)')
		"$callback" "$expect" "$label" "$json"
		count=$((count + 1))
	done 3<"$body_table_file"
	body_table_count=$count
}
