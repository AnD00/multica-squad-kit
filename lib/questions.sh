# 質問の順。行ごとに一つの題で、サーバーの URL は未設定のときだけ先頭に足す。
# 総数はこの行数から数える。答えによって出さない質問も数え、question_skip で聞かないことを示す。
question_order='ワークスペース
プロジェクト
プロジェクトの区別
リポジトリ
メンバーの区別
スクワッドに入れる人間
使うランタイム
外す役
Dependabot の PR の Webhook'

# 進みの ●○ の数。サーバーの URL は順の外なので数えない。
question_dots=0
while IFS= read -r _; do question_dots=$((question_dots+1)); done <<<"$question_order"
question_offset=0

# 順の定義があるときは、題が順のとおりかを確認する。質問を足したのに順へ足し忘れると止まる。
# 書き換えてよいかは質問ごとに決める。色が出る端末で、入力も端末のときだけ、答えた質問を縮める。
question_begin() {
	question_number=$((${question_number:-0}+1))
	question_title=$1; question_description=$2; question_example=$3
	if [[ -n ${question_titles:-} && $(sed -n "${question_number}p" <<<"$question_titles") != "$question_title" ]]; then
		die "質問の順の定義と違います: $question_title"
	fi
	question_items='[]'; question_zero=''; question_notice=''; question_notice_kind=description; question_fixed=''
	question_opened=no; question_rows=0; question_size=''
	if [[ $ui_live_err == yes && -t 0 ]]; then question_live=yes; else question_live=no; fi
}

# 開いた質問が端末で占める行を数える。縮めるときに消す行の数になるので、書き換えるときだけ数える。
# 空の行も 1 行に数え、折り返す行は端末の幅で数える。
question_count() {
	local rows
	[[ $question_live == yes ]] || return 0
	rows=$(ui_rows "$1")
	((rows > 0)) || rows=1
	question_rows=$((question_rows + rows))
}

question_text() {
	printf '%s\n' "$1" >&2
	question_count "$1"
}

# 質問に添える注意の文は色なしで作り、画面に出すときに種類の色と印を付ける。
# question_notice_kind は description（印も色もなし）か warning（行頭の ! と色）。説明の下に同じ字下げで出す。
question_notice_show() {
	local line
	[[ -n $question_notice ]] || return 0
	while IFS= read -r line; do
		if [[ $question_notice_kind == warning ]]; then
			printf '  ' >&2
			ui_mark err warn "$line"
			question_count "  ! $line"
		else
			question_text "  $line"
		fi
	done <<<"$question_notice"
}

# 質問の入力を受け付けなかったときは、入力の行の下に ✖ と理由を出す。続く行は字下げだけにする。
# 縮めるときにまとめて消すので、理由の行も数える。
question_reject() {
	local line
	ui_mark err fail "$1"
	question_count "✖ $1"
	shift
	for line; do question_text "  $line"; done
}

# 題を、順の中で最も長い題の幅にそろえる。
question_pad_title() {
	local line width=0 size
	if [[ -z ${question_title_width:-} ]]; then
		while IFS= read -r line; do
			size=$(ui_width "$line")
			((size <= width)) || width=$size
		done <<<"${question_titles:-$question_order}"
		question_title_width=$width
	fi
	ui_pad "$question_title_width" "$1"
}

# 答えによって出さない質問は、番号を進めて、題と理由を 1 行にする。
question_skip() {
	question_begin "$1" '' ''
	ui_mark err keep "$(question_pad_title "$question_title")" "$2"
}

# 答えた質問を、✔ と題と答えの 1 行にする。答えが複数のときは、呼ぶ側が 2 つの空白で区切って渡す。
# 開いた質問を縮めるのは、端末の大きさが開いたときと同じで、行が高さ - 1 に収まるときだけにする。
# そうでないときは、開いた質問をそのまま残して、入力の行のあとへ 1 行足す。
question_answer() {
	if [[ $question_live == yes && $question_opened == yes ]]; then
		ui_size err
		if [[ "$ui_lines $ui_columns" == "$question_size" ]] && ((question_rows <= ui_lines - 1)); then
			ui_rewind err "$question_rows"
		fi
	fi
	{
		ui_paint err success '✔'
		printf ' %s  %s' "$(question_pad_title "$question_title")" "$1"
		if [[ -n ${2-} ]]; then printf '  '; ui_paint err default "$2"; fi
		printf '\n'
	} >&2
	question_opened=no
}

# 質問を開く。空の行、? と題と進み、灰の説明と例、注意、常に入る役、選択肢の順に出す。
question_open() {
	local filled=$((question_number - question_offset)) index plain line number count
	question_opened=yes; question_rows=0
	if [[ $question_live == yes ]]; then ui_size err; question_size="$ui_lines $ui_columns"; fi
	((filled >= 0)) || filled=0
	printf '\n' >&2
	question_count ''
	{
		ui_paint err question "? $question_title"
		printf '  '
		plain="? $question_title  "
		for ((index = 1; index <= question_dots; index++)); do
			if ((index <= filled)); then ui_paint err active '●'; else ui_paint err default '○'; fi
			plain+='●'
		done
		printf '\n'
	} >&2
	question_count "$plain"
	if [[ -n $question_description ]]; then
		{ ui_paint err default "  $question_description"; printf '\n'; } >&2
		question_count "  $question_description"
	fi
	if [[ -n $question_example ]]; then
		{ ui_paint err default "  $question_example"; printf '\n'; } >&2
		question_count "  $question_example"
	fi
	question_notice_show
	if [[ -n $question_fixed ]]; then
		question_text '  常に入る役:'
		while IFS= read -r line; do question_text "  $line"; done <<<"$question_fixed"
		question_text '  外せる役:'
	fi
	count=$(jq length <<<"$question_items")
	for ((number = 1; number <= count; number++)); do question_choice "$number" "$(jq -r --argjson i "$number" '.[$i-1]' <<<"$question_items")"; done
	[[ -z $question_zero ]] || question_choice 0 "$question_zero"
}

# 選択肢は、字下げ 4、太字の紫の番号、2 つの空白、本文の順。本文の続きの行は、最初の行の本文と同じ位置にそろえる。
question_choice() {
	local number=$1 text=$2 line first=yes pad
	pad=$(printf '%*s' $((${#number} + 2)) '')
	if [[ -t 2 ]]; then ui_size err; text=$(question_choice_wrap "$text" "$((ui_columns - 4 - ${#number} - 2))"); fi
	while IFS= read -r line; do
		if [[ $first == yes ]]; then
			{ printf '    '; ui_paint err choice "$number"; printf '  %s\n' "$line"; } >&2
			question_count "    $number  $line"
			first=no
		else
			printf '    %s%s\n' "$pad" "$line" >&2
			question_count "    $pad$line"
		fi
	done <<<"$text"
}

# 端末の選択肢の本文を、番号と字下げを除いた幅で折り返す。
# 元の行の字下げは続く行にも付け、補足の説明の開始位置を保つ。
question_choice_wrap() {
	local LC_ALL=C
	local text=$1 limit=$2 line indent body chunk offset width budget
	while IFS= read -r line; do
		indent=${line%%[! ]*}; body=${line#"$indent"}
		budget=$((limit - ${#indent}))
		# 字下げと全角 1 文字が収まらないほど狭い端末では、元の行を残す。
		if ((budget < 2)); then printf '%s\n' "$line"; continue; fi
		chunk=$indent; offset=0; width=0
		while ((offset < ${#body})); do
			_ui_character "$body" "$offset"
			if ((width + ui_character_width > budget)); then
				printf '%s\n' "$chunk"
				chunk=$indent; width=0
			fi
			chunk+=${body:offset:ui_character_bytes}
			width=$((width + ui_character_width))
			offset=$((offset + ui_character_bytes))
		done
		printf '%s\n' "$chunk"
	done <<<"$text"
}

# 入力の行は › と空白で、既定値があれば灰で添える。打たれた答えの分も折り返しの行に数える。
# 標準入力が端末でないときは、答えが画面に出ないので、入力の行の終わりに改行を足す。
question_input_show() {
	local default=$1
	{
		ui_paint err active '›'
		printf ' '
		if [[ -n $default ]]; then ui_paint err default "$default"; printf ' '; fi
	} >&2
}

question_input() {
	local default=$1
	question_input_show "$default"
	IFS= read -r answer || { printf '\n' >&2; die '入力が終わりました。答えは保存していません。'; }
	[[ -t 0 ]] || printf '\n' >&2
	question_count "› ${default:+$default }$answer"
	question_typed=$answer
	[[ -n $answer ]] || answer=$default
}

question_prompt() {
	[[ $question_opened == yes ]] || question_open
	question_input "$1"
}

valid_key() { [[ $1 =~ ^[a-z][a-z0-9]{1,11}$ ]]; }
key_default() {
	local value
	value=$(printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C tr -cd 'a-z0-9' | sed 's/^[0-9]*//' | cut -c1-12)
	if valid_key "$value"; then printf '%s' "$value"; fi
	return 0
}

ask_key() {
	local default=$1 previous=$2 kind=$3 matches existing candidate
	if [[ -n $previous ]] && valid_key "$previous"; then default=$previous
	elif [[ -n $previous ]]; then
		question_notice="前回の目印「${previous}」は今の形に合いません。既存の一式は残し、今回の新しい名前を確認します。"; question_notice_kind=warning
	fi
	while :; do
		question_prompt "$default"
		if ! valid_key "$answer"; then
			question_reject '英小文字で始まる英小文字と数字の2〜12文字にしてください。大文字・ハイフン・記号は使えません。'
			continue
		fi
		if [[ $kind == member ]]; then
			candidate=$(printf '%s-%s' "$project_key" "$answer" | LC_ALL=C tr '[:lower:]' '[:upper:]')
			squad_named "$question_squads" "$candidate"
			if [[ $(jq length <<<"$matches") == 1 ]]; then
				existing=$(mc squad get "$(jq -r '.[0].id' <<<"$matches")" --output json) || die 'スクワッドの所有者を取得できませんでした。'
				jq -e '(.creator_id|type=="string" and length>0)' >/dev/null <<<"$existing" || die 'スクワッドの所有者の応答が不正です。'
				if [[ $(jq -r '.creator_id' <<<"$existing") != "$question_actor_id" ]]; then
					question_reject "「${candidate}」はほかの人が作ったスクワッドです。別のメンバーの目印を入力してください。"
					continue
				fi
			fi
		fi
		break
	done
}

valid_server() { [[ $1 =~ ^https://[^/?#[:space:]@]+(:[0-9]+)?(/[^?#[:space:]]*)?$ ]]; }
choose_server() {
	local config configured
	question_number=0; question_offset=0; question_title_width=; question_titles=$question_order; question_total=$(grep -c "" <<<"$question_titles"); question_server_checked=no
	config=$(multica config show) || die 'CLI の設定を読めませんでした。'
	configured=$(printf '%s\n' "$config" | awk '$1=="server_url:" && $2!="(not" {print $2}')
	server_url=${MULTICA_SERVER_URL:-$configured}
	if [[ -n $server_url ]]; then
		valid_server "$server_url" || die 'CLI のサーバー設定を確認し、https:// で始まる URL に直してください。'
		server_url=${server_url%/}
		printf '設定済みのサーバーを使います: %s\n' "$server_url" >&2
		return
	fi
	question_titles=$(printf 'サーバーの URL\n%s' "$question_order"); question_total=$(grep -c "" <<<"$question_titles"); question_offset=1
	question_begin 'サーバーの URL' 'このホストのデーモンが接続する Multica サーバーです。管理者から案内された URL を入力します。' 'https://multica.example.test（例ではなく、案内された実際の URL を入力）'
	while :; do
		question_prompt ''
		if ! valid_server "$answer"; then question_reject 'https:// で始まるサーバーの URL を入力してください。'; continue; fi
		server_url=${answer%/}
		if mc auth status >/dev/null 2>&1; then question_server_checked=yes; break; fi
		question_reject 'サーバーに接続できないか、ログインしていません。URL と接続を確認してください。' \
			"$(printf '未ログインなら別のターミナルで multica --server-url %q login を済ませ、同じ質問へ入力してください。' "$server_url")"
	done
	question_answer "$server_url"
}
check_login() {
	[[ ${question_server_checked:-no} != yes ]] || return 0
	if ! mc auth status >/dev/null 2>&1; then
		ui_error 'Multica の接続とログインを確認してください。'
		printf 'multica --server-url %q login\n' "$server_url" >&2
		die 'ログイン後に流し直してください。ここではログインや設定の変更を行いません。'
	fi
}

question_list() {
	local label=$1 raw
	shift
	raw=$(mc "$@" --output json) || die "$label を取得できませんでした。"
	jq -e 'type=="array" and all(.[]; (.id|type=="string" and length>0) and (.name|type=="string" and length>0))' >/dev/null <<<"$raw" || die "$label の応答が不正です。"
	printf '%s\n' "$raw"
}

# 0 を許す選択にも使う。読み取りと番号の検証は同じ質問内で完結する。
pick_numbers() {
	local default=$1 allow_zero=$2 raw token index choices
	while :; do
		question_prompt "$default"
		raw=${answer//,/ }; read -r -a choices <<<"$raw"
		picked_numbers='[]'
		for token in "${choices[@]-}"; do
			if [[ ! $token =~ ^[0-9]+$ || ${#token} -gt 6 ]]; then picked_numbers=''; break; fi
			index=$((10#$token))
			if [[ $index == 0 && $allow_zero == yes && ${#choices[@]} == 1 ]]; then picked_numbers='[]'; break; fi
			if (( index < 1 || index > $(jq length <<<"$question_items") )); then picked_numbers=''; break; fi
			picked_numbers=$(jq -c --argjson i "$index" 'if index($i)==null then .+[$i] else . end' <<<"$picked_numbers")
		done
		[[ -z $picked_numbers ]] || break
		if [[ $allow_zero == yes ]]; then question_reject '一覧の番号を半角数字で、空白かカンマで区切ってください。0 は単独で入力します。'
		else question_reject '1つ以上の番号を、表示された候補から半角数字で選んでください。空のままでは進めません。'; fi
	done
}

pick_project() {
	local projects=$1 previous=$2 default matches index
	default=$(jq -r '.project_name // empty' <<<"$previous")
	question_begin 'プロジェクト' 'タスクを入れる場所です。今あるものを番号で選ぶか、新しい名前を入力すると作ります。' '1、または Demo Project のような新しい名前'
	question_items=$(jq '[.[].title]' <<<"$projects")
	if [[ $(jq length <<<"$projects") == 0 ]]; then question_notice='まだプロジェクトがありません。新しい名前を入れると作ります。'; question_example='Demo Project のような新しい名前'; fi
	while :; do
		question_prompt "$default"
		if [[ -z ${answer//[[:space:]]/} || $answer == *$'\r'* ]]; then question_reject 'プロジェクトの名前が空です。名前か、一覧の番号を入力してください。'; continue; fi
		if [[ $answer =~ ^[0-9]+$ ]]; then
			if [[ ${#answer} -le 6 ]]; then
				index=$((10#$answer))
				if ((index>=1 && index<=$(jq length <<<"$projects"))); then
					project_id=$(jq -r --argjson i "$index" '.[$i-1].id' <<<"$projects")
					project_name=$(jq -r --argjson i "$index" '.[$i-1].title' <<<"$projects"); break
				fi
			fi
			question_reject '一覧にない番号です。新しい名前は数字だけにせず、文字を含めて入力してください。'; continue
		fi
		project_name=$answer
		matches=$(jq -c --arg name "$project_name" '[.[]|select(.title==$name)]' <<<"$projects")
		if [[ $(jq length <<<"$matches") -gt 1 ]]; then question_reject '同名のプロジェクトが複数あります。一覧の番号で選んでください。'; continue; fi
		project_id=$(jq -r '.[0].id // empty' <<<"$matches"); break
	done
}

# オートパイロットの名前は、ここだけで作る。リポジトリごとのものには OWNER/REPO を渡す。
# 登録する名前は common/autopilots.md の見出しで、tests/role-choices-test.sh が同じ名前になることを確認する。
autopilot_title() {
	case $1 in
	security-reviewer) printf '週 1 回の依存ライブラリの脆弱性チェック %s %s' "$project_key" "$2" ;;
	dependabot-merger) printf 'Dependabot の PR の週次の確認 %s %s' "$project_key" "$2" ;;
	usage-monitor) printf '使用上限の見張り %s-%s' "$project_key" "$member_key" ;;
	esac
}

# 外せる項目と、その項目に含まれる役の対応。リーダーは含めない。
# roles はエージェントの役、autopilots は一緒に外れるオートパイロットの種類、watch はオートパイロットではない見張りである。
role_choices='[
 {"key":"planner","roles":["planner"],"title":"要件定義","purpose":"要望をまとめて人間と合意する","changes":"要件は人間に補ってもらう"},
 {"key":"designer","roles":["designer"],"title":"設計","purpose":"設計と実装のフェーズを作る","changes":"設計は人間に補ってもらう"},
 {"key":"claude","roles":["claude-implementer","claude-fixer"],"title":"Claude の実装・修正","purpose":"新規実装と指摘の修正を行う","changes":"振り分け先から外れる"},
 {"key":"codex","roles":["codex-implementer","codex-fixer"],"title":"Codex の実装・修正","purpose":"新規実装と指摘の修正を行う","changes":"振り分け先から外れる。レビューの4役はClaudeのモデルになる"},
 {"key":"code-reviewer","roles":["code-reviewer"],"title":"コードレビュー","purpose":"正しさとテストを確認する","changes":"返事を待つ役の一覧から外れる"},
 {"key":"security-reviewer","roles":["security-reviewer"],"title":"セキュリティ","purpose":"危険な実装を確認する","autopilots":["security-reviewer"],"changes":"返事を待つ役の一覧から外れる"},
 {"key":"ux-reviewer","roles":["ux-reviewer"],"title":"UX","purpose":"画面の使いやすさを確認する","changes":"返事を待つ役の一覧から外れる"},
 {"key":"performance-reviewer","roles":["performance-reviewer"],"title":"パフォーマンス","purpose":"遅さや負荷を確認する","changes":"返事を待つ役の一覧から外れる"},
 {"key":"qa","roles":["qa"],"title":"QA","purpose":"動作とE2Eを確認する","changes":"返事を待つ役の一覧から外れる"},
 {"key":"ci-monitor","roles":["ci-monitor"],"title":"PR の CI の見張り","purpose":"CIの結果を知らせる","watch":"リーダーが PR ごとに置く CI の見張り"},
 {"key":"usage-monitor","roles":["usage-monitor"],"title":"使用上限の見張り","purpose":"AI の使用上限を見張る","autopilots":["usage-monitor"]},
 {"key":"dependabot-merger","roles":["dependabot-merger"],"title":"Dependabot の PR","purpose":"更新を週次で扱う","autopilots":["dependabot-merger"],"changes":"Webhook を使うかを聞かず、GitHub への Webhook の登録をしない"}
]'

# 外せる項目の文。1 行目は「役: 担当。」で、続けて一緒に外れるものを種類ごとの見出しに分ける。
# 引数は、項目の JSON、見出しの字下げ、1 行目の末尾に添える注意。該当するものがない見出しは出さない。
role_choice_text() {
	local choice=$1 indent=$2 note=$3 title purpose changes watch roles kinds role kind repo names=''
	{ IFS= read -r title; IFS= read -r purpose; IFS= read -r changes; IFS= read -r watch; IFS= read -r roles; IFS= read -r kinds; } < <(jq -r '.title,.purpose,(.changes//""),(.watch//""),(.roles|join(" ")),((.autopilots//[])|join(" "))' <<<"$choice")
	printf '%s: %s。%s\n%sエージェント: ' "$title" "$purpose" "$note" "$indent"
	for role in $roles; do printf '%s%s-%s-%s' "${names:+、}" "$project_key" "$role" "$member_key"; names=yes; done
	names=''
	for kind in $kinds; do
		if [[ $kind == usage-monitor ]]; then
			names=${names:+${names}、}$(autopilot_title "$kind")
		else
			while IFS= read -r repo; do names=${names:+${names}、}$(autopilot_title "$kind" "$repo"); done < <(jq -r '.[].repository' <<<"$repositories")
		fi
	done
	[[ -z $names ]] || printf '\n%sオートパイロット: %s' "$indent" "$names"
	[[ -z $watch ]] || printf '\n%s見張り: %s' "$indent" "$watch"
	[[ -z $changes ]] || printf '\n%sほかに変わること: %s' "$indent" "$changes"
}

# 使うランタイムにない系統の項目には、選ばなくても外れることを添える。
role_choice_note() {
	if [[ $1 == claude || $1 == codex ]] && jq -e --arg key "$1" 'index($key)==null' >/dev/null <<<"$runtimes"; then printf '（使うランタイムにないため外れます）'; fi
}

# リーダーと、使うランタイムの最上位の役は、ほかの役と同じ見出しで名前を出す。
role_fixed_text() {
	local runtime
	printf 'リーダー（orchestrator）: 振り分けと進行を担当します。必須のため外せません。\n  エージェント: %s-orchestrator-%s' "$project_key" "$member_key"
	for runtime in claude codex; do
		jq -e --arg runtime "$runtime" 'index($runtime)!=null' >/dev/null <<<"${runtimes:-[\"claude\",\"codex\"]}" || continue
		printf '\n%s の最上位のレビュー（%s-principal）: 重要なタスクの設計と PR を見直します。外せません。\n  エージェント: %s-%s-principal-%s' "$(if [[ $runtime == claude ]]; then printf Claude; else printf Codex; fi)" "$runtime" "$project_key" "$runtime" "$member_key"
	done
}

pick_runtimes() {
	local previous=$1 default=1 claude_status='コマンドが見つかりません' codex_status='コマンドが見つかりません'
	command -v claude >/dev/null && claude_status='コマンドが見つかりました'
	command -v codex >/dev/null && codex_status='コマンドが見つかりました'
	if jq -e 'has("runtimes")' >/dev/null <<<"$previous"; then
		default=$(jq -r 'if (.runtimes|length)==2 then 1 elif .runtimes==["claude"] then 2 else 3 end' <<<"$previous")
	elif [[ $claude_status == 'コマンドが見つかりません' ]]; then default=3
	elif [[ $codex_status == 'コマンドが見つかりません' ]]; then default=2
	fi
	question_begin '使うランタイム' 'エージェントを動かすランタイムです。このホストに入っていて、エージェント用にログインするものを選びます。' '1（両方）、2（Claude Code だけ）、3（Codex だけ）'
	question_items=$(jq -nc --arg claude "$claude_status" --arg codex "$codex_status" '["両方（claude: \($claude)、codex: \($codex)）","Claude Code だけ（claude: \($claude)）","Codex だけ（codex: \($codex)）"]')
	while :; do
		pick_numbers "$default" no
		if [[ $(jq length <<<"$picked_numbers") != 1 ]]; then
			question_reject '使うランタイムは一つの番号だけを選んでください。'; continue
		fi
		case $(jq -r '.[0]' <<<"$picked_numbers") in
		1) runtimes='["claude","codex"]' ;; 2) runtimes='["claude"]' ;; 3) runtimes='["codex"]' ;;
		esac
		if check_runtime_tools; then break; fi
		question_reject 'コマンドが見つかるランタイムを選ぶか、導入して同じ質問に答えてください。'
	done
	question_answer "$(jq -r 'map(if .=="claude" then "Claude Code" else "Codex" end)|join("  ")' <<<"$runtimes")"
}

# Dependabot の役を残したときだけ聞く。週次のスケジュールだけでも動くので、既定は使わない。
# 答えは JSON の真偽値の文字で持つ。
pick_dependabot_webhook() {
	local default=1
	dependabot_webhook=false
	if ! jq -e 'index("dependabot-merger")==null' >/dev/null <<<"$excluded_roles"; then
		question_skip 'Dependabot の PR の Webhook' 'Dependabot の役を外したので聞きません。'
		return 0
	fi
	question_begin 'Dependabot の PR の Webhook' 'Dependabot の PR を、週次のスケジュールに加えて Webhook でも起動するかを選びます。使うときは、リポジトリごとに GitHub へ Webhook を登録し、登録やフィルターの設定をタスクで頼みます。' '1（使わない）、2（使う）'
	if jq -e '.dependabot_webhook==true' >/dev/null <<<"$1"; then default=2; fi
	question_items='["使わない（週次のスケジュールだけで扱う。Webhook の登録とタスクの起票をしない）","使う（リポジトリごとに Webhook を登録し、イベントフィルターの設定を起票する）"]'
	# この項目のない前の答えは使わないと読むが、前のバージョンは聞かずに登録していたことを知らせる。
	if [[ -f $2 ]] && ! jq -e 'has("dependabot_webhook")' "$2" >/dev/null 2>&1; then
		question_notice='前の答えにはこの項目がありません。前のバージョンは聞かずに Webhook を登録していました。使わないを選ぶと、残っている Webhook のトリガーを外すよう起票します。'
		question_notice_kind=warning
	fi
	while :; do
		pick_numbers "$default" no
		if [[ $(jq length <<<"$picked_numbers") == 1 ]]; then break; fi
		question_reject '使うかどうかは一つの番号だけを選んでください。'
	done
	if [[ $(jq -r '.[0]' <<<"$picked_numbers") == 2 ]]; then dependabot_webhook=true; question_answer '使う'; else question_answer '使わない'; fi
}

ask_questions() {
	local workspaces projects repos members profile cached='{}' raw files=0 candidate default index token previous_key selected i choice
	workspace_id=''
	workspaces=$(read_list ワークスペース workspace list)
	question_begin 'ワークスペース' 'エージェントのチームを作る置き場です。自分が入っているものから選びます。' '1（一覧の番号）'
	if [[ $(jq length <<<"$workspaces") == 0 ]]; then
		question_notice='ワークスペースを作るか、管理者に招待してもらってください。'; question_prompt_no_input
		die '所属するワークスペースがありません。'
	fi
	question_items=$(jq '[.[].name]' <<<"$workspaces")
	# 前回の答え・CLI の設定・候補が一件の場合も、自分で番号を選ぶ。
	while :; do
		pick_numbers '' no
		if [[ $(jq length <<<"$picked_numbers") == 1 ]]; then break; fi
		question_reject 'ワークスペースは一つの番号だけを選んでください。'
	done
	index=$(jq -r '.[0]' <<<"$picked_numbers")
	workspace_id=$(jq -r --argjson i "$index" '.[$i-1].id' <<<"$workspaces")
	workspace_name=$(jq -r --argjson i "$index" '.[$i-1].name' <<<"$workspaces")
	question_answer "$workspace_name"
	profile=$(mc user profile get --output json) || die '導入する人の情報を取得できませんでした。'
	question_actor_id=$(jq -er '.id|select(type=="string" and length>0)' <<<"$profile") || die '導入する人の ID が不正です。'
	question_email=$(jq -r '.email // empty' <<<"$profile")
	projects=$(read_list プロジェクト project list)
	cached=$(latest_answers "$server_url" "$workspace_id" '')
	pick_project "$projects" "$cached"
	if [[ -n $project_id ]]; then question_answer "$project_name" '今あるものを使う'; else question_answer "$project_name" '新しく作る'; fi
	cached=$(latest_answers "$server_url" "$workspace_id" "$project_name")
	question_begin 'プロジェクトの区別' 'プロジェクトの短い名前です。一式の名前の先頭に付き、同じプロジェクトなら全員が同じ値を使います。人の目印とは別です。' 'demo、shop（英小文字で始まる英小文字と数字の2〜12文字）'
	while :; do
		ask_key "$(key_default "$project_name")" "$(jq -r '.project_key // empty' <<<"$cached")" project
		project_key=$answer; answers_file="$state_root/$workspace_id/$project_key.json"; saved='{}'
		if [[ -e $answers_file ]]; then
			[[ ! -L $answers_file ]] && valid_answers "$answers_file" || die '保存済みの答えが不正です。内容を確認してください。'
			saved=$(load_answers "$answers_file")
			if ! jq -e --arg ws "$workspace_id" --arg url "$server_url" --arg name "$project_name" --arg key "$project_key" '.workspace_id==$ws and .server_url==$url and .project_name==$name and .project_key==$key' >/dev/null <<<"$saved"; then
				question_reject 'そのプロジェクトの区別は別の答えに使われています。別の目印を入力してください。'; continue
			fi
		fi
		break
	done
	question_answer "$project_key"
	repos=$(read_list リポジトリ repo list)
	repository_choices "$repos" "$projects" "$project_id"
	question_begin 'リポジトリ' 'このプロジェクトのエージェントが作業し、書き込める場所です。選んだものだけに push と PR ができ、複数選べます。' '1 3、または 1,3（1つ以上）'
	question_items=$(jq '[.[].repository]' <<<"$eligible_repos")
	case $(jq length <<<"$eligible_repos") in 1) question_example='1（候補は一つです）' ;; 2) question_example='1 2、または 1,2（1つ以上）' ;; esac
	question_notice=$(jq -r '.[]|"選べないリポジトリ: \(.repository)（別プロジェクト: \(.projects|join("、"))）"' <<<"$blocked_repos"); question_notice_kind=warning
	if [[ $(jq length <<<"$eligible_repos") == 0 ]]; then
		question_prompt_no_input
		printf '%s\n' 'ワークスペースのオーナーか管理者に、次の準備を依頼してください。' \
			'1. ワークスペースの設定 → コードで GitHub 連携を設定し、このプロジェクトで使うリポジトリを許可します。' \
			'2. 自前サーバーで GitHub App が未設定なら、サーバーの管理者に GitHub 連携の準備を依頼します。' \
			'3. 導入先のサーバー・ワークスペースで multica repo list --output json を実行し、候補に出ることを確認してから、セットアップを流し直します。' >&2
		die '選べるリポジトリがありません。手順書の「GitHub 連携とリポジトリの紐付け」に従い、ワークスペースへ紐付けてください。'
	fi
	default=$(jq -nr --argjson items "$eligible_repos" --argjson previous "$saved" '[($previous.repositories // [])[] as $repo | $items|to_entries[]|select(.value.repository==$repo.repository)|(.key+1|tostring)]|join(" ")')
	if [[ -z $default && $(jq length <<<"$eligible_repos") == 1 ]]; then default=1; fi
	pick_numbers "$default" no
	repositories=$(jq -nc --argjson items "$eligible_repos" --argjson numbers "$picked_numbers" '[$numbers[] as $i | $items[$i-1]]')
	question_answer "$(jq -r 'map(.repository)|join("  ")' <<<"$repositories")"
	question_squads=$(question_list スクワッド squad list)
	question_begin 'メンバーの区別' '導入する人の短い目印です。一式の名前の末尾に付き、その人のホストと AI の利用枠で動く一式を見分けます。1人でも必要です。' 'member1（名字の頭と番号など。英小文字で始まる英小文字と数字の2〜12文字）'
	ask_key "$(key_default "${question_email%%@*}")" "$(jq -r '.member_key // empty' <<<"$saved")" member
	member_key=$answer
	question_answer "$member_key"
	members=$(read_list メンバー workspace member list)
	jq -e --arg id "$question_actor_id" 'any(.[]; .user_id==$id)' >/dev/null <<<"$members" || die 'ワークスペースの一覧で自分を確認できません。メンバーを確認してください。'
	question_begin 'スクワッドに入れる人間' '要件の確認・設計の承認・マージの判断で呼ばれる人です。ワークスペースのメンバーから複数選べます。' '1 2、または 1,2（0なら人間を入れない）'
	question_items=$(jq '[.[].name]' <<<"$members"); if [[ $(jq length <<<"$members") == 1 ]]; then question_example='1（自分）、または0（入れない）'; fi; question_zero='人間のメンバーを入れない'
	selected=$(jq -c --arg id "$question_actor_id" '.member_ids // [$id]' <<<"$saved")
	default=$(jq -nr --argjson members "$members" --argjson selected "$selected" '[$members|to_entries[]|select(.value.user_id as $id|$selected|index($id))|(.key+1|tostring)]|join(" ")'); default=${default:-0}
	pick_numbers "$default" yes
	member_ids=$(jq -nc --argjson members "$members" --argjson numbers "$picked_numbers" '[$numbers[] as $i | $members[$i-1].user_id]|unique')
	question_answer "$(jq -r --argjson numbers "$picked_numbers" '[$numbers[] as $i | .[$i-1].name]|join("  ")' <<<"$members" | sed 's/^$/なし/')"
	pick_runtimes "$saved"
	question_begin '外す役' '要らない役を番号で選びます。リーダーは必須で、実装・修正は少なくとも一系統を残します。' '5 7、または 5,7（0なら何も外さない）'
	question_items='[]'
	for ((i=0; i<$(jq length <<<"$role_choices"); i++)); do
		choice=$(jq -c --argjson i "$i" '.[$i]' <<<"$role_choices")
		question_items=$(jq -c --arg text "$(role_choice_text "$choice" '  ' "$(role_choice_note "$(jq -r '.key' <<<"$choice")")")" '.+[$text]' <<<"$question_items")
	done
	question_zero='何も外さない'
	question_fixed=$(role_fixed_text)
	default=$(jq -nr --argjson choices "$role_choices" --argjson excluded "$(jq -c '.excluded_roles // []' <<<"$saved")" '[$choices|to_entries[]|select(any(.value.roles[]; . as $role | $excluded|index($role)))|(.key+1|tostring)]|join(" ")'); default=${default:-0}
	while :; do
		pick_numbers "$default" yes
		excluded_roles=$(jq -nc --argjson choices "$role_choices" --argjson numbers "$picked_numbers" '[$numbers[] as $i | $choices[$i-1].roles[]]|unique')
		if jq -e --argjson runtimes "$runtimes" '. as $excluded | any($runtimes[]; (.+"-implementer") as $role | $excluded|index($role)==null)' >/dev/null <<<"$excluded_roles"; then break; fi
		question_reject '実装と修正の系統を両方は外せません。少なくとも一系統を残してください。'
	done
	question_answer "$(jq -r --argjson numbers "$picked_numbers" '[$numbers[] as $i | .[$i-1].title]|join("  ")' <<<"$role_choices" | sed 's/^$/何も外さない/')"
	pick_dependabot_webhook "$saved" "$answers_file"
	answers=$(jq -n --arg server_url "$server_url" --arg workspace_id "$workspace_id" --arg workspace_name "$workspace_name" --arg project_id "$project_id" --arg project_name "$project_name" --arg project_key "$project_key" --argjson repositories "$repositories" --arg member_key "$member_key" --argjson member_ids "$member_ids" --argjson runtimes "$runtimes" --argjson excluded_roles "$excluded_roles" --argjson dependabot_webhook "$dependabot_webhook" '{schema:1,server_url:$server_url,workspace_id:$workspace_id,workspace_name:$workspace_name,project_id:$project_id,project_name:$project_name,project_key:$project_key,repositories:$repositories,member_key:$member_key,member_ids:$member_ids,runtimes:$runtimes,excluded_roles:$excluded_roles,dependabot_webhook:$dependabot_webhook}')
	question_people=$members
}

# 候補がない質問も、説明と理由を入力なしで表示してから止める。
question_prompt_no_input() {
	question_open
}

plan_action() {
	local items=$1 field=$2 name=$3 existing=$4 matches
	matches=$(jq -c --arg field "$field" --arg name "$name" '[.[]|select(.[$field]==$name)]' <<<"$items")
	[[ $(jq length <<<"$matches") -le 1 ]] || die "同じ名前が複数あります: $name"
	if [[ $(jq length <<<"$matches") == 0 ]]; then printf '新しく作る'; else printf '%s' "$existing"; fi
}

plan_autopilot_action() {
	local pilots=$1 agents=$2 title=$3 current count
	current=$(jq -c --arg title "$title" '[.[]|select(.title==$title)]' <<<"$pilots")
	count=$(jq length <<<"$current")
	[[ $count -le 1 ]] || die "同じ名前のオートパイロットが複数あります: $title"
	if [[ $count == 0 ]]; then printf '新しく作る'; return; fi
	if jq -e --argjson agents "$agents" --arg owner "$question_actor_id" --arg prefix "$project_key-" --arg suffix "-$member_key" --arg project "$project_id" '
		.[0] | .assignee_id as $id | .assignee_type=="agent" and .project_id==$project and
		any($agents[]; .id==$id and .owner_id==$owner and (.name|startswith($prefix) and endswith($suffix)))
	' >/dev/null <<<"$current"; then printf '今あるものを直す'
	else printf '今あるものを保持（別の担当またはプロジェクト）'; fi
}

# 一覧の行はデータとして集め、読み取りがすべて通ってから画面に出す。
plan_item() {
	plan_rows=$(jq -c --arg group "$1" --arg mark "$2" --arg name "$3" --arg value "${4-}" '.+[{group:$group,mark:$mark,name:$name,value:$value}]' <<<"$plan_rows")
}

confirmation_plan() {
	local agents skills autopilots squad_name squad_id role name action skill_dir repo title resources bound='[]' roster='[]'
	local auto_plan='[]' kind choice id value watch changes note
	local plan_rows='[]'
	# 表示の予定だけに、選ばなかったランタイムの系統を足す。保存する答えは変えない。
	local excluded_roles=$excluded_roles
	excluded_roles=$(jq -c --argjson runtimes "$runtimes" '. + ["claude","codex" | . as $runtime | select($runtimes|index($runtime)==null) | "\($runtime)-implementer","\($runtime)-fixer","\($runtime)-principal"] | unique' <<<"$excluded_roles")
	agents=$(question_list エージェント agent list)
	skills=$(question_list スキル skill list)
	autopilots=$(mc autopilot list --output json) || die 'オートパイロットを取得できませんでした。'
	autopilots=$(jq -ec '.autopilots|select(type=="array" and all(.[]; (.id|type=="string") and (.title|type=="string")))' <<<"$autopilots") || die 'オートパイロット一覧の応答が不正です。'
	if [[ -n $project_id ]]; then
		resources=$(mc project resource list "$project_id" --output json) || die '既存のプロジェクトの紐付けを取得できませんでした。'
		jq -e 'type=="array" and all(.[]; (.resource_type|type=="string"))' >/dev/null <<<"$resources" || die '既存の紐付けの応答が不正です。'
		bound=$(jq -c "$repository_filter"'[.[]|select(.resource_type=="github_repo")|.resource_ref.url|repository_name]' <<<"$resources") || die '既存の紐付けの URL が不正です。'
	fi
	for role in $template_roles; do
		[[ " ${extension_disabled_roles:-} " != *" $role "* ]] || continue
		jq -e --arg role "$role" 'index($role)!=null' >/dev/null <<<"$excluded_roles" && continue
		name=$project_key-$role-$member_key
		action=$(plan_action "$agents" name "$name" change) || return 1
		[[ $action != 新しく作る ]] || action=add
		plan_item エージェント "$action" "$name" || return 1
	done
	squad_name=$(printf '%s-%s' "$project_key" "$member_key" | LC_ALL=C tr '[:lower:]' '[:upper:]')
	squad_named "$question_squads" "$squad_name"
	squad_id=$(jq -r '.[0].id // empty' <<<"$matches")
	if [[ -n $squad_id ]]; then action=change; squad_name=$(jq -r '.[0].name' <<<"$matches"); else action=add; fi
	plan_item スクワッド "$action" "$squad_name" || return 1
	for skill_dir in "$root/skeleton/.agents/skills/"*/; do
		[[ -d $skill_dir ]] || continue
		name=$project_key-$(basename "$skill_dir")
		action=$(plan_action "$skills" name "$name" keep) || return 1
		[[ $action != 新しく作る ]] || action=add
		plan_item スキル "$action" "$name" || return 1
	done
	while IFS= read -r repo; do
		if jq -e --arg repo "$repo" 'index($repo)!=null' >/dev/null <<<"$bound"; then action=keep; else action=add; fi
		plan_item リポジトリ "$action" "$repo" || return 1
		for role in security-reviewer dependabot-merger; do
			jq -e --arg role "$role" 'index($role)!=null' >/dev/null <<<"$excluded_roles" && continue
			title=$(autopilot_title "$role" "$repo")
			action=$(plan_autopilot_action "$autopilots" "$agents" "$title") || return 1
			auto_plan=$(jq -c --arg title "$title" --arg action "$action" '.+[{title:$title,action:$action}]' <<<"$auto_plan") || return 1
		done
	done < <(jq -r '.[].repository' <<<"$repositories")
	while IFS= read -r repo; do
		[[ -n $repo ]] || continue
		if jq -e --arg repo "$repo" 'index($repo)!=null' >/dev/null <<<"$bound"; then action=keep; else action=add; fi
		plan_item リポジトリ "$action" "$repo" 紐付けだけ || return 1
	done < <(jq -r '.[]' <<<"${link_repositories:-[]}")
	if ! jq -e 'index("usage-monitor")!=null' >/dev/null <<<"$excluded_roles"; then
		title=$(autopilot_title usage-monitor)
		action=$(plan_autopilot_action "$autopilots" "$agents" "$title") || return 1
		auto_plan=$(jq -c --arg title "$title" --arg action "$action" '.+[{title:$title,action:$action}]' <<<"$auto_plan") || return 1
	fi
	while IFS= read -r choice; do
		title=$(jq -r .title <<<"$choice"); action=$(jq -r .action <<<"$choice"); value=''
		case $action in
		新しく作る) action=add ;;
		今あるものを直す) action=change ;;
		*) action=warn; value=別の担当 ;;
		esac
		plan_item オートパイロット "$action" "$title" "$value" || return 1
	done < <(jq -c '.[]' <<<"$auto_plan")
	if [[ -n $squad_id && $(jq length <<<"$member_ids") != 0 ]]; then
		roster=$(mc squad member list "$squad_id" --output json) || die 'スクワッドのメンバーを読めませんでした。'
		jq -e 'type=="array" and all(.[]; (.member_type=="agent" or .member_type=="member") and (.member_id|type=="string" and length>0))' >/dev/null <<<"$roster" || die 'スクワッドのメンバーの応答が不正です。'
	fi
	while IFS= read -r id; do
		name=$(jq -r --arg id "$id" '.[]|select(.user_id==$id)|.name' <<<"$question_people")
		if jq -e --arg id "$id" 'any(.[]; .member_type=="member" and .member_id==$id)' >/dev/null <<<"$roster"; then action=keep; else action=add; fi
		plan_item 人間 "$action" "$name" || return 1
	done < <(jq -r '.[]' <<<"$member_ids")
	while IFS= read -r choice; do
		jq -e --argjson excluded "$excluded_roles" 'any(.roles[]; . as $role | $excluded|index($role))' >/dev/null <<<"$choice" || continue
		name=$(jq -r .key <<<"$choice")
		value=''
		for role in $(jq -r '.roles[]' <<<"$choice"); do value+=${value:+  }$project_key-$role-$member_key; done
		for kind in $(jq -r '.autopilots[]?' <<<"$choice"); do
			if [[ $kind == usage-monitor ]]; then value+="  $(autopilot_title "$kind")"
			else while IFS= read -r repo; do value+="  $(autopilot_title "$kind" "$repo")"; done < <(jq -r '.[].repository' <<<"$repositories"); fi
		done
		watch=$(jq -r '.watch // empty' <<<"$choice"); changes=$(jq -r '.changes // empty' <<<"$choice"); note=$(role_choice_note "$name")
		value+=${watch:+  $watch}${changes:+  $changes}$note
		plan_item 役 drop "$name" "$value" || return 1
	done < <(jq -c '.[]' <<<"$role_choices")
	for role in ${extension_disabled_roles:-}; do plan_item 役 drop "$role" エージェントは残す || return 1; done
	printf '%s\n' "$plan_rows"
}

confirmation_show() {
	local plan=$1 group row mark name value count text separator=''
	printf '\n' >&2
	for group in エージェント スクワッド スキル リポジトリ オートパイロット 人間 役; do
		[[ $(jq --arg group "$group" '[.[]|select(.group==$group)]|length' <<<"$plan") != 0 ]] || continue
		ui_line err strong "  $group"
		while IFS= read -r row; do
			mark=$(jq -r .mark <<<"$row"); name=$(jq -r .name <<<"$row"); value=$(jq -r .value <<<"$row")
			printf '    ' >&2; ui_mark err "$mark" "$name" "$value"
		done < <(jq -c --arg group "$group" '.[]|select(.group==$group)' <<<"$plan")
	done
	printf '\n  ' >&2
	for mark in add change keep warn drop; do
		count=$(jq --arg mark "$mark" '[.[]|select(.mark==$mark)]|length' <<<"$plan")
		((count != 0)) || continue
		# 印と色の対応は ui_mark に任せ、件数だけは印のすぐ後ろへ詰める。
		text=$(ui_mark err "$mark" "$count" 2>&1)
		printf '%s%s' "$separator" "${text/ /}" >&2
		separator='  '
	done
	printf '\n' >&2
}

confirm_answers() {
	local plan question_live=no question_rows=0 question_size='' question_typed='' accepted=no retried=no
	plan=$(confirmation_plan) || die '答えの一覧を作れませんでした。答えは保存していません。'
	confirmation_show "$plan"
	{ ui_paint err question '? 保存して作りますか'; printf '  '; ui_paint err default 'yes/no'; printf '\n'; } >&2
	if [[ $ui_live_err == yes && -t 0 ]]; then question_live=yes; ui_size err; question_size="$ui_lines $ui_columns"; fi
	while :; do
		question_input no
		case $answer in yes|no) accepted=yes ;; esac
		if [[ $accepted == yes ]]; then
			# 問いと一覧は残す。聞き直した入力と理由だけを、受け付けた入力へ置き換える。
			if [[ $question_live == yes && $retried == yes ]]; then
				ui_size err
				if [[ "$ui_lines $ui_columns" == "$question_size" ]] && ((question_rows <= ui_lines - 1)); then
					ui_rewind err "$question_rows"
					question_input_show no; printf '%s\n' "$question_typed" >&2
				fi
			fi
			[[ $answer != yes ]] || return 0
			die '中止しました。答えは保存していません。'
		fi
		retried=yes
		question_reject 'yes で続けるか、no で中止してください。答えはまだ保存していません。'
	done
}
