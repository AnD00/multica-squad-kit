#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-cli-lib-control-test.sh で実行する。
# squad-cli-lib の制御記録・認める回・最終レビューの判定（squad_cli_control）を、入力を直接渡して確認する。
# squad-review-next・squad-review-wait・squad-pr-watch は、同じ判定を呼ぶ。条件は docs/review-next-step.md の「制御記録の読み方」にある。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
mkdir -p tmp
test_dir=$(mktemp -d "$PWD/tmp/cli-lib-control-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
source "$root/common/monitor/squad-cli-lib"

file=$test_dir/comments.json
n=0
reset() { printf '[]' >"$file"; n=0; }
add() { # ID 作者 作者の種類 本文
	n=$((n + 1))
	jq --arg id "$1" --arg author "$2" --arg type "$3" --arg content "$4" \
		--arg at "$(printf '2026-11-10T12:%02d:%02dZ' $((n / 60)) $((n % 60)))" \
		'. + [{id: $id, author_id: $author, author_type: $type, content: $content, created_at: $at}]' "$file" >"$file.new"
	mv "$file.new" "$file"
}
agent() { add "$1" "$2" agent "$3"; }
mention() { printf '[@%s](mention://agent/%s)' "$1" "$1"; }
sha=abc1234def
decide=$'/note\n返事の待ち: 次の依頼を決めます'
# リーダー L の回 r1（レビュー）と、返事を待つ役 qa・cr、最上位の役 P。
base() {
	reset
	agent r1 L $'確認するコミット: '"$sha"$'\n返事を待つ役: '"$(mention qa) $(mention cr)"$'\n観点: qa（テスト）'
	agent d1 qa "$decide"
}
analyze() { squad_cli_control analyze "$(<"$file")" '["L"]' '["P"]'; }
check() { # 説明 jq の式。analyze の出力に当てる
	local what=$1
	shift
	analyze | jq -e "$@" >/dev/null || {
		printf '失敗: %s\n' "$what" >&2
		analyze | jq . >&2
		exit 1
	}
}
# コメント x を足して、x が制御記録として読まれたか（kind と written）を確認する。
counted() { analyze | jq -r '[.controls[] | select(.id == "x") | "\(.kind):\(.written)"] | first // "no"'; }

# ---- 制御記録の種類。決める実行の役（qa）もリーダー（L）も、種類ごとに書き済みか次へ回し済みだけかが分かれる。
# macOS の標準の bash 3.2 には連想配列がないので、種類ごとの本文と期待は case で引く。
kind_case() { # 種類 → 「本文|期待」
	case $1 in
	retry) printf '%s' $'コミットが合わず頼み直す役: qa\n前の回: r1|retry:true' ;;
	fix) printf '%s' $'修正の依頼: 直す\n前の回: r1|fix:true' ;;
	final) printf '%s' $'見直しの種類: 最終レビュー\n前の回: r1|final:true' ;;
	merge) printf '%s' $'マージの依頼: '"$sha"$'\n前の回: r1|merge:true' ;;
	human) printf '%s' $'使用率の待ち: 24 時間を超えるので人間に聞く\n前の回: r1|human:true' ;;
	usage) printf '%s' $'使用率の待ち: 待つ\n前の回: r1|usage:false' ;;
	ci) printf '%s' $'マージの前の CI の待ち: 待つ\n前の回: r1|ci:false' ;;
	esac
}
for name in retry fix final merge human usage ci; do
	entry=$(kind_case "$name")
	body=${entry%|*}
	want=${entry##*|}
	for author in L qa; do
		base
		agent x "$author" "$body"
		[[ $(counted) == "$want" ]] || { echo "種類 $name を $author が書いたときの読み: $(counted)（期待 ${want}）" >&2; exit 1; }
	done
done
echo 'PASS control: 決める実行の役とリーダーが書いた種類ごとに、書き済みか次へ回し済みだけかが分かれる'

# ---- 制御記録と読まないもの。どれも、`前の回:` か種類の行を持っていても、書き済みにも次へ回し済みにもならない。
reject() { # 説明 作者 作者の種類 本文
	base
	add x "$2" "$3" "$4"
	[[ $(counted) == no ]] || { echo "制御記録と読んだ: $1 → $(counted)" >&2; exit 1; }
}
reject '前の回: だけ' L agent $'次の依頼です\n前の回: r1'
reject '種類の行だけ' L agent '修正の依頼: 直す'
reject '前の回: の引用' L agent $'> 修正の依頼: 直す\n> 前の回: r1'
reject '種類の行だけ引用' L agent $'> 修正の依頼: 直す\n前の回: r1'
reject '逆引用符の囲み' L agent $'```\n修正の依頼: 直す\n前の回: r1\n```'
reject '~~~ の囲み' L agent $'~~~\n修正の依頼: 直す\n前の回: r1\n~~~'
reject '4 個の囲みの中の 3 個の囲みの例' L agent $'````\n```\n修正の依頼: 直す\n前の回: r1\n```\n````'
reject '4 個の囲みの中の 3 個の囲みの後ろの例' L agent $'````md\n```\nx\n```\n修正の依頼: 直す\n前の回: r1\n````'
reject '5 個の囲みの中の 4 個の囲みの例' L agent $'`````\n````\n修正の依頼: 直す\n前の回: r1\n````\n`````'
reject '4 個の ~ の囲みの中の 3 個の囲みの例' L agent $'~~~~\n~~~\n修正の依頼: 直す\n前の回: r1\n~~~\n~~~~'
reject '逆引用符の囲みの中の ~~~' L agent $'```\n~~~\n修正の依頼: 直す\n前の回: r1\n~~~\n```'
reject '閉じていない囲み' L agent $'````\n```\n修正の依頼: 直す\n前の回: r1\n```'
reject '情報文字列つきの 4 個の囲み' L agent $'````text\n```\n修正の依頼: 直す\n前の回: r1\n```\n````'
reject '行頭の空白' L agent $' 修正の依頼: 直す\n 前の回: r1'
reject '前の回: の ID の後ろに文字' L agent $'修正の依頼: 直す\n前の回: r1 と同じ'
reject '役の結果（返事の回: あり）' qa agent $'/note\n返事の回: r1\n修正の依頼: 直す\n前の回: r1'
reject 'リーダーの名前の結果' L agent $'/note\n返事の回: r1\n修正の依頼: 直す\n前の回: r1'
reject '人間のコメント' L member $'修正の依頼: 直す\n前の回: r1'
reject 'メンバーの名前の人間' human member $'修正の依頼: 直す\n前の回: r1'
reject '決める実行の役でもリーダーでもないエージェント' cr agent $'修正の依頼: 直す\n前の回: r1'
reject '知らないエージェント' stranger agent $'修正の依頼: 直す\n前の回: r1'
reject '存在しない回' L agent $'修正の依頼: 直す\n前の回: nothing'
reject '前の回: が読めない' L agent $'修正の依頼: 直す\n前の回:'
echo 'PASS control: 前の回: だけ・引用・囲み・行頭の空白・結果・人間・ほかの役・存在しない回は、制御記録と読まない'

# 囲みを正しく閉じたあとの行は、制御記録の行として読む。閉じるのは、開始と同じ種類で、開始以上の長さの行だけ。
accept() { # 説明 本文 期待
	base
	add x L agent "$2"
	[[ $(counted) == "$3" ]] || { echo "囲みのあとの行を読めない: $1 → $(counted)" >&2; exit 1; }
}
accept '4 個の囲みを 4 個で閉じたあと' $'````\n```\n例\n```\n````\n修正の依頼: 直す\n前の回: r1' fix:true
accept '4 個の囲みを 5 個で閉じたあと' $'````\n例\n`````\n修正の依頼: 直す\n前の回: r1' fix:true
accept '3 個の囲みを閉じたあと' $'```\n例\n```\n修正の依頼: 直す\n前の回: r1' fix:true
accept '~ の囲みを閉じたあと' $'~~~~\n例\n~~~~\n修正の依頼: 直す\n前の回: r1' fix:true
echo 'PASS control: 囲みは開始と同じ種類・同じ長さ以上の行で閉じ、閉じたあとの制御記録は読む'

# 回より前に書かれたもの、決める記録より前に書かれたもの。
reset
agent early L $'修正の依頼: 直す\n前の回: r1'
agent r1 L $'確認するコミット: '"$sha"$'\n返事を待つ役: '"$(mention qa)"$'\n観点: qa（テスト）'
agent d1 qa "$decide"
analyze | jq -e '[.controls[] | select(.id == "early")] | length == 0' >/dev/null
echo 'PASS control: 指す回より前に書かれたコメントは、制御記録と読まない'
reset
agent r1 L $'確認するコミット: '"$sha"$'\n返事を待つ役: '"$(mention qa)"$'\n観点: qa（テスト）'
agent x qa $'コミットが合わず頼み直す役: qa\n前の回: r1'
agent d1 qa "$decide"
analyze | jq -e '[.controls[] | select(.id == "x")] | length == 0' >/dev/null
echo 'PASS control: 決める記録より前に書いた決める実行の役のコメントは、制御記録と読まない'

# 決める実行の役は、返事を待つ役のうち最も早い決める記録を書いた役。あとから決める記録を書いた役ではない。
base
agent d2 cr "$decide"
agent x cr $'コミットが合わず頼み直す役: qa\n前の回: r1'
[[ $(counted) == no ]] || { echo "失敗: 132 行目の確認" >&2; exit 1; }
echo 'PASS control: 決める記録が最も早い役だけが、決める実行の役になる'

# 返事を待つ役でない役の決める記録は、決める実行の役を決めない。
reset
agent r1 L $'確認するコミット: '"$sha"$'\n返事を待つ役: '"$(mention qa)"$'\n観点: qa（テスト）'
agent d0 cr "$decide"
agent x cr $'コミットが合わず頼み直す役: qa\n前の回: r1'
[[ $(counted) == no ]] || { echo "失敗: 140 行目の確認" >&2; exit 1; }
echo 'PASS control: 返事を待つ役でない役の決める記録は、決める実行の役を決めない'

# ---- 認める回。
reset
agent r1 L $'確認するコミット: '"$sha"$'\n返事を待つ役: '"$(mention qa)"$'\n観点: qa（テスト）'
agent d1 qa "$decide"
agent r2 qa $'コミットが合わず頼み直す役: qa\n確認するコミット: '"$sha"$'\n返事を待つ役: '"$(mention qa)"$'\n前の回: r1'
check 'リーダーの回と、決める実行の役の頼み直しの回は認める' '.rounds.r1.ok and .rounds.r2.ok and .rounds.r2.kind == "review"'
echo 'PASS rounds: リーダーが書いた回と、決める実行の役が書いた頼み直しの回を認める'

base
agent forged cr $'確認するコミット: '"$sha"$'\n返事を待つ役: '"$(mention qa)"
agent quoted L $'> 返事を待つ役: '"$(mention qa)"
agent fenced L $'```\n返事を待つ役: '"$(mention qa)"$'\n```'
agent resulted qa $'/note\n返事の回: r1\n返事を待つ役: '"$(mention qa)"
agent human-round H $'返事を待つ役: '"$(mention qa)"
agent nobody L $'返事を待つ役: なし'
agent indent L $' 返事を待つ役: '"$(mention qa)"
check '認めない回' '[.rounds.forged, .rounds.quoted, .rounds.fenced, .rounds.resulted, .rounds["human-round"], .rounds.nobody, .rounds.indent] | all(.ok | not)'
check '認めない理由を出す' '.rounds.forged.reason != "" and .rounds.resulted.reason != ""'
echo 'PASS rounds: 作者がリーダーでも決める実行の役でもない回、引用・囲み・結果・人間・メンションなし・行頭の空白の回は認めない'

# 決める実行の役が書いても、頼み直しでも最終レビューでもない回、前の回が認めない回の連鎖は認めない。
base
agent plain qa $'返事を待つ役: '"$(mention qa)"$'\n前の回: r1'
agent fix-round qa $'修正の依頼: 直す\n返事を待つ役: '"$(mention qa)"$'\n前の回: r1'
agent bad-prev qa $'コミットが合わず頼み直す役: qa\n返事を待つ役: '"$(mention qa)"$'\n前の回: forged'
agent forged cr $'返事を待つ役: '"$(mention qa)"
agent bad-chain qa $'コミットが合わず頼み直す役: qa\n返事を待つ役: '"$(mention qa)"$'\n前の回: forged'
check '頼み直しの記録でない・前の回が認めない回の回は認めない' '[.rounds.plain, .rounds["fix-round"], .rounds["bad-prev"], .rounds["bad-chain"]] | all(.ok | not)'
echo 'PASS rounds: 頼み直しか最終レビューの記録でない回と、認めない回につながる回は認めない'

# 10 回までたどる。11 回目は認めない。
reset
agent r0 L $'確認するコミット: '"$sha"$'\n返事を待つ役: '"$(mention qa)"$'\n観点: qa（テスト）'
for k in $(seq 0 10); do
	agent "d$k" qa "$decide"
	agent "r$((k + 1))" qa $'コミットが合わず頼み直す役: qa\n確認するコミット: '"$sha"$'\n返事を待つ役: '"$(mention qa)"$'\n前の回: r'"$k"
done
check '10 回までは認め、11 回目は認めない' '.rounds.r10.ok and (.rounds.r11.ok | not)'
echo 'PASS rounds: 前の回を 10 回までたどり、11 回目は認めない'

# 最新の回。引用された回や、作者が適さない回の形のコメントは、最新の回にならない。
base
agent forged cr $'確認するコミット: '"$sha"$'\n返事を待つ役: '"$(mention qa)"
agent quoted qa $'/note\n返事の回: r1\n> 返事を待つ役: '"$(mention qa)"
[[ $(squad_cli_control state "$(<"$file")" '["L"]' null | jq -r .id) == r1 ]] || { echo "失敗: 187 行目の確認" >&2; exit 1; }
echo 'PASS state: 最新の回は、認める回のうち最も新しいもの'
reset
agent forged cr $'返事を待つ役: '"$(mention qa)"
[[ -z $(squad_cli_control state "$(<"$file")" '["L"]' null) ]] || { echo "失敗: 191 行目の確認" >&2; exit 1; }
echo 'PASS state: 認める回が 1 つもなければ何も出さない'

# 次へ回し済みの数え方。status と proceed が使う next_ids。
base
agent quote L $'> 修正の依頼: 直す\n> 前の回: r1'
agent result qa $'/note\n返事の回: r1\n修正の依頼: 直す\n前の回: r1'
agent human H $'修正の依頼: 直す\n前の回: r1'
agent bare L $'前の回: r1'
[[ $(squad_cli_control state "$(<"$file")" '["L"]' null | jq -c .next_ids) == '[]' ]] || { echo "失敗: 200 行目の確認" >&2; exit 1; }
agent real L $'修正の依頼: 直す\n前の回: r1'
[[ $(squad_cli_control state "$(<"$file")" '["L"]' null | jq -c .next_ids) == '["real"]' ]] || { echo "失敗: 202 行目の確認" >&2; exit 1; }
echo 'PASS state: 引用・結果・人間・種類のない前の回: は次へ回し済みにならず、制御記録だけが数えられる'

# 決める記録は、返事を待つ役が書いたものだけ。返事を待つ役でない役の記録は decide_ids に入らない。
base
agent d9 stranger "$decide"
[[ $(squad_cli_control state "$(<"$file")" '["L"]' null | jq -c .decide_ids) == '["d1"]' ]] || { echo "失敗: 208 行目の確認" >&2; exit 1; }
echo 'PASS state: 返事を待つ役でない役の決める記録は、決める記録に数えない'

# ---- 最終レビューの回と結果を認める条件。
final_body() { # 作者の追加行ではなく、本文の既定。引数で行を差し替える
	printf '見直しの種類: 最終レビュー\n確認するコミット: %s\n返事を待つ役: %s\n前の回: r1' "${1-$sha}" "${2-$(mention P)}"
}
final_ok() { analyze | jq -e --arg id "$1" '.finals[$id].ok' >/dev/null; }
base
agent f-ok L "$(final_body)"
final_ok f-ok
agent f-decide qa "$(final_body)"
final_ok f-decide
echo 'PASS finals: 最上位の役 1 つを待つ、同じコミットの最終レビューの回を、リーダーと決める実行の役が書けば認める'
for case in non-principal two-mentions wrong-commit no-prev bad-prev not-review author; do
	base
	case $case in
	non-principal) agent f L "$(final_body "$sha" "$(mention qa)")" ;;
	two-mentions) agent f L "$(final_body "$sha" "$(mention P) $(mention qa)")" ;;
	wrong-commit) agent f L "$(final_body ffffffff)" ;;
	no-prev) agent f L $'見直しの種類: 最終レビュー\n確認するコミット: '"$sha"$'\n返事を待つ役: '"$(mention P)" ;;
	bad-prev) agent f L "$(final_body | sed 's/前の回: r1/前の回: nothing/')" ;;
	not-review) agent design L $'見直しの種類: 設計の見直し\n確認するコミット: '"$sha"$'\n返事を待つ役: '"$(mention P)"
		agent f L "$(final_body | sed 's/前の回: r1/前の回: design/')" ;;
	author) agent f cr "$(final_body)" ;;
	esac
	analyze | jq -e '.finals.f | .ok == false and .reason != ""' >/dev/null || { echo "最終レビューを認めた: $case" >&2; analyze | jq .finals >&2; exit 1; }
done
echo 'PASS finals: 最上位の役でない役、待つ役が 2 つ、コミットの違い、前の回の欠落・不適、作者の不適は、理由つきで認めない'

# ---- マージの依頼の確認。ci-wait が使う。リーダーの書いた前の回: のない依頼は読み、役の結果や引用などは読まない。
merged() { squad_cli_control merge_requested "$(<"$file")" "${2:-[\"L\"]}" null "$1"; }
base
[[ $(merged "$sha") == no ]] || { echo "失敗: 241 行目の確認" >&2; exit 1; }
agent m1 L "マージの依頼: $sha"
[[ $(merged "$sha") == yes && $(merged other) == no ]] || { echo "失敗: 243 行目の確認" >&2; exit 1; }
echo 'PASS merge_requested: リーダーの前の回: のない依頼を、その head について依頼済みと読む'
for case in fence result nonleader unknown-round; do
	base
	case $case in
	fence) agent m L $'```\nマージの依頼: '"$sha"$'\n```' ;;
	result) agent m qa $'/note\n返事の回: r1\nマージの依頼: '"$sha"$'\n前の回: r1' ;;
	nonleader) agent m cr "マージの依頼: $sha"$'\n前の回: r1' ;;
	unknown-round) agent m qa "マージの依頼: $sha"$'\n前の回: nothing' ;;
	esac
	[[ $(merged "$sha") == no ]] || { echo "マージの依頼と読んだ: $case" >&2; exit 1; }
done
# 引用の本文は読めない候補になり、マージの依頼を読めたとも読めなかったとも言わず、止める。
base
agent m L $'> マージの依頼: '"$sha"$'\n> 前の回: r1'
[[ $(merged "$sha") == "blocked "* ]] || { echo "引用のマージの依頼で止めない: $(merged "$sha")" >&2; exit 1; }
base
agent m qa "マージの依頼: $sha"$'\n前の回: r1'
[[ $(merged "$sha") == yes ]] || { echo "決める実行の役のマージの依頼を読まない" >&2; exit 1; }
echo 'PASS merge_requested: 囲み・結果・ほかの役・存在しない回の依頼は読まず、引用は読めない候補として止め、決める実行の役の制御記録は読む'
# 読める依頼と、同じ head の読めない候補が同時にあるときは、順序と作者によらず、読めない候補を優先して理由で止める（依頼済みと読まない）。
for order in before after; do
	for unread in $'> マージの依頼: SHA' $'  マージの依頼: SHA' $'マージの依頼: SHA\n<div>' $'マージの依頼: SHA\n```\n閉じない'; do
		base
		body=${unread//SHA/$sha}
		if [[ $order == before ]]; then agent bad L "$body"; agent m1 L "マージの依頼: $sha"; else agent m1 L "マージの依頼: $sha"; agent bad L "$body"; fi
		[[ $(merged "$sha") == "blocked 制御記録を読めない（bad: "* ]] || { echo "読める依頼と読めない候補が同時にあるのに止めない（${order}）: $(merged "$sha")" >&2; exit 1; }
	done
done
echo 'PASS merge_requested: 読める依頼と同じ head の読めない候補が同時にあるときは、順序によらず、読めない候補を優先して止める'
