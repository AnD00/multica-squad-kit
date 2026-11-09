# 質問は stdin から読み、既定値でも Enter を待つ。質問中は登録・保存しない。
ask() {
	local label=$1 default=$2
	printf '%s ' "$label" >&2
	ui_paint err default "[$default]" >&2
	printf ': ' >&2
	IFS= read -r answer || die '入力が終わりました。答えは保存していません。'
	[[ -n $answer ]] || answer=$default
}

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

# 順の定義があるときは、題が順のとおりかを確かめる。質問を足したのに順へ足し忘れると止まる。
question_begin() {
	question_number=$((${question_number:-0}+1))
	question_title=$1; question_description=$2; question_example=$3
	if [[ -n ${question_titles:-} && $(sed -n "${question_number}p" <<<"$question_titles") != "$question_title" ]]; then
		die "質問の順の定義と違います: $question_title"
	fi
	question_items='[]'; question_zero=''; question_notice=''; question_notice_kind=description; question_fixed=''
}

# 質問に添える注意の文は色なしで作り、画面に出すときに種類の色と印を付ける。
# question_notice_kind は description（印も色もなし）か warning。行ごとに印を付ける。
question_notice_show() {
	local line
	[[ -n $question_notice ]] || return 0
	while IFS= read -r line; do
		if [[ $question_notice_kind == warning ]]; then ui_warning "$line"; else printf '%s\n' "$line" >&2; fi
	done <<<"$question_notice"
}

# 画面の種類ごとの色と印は manual.md の「表示の色と印」に従い、lib/ui.sh で付ける。
# 入力を受け付けずに同じ質問へ戻るときは、行頭に印の「エラー:」を付ける。続く行は同じ色にする。
input_error() {
	local line
	ui_error "$1"
	shift
	for line; do ui_line err error "$line"; done
}

# 答えによって出さない質問は、番号を進めて見出しだけを出す。
question_skip() {
	question_begin "$1" '' ''
	printf '\n' >&2
	ui_line err question "質問 ($question_number/$question_total) $question_title: $2"
}

question_heading() {
	printf '\n' >&2
	ui_line err question "質問 ($question_number/$question_total) $question_title"
	printf '%s\n例: %s\n' "$question_description" "$question_example" >&2
}

question_choice() {
	ui_paint err choice "$1:" >&2
	printf ' %s\n' "$2" >&2
}

question_prompt() {
	question_heading
	if [[ -n $1 ]]; then ui_line err default "既定値: $1（Enter で使います）"
	else ui_line err default '既定値: なし。例と説明を見て入力してください。'; fi
	if [[ -n $question_fixed ]]; then printf '常に入る役:\n%s\n外せる役:\n' "$question_fixed" >&2; fi
	local number
	for ((number=1; number<=$(jq length <<<"$question_items"); number++)); do question_choice "$number" "$(jq -r --argjson i "$number" '.[$i-1]' <<<"$question_items")"; done
	[[ -z $question_zero ]] || question_choice 0 "$question_zero"
	question_notice_show
	ask '入力' "$1"
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
			input_error '英小文字で始まる英小文字と数字の2〜12文字にしてください。大文字・ハイフン・記号は使えません。'
			continue
		fi
		if [[ $kind == member ]]; then
			candidate=$(printf '%s-%s' "$project_key" "$answer" | LC_ALL=C tr '[:lower:]' '[:upper:]')
			squad_named "$question_squads" "$candidate"
			if [[ $(jq length <<<"$matches") == 1 ]]; then
				existing=$(mc squad get "$(jq -r '.[0].id' <<<"$matches")" --output json) || die 'スクワッドの所有者を取得できませんでした。'
				jq -e '(.creator_id|type=="string" and length>0)' >/dev/null <<<"$existing" || die 'スクワッドの所有者の応答が不正です。'
				if [[ $(jq -r '.creator_id' <<<"$existing") != "$question_actor_id" ]]; then
					input_error "「${candidate}」はほかの人が作ったスクワッドです。別のメンバーの目印を入力してください。"
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
	question_number=0; question_titles=$question_order; question_total=$(grep -c "" <<<"$question_titles"); question_server_checked=no
	config=$(multica config show) || die 'CLI の設定を読めませんでした。'
	configured=$(printf '%s\n' "$config" | awk '$1=="server_url:" && $2!="(not" {print $2}')
	server_url=${MULTICA_SERVER_URL:-$configured}
	if [[ -n $server_url ]]; then
		valid_server "$server_url" || die 'CLI のサーバー設定を確認し、https:// で始まる URL に直してください。'
		server_url=${server_url%/}
		printf '設定済みのサーバーを使います: %s\n' "$server_url" >&2
		return
	fi
	question_titles=$(printf 'サーバーの URL\n%s' "$question_order"); question_total=$(grep -c "" <<<"$question_titles")
	question_begin 'サーバーの URL' 'このホストのデーモンが接続する Multica サーバーです。管理者から案内された URL を入力します。' 'https://multica.example.test（例ではなく、案内された実際の URL を入力）'
	while :; do
		question_prompt ''
		if ! valid_server "$answer"; then input_error 'https:// で始まるサーバーの URL を入力してください。'; continue; fi
		server_url=${answer%/}
		if mc auth status >/dev/null 2>&1; then question_server_checked=yes; break; fi
		input_error 'サーバーに接続できないか、ログインしていません。URL と接続を確認してください。' \
			"$(printf '未ログインなら別のターミナルで multica --server-url %q login を済ませ、同じ質問へ入力してください。' "$server_url")"
	done
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
		if [[ $allow_zero == yes ]]; then input_error '一覧の番号を半角数字で、空白かカンマで区切ってください。0 は単独で入力します。'
		else input_error '1つ以上の番号を、表示された候補から半角数字で選んでください。空のままでは進めません。'; fi
	done
}

pick_project() {
	local projects=$1 previous=$2 default matches index
	default=$(jq -r '.project_name // empty' <<<"$previous")
	question_begin 'プロジェクト' 'タスク（issue）を入れる場所です。今あるものを番号で選ぶか、新しい名前を入力すると作ります。' '1、または Demo Project のような新しい名前'
	question_items=$(jq '[.[].title]' <<<"$projects")
	if [[ $(jq length <<<"$projects") == 0 ]]; then question_notice='まだプロジェクトがありません。新しい名前を入れると作ります。'; question_example='Demo Project のような新しい名前'; fi
	while :; do
		question_prompt "$default"
		if [[ -z ${answer//[[:space:]]/} || $answer == *$'\r'* ]]; then input_error 'プロジェクトの名前が空です。名前か、一覧の番号を入力してください。'; continue; fi
		if [[ $answer =~ ^[0-9]+$ ]]; then
			if [[ ${#answer} -le 6 ]]; then
				index=$((10#$answer))
				if ((index>=1 && index<=$(jq length <<<"$projects"))); then
					project_id=$(jq -r --argjson i "$index" '.[$i-1].id' <<<"$projects")
					project_name=$(jq -r --argjson i "$index" '.[$i-1].title' <<<"$projects"); break
				fi
			fi
			input_error '一覧にない番号です。新しい名前は数字だけにせず、文字を含めて入力してください。'; continue
		fi
		project_name=$answer
		matches=$(jq -c --arg name "$project_name" '[.[]|select(.title==$name)]' <<<"$projects")
		if [[ $(jq length <<<"$matches") -gt 1 ]]; then input_error '同名のプロジェクトが複数あります。一覧の番号で選んでください。'; continue; fi
		project_id=$(jq -r '.[0].id // empty' <<<"$matches"); break
	done
}

# オートパイロットの名前は、ここだけで作る。リポジトリごとのものには OWNER/REPO を渡す。
# 登録する名前は common/autopilots.md の見出しで、tests/role-choices-test.sh が同じ名前になることを確かめる。
autopilot_title() {
	case $1 in
	security-reviewer) printf '週 1 回の依存ライブラリの脆弱性チェック %s %s' "$project_key" "$2" ;;
	dependabot-merger) printf 'Dependabot の PR の週次の確認 %s %s' "$project_key" "$2" ;;
	usage-monitor) printf '使用上限の見張り %s-%s' "$project_key" "$member_key" ;;
	esac
}

# 外せる項目と、その項目に含まれる役の対応。進行役は含めない。
# roles はエージェントの役、autopilots は一緒に外れるオートパイロットの種類、watch はオートパイロットではない見張りである。
role_choices='[
 {"key":"planner","roles":["planner"],"title":"要件定義","purpose":"要望をまとめて人間と合意する","changes":"要件は人間に補ってもらう"},
 {"key":"designer","roles":["designer"],"title":"設計","purpose":"設計と実装の段を作る","changes":"設計は人間に補ってもらう"},
 {"key":"claude","roles":["claude-implementer","claude-fixer"],"title":"Claude の実装・修正","purpose":"新規実装と指摘の修正を行う","changes":"振り分け先から外れる"},
 {"key":"codex","roles":["codex-implementer","codex-fixer"],"title":"Codex の実装・修正","purpose":"新規実装と指摘の修正を行う","changes":"振り分け先から外れる。レビューの4役はClaudeのモデルになる"},
 {"key":"code-reviewer","roles":["code-reviewer"],"title":"コードレビュー","purpose":"正しさとテストを確認する","changes":"返事を待つ役の一覧から外れる"},
 {"key":"security-reviewer","roles":["security-reviewer"],"title":"セキュリティ","purpose":"危険な実装を確認する","autopilots":["security-reviewer"],"changes":"返事を待つ役の一覧から外れる"},
 {"key":"ux-reviewer","roles":["ux-reviewer"],"title":"UX","purpose":"画面の使いやすさを確認する","changes":"返事を待つ役の一覧から外れる"},
 {"key":"performance-reviewer","roles":["performance-reviewer"],"title":"パフォーマンス","purpose":"遅さや負荷を確認する","changes":"返事を待つ役の一覧から外れる"},
 {"key":"qa","roles":["qa"],"title":"QA","purpose":"動作とE2Eを確認する","changes":"返事を待つ役の一覧から外れる"},
 {"key":"ci-monitor","roles":["ci-monitor"],"title":"PR の CI の見張り","purpose":"CIの結果を知らせる","watch":"進行役が PR ごとに置く CI の見張り"},
 {"key":"usage-monitor","roles":["usage-monitor"],"title":"使用上限の見張り","purpose":"AIの残量を見張る","autopilots":["usage-monitor"]},
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

# 進行役のエージェントは、ほかの役と同じ見出しで名前を出す。
role_fixed_text() {
	printf '進行役（orchestrator）: 振り分けと進行を担当します。必須のため外せません。\n  エージェント: %s-orchestrator-%s' "$project_key" "$member_key"
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
			input_error '使うランタイムは一つの番号だけを選んでください。'; continue
		fi
		case $(jq -r '.[0]' <<<"$picked_numbers") in
		1) runtimes='["claude","codex"]' ;; 2) runtimes='["claude"]' ;; 3) runtimes='["codex"]' ;;
		esac
		if check_runtime_tools; then break; fi
		input_error 'コマンドが見つかるランタイムを選ぶか、導入して同じ質問に答えてください。'
	done
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
	question_begin 'Dependabot の PR の Webhook' 'Dependabot の PR を、週次のスケジュールに加えて Webhook でも起動するかを選びます。使うときは、リポジトリごとに GitHub へ Webhook を登録し、登録やフィルターの設定を issue で頼みます。' '1（使わない）、2（使う）'
	if jq -e '.dependabot_webhook==true' >/dev/null <<<"$1"; then default=2; fi
	question_items='["使わない（週次のスケジュールだけで扱う。Webhook の登録と issue の起票をしない）","使う（リポジトリごとに Webhook を登録し、イベントフィルターの設定を起票する）"]'
	# この項目のない前の答えは使わないと読むが、前の版は聞かずに登録していたことを知らせる。
	if [[ -f $2 ]] && ! jq -e 'has("dependabot_webhook")' "$2" >/dev/null 2>&1; then
		question_notice='前の答えにはこの項目がありません。前の版は聞かずに Webhook を登録していました。使わないを選ぶと、残っている Webhook のトリガーを外すよう起票します。'
		question_notice_kind=warning
	fi
	while :; do
		pick_numbers "$default" no
		if [[ $(jq length <<<"$picked_numbers") == 1 ]]; then break; fi
		input_error '使うかどうかは一つの番号だけを選んでください。'
	done
	if [[ $(jq -r '.[0]' <<<"$picked_numbers") == 2 ]]; then dependabot_webhook=true; fi
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
		input_error 'ワークスペースは一つの番号だけを選んでください。'
	done
	index=$(jq -r '.[0]' <<<"$picked_numbers")
	workspace_id=$(jq -r --argjson i "$index" '.[$i-1].id' <<<"$workspaces")
	workspace_name=$(jq -r --argjson i "$index" '.[$i-1].name' <<<"$workspaces")
	profile=$(mc user profile get --output json) || die '導入する人の情報を取得できませんでした。'
	question_actor_id=$(jq -er '.id|select(type=="string" and length>0)' <<<"$profile") || die '導入する人の ID が不正です。'
	question_email=$(jq -r '.email // empty' <<<"$profile")
	projects=$(read_list プロジェクト project list)
	cached=$(latest_answers "$server_url" "$workspace_id" '')
	pick_project "$projects" "$cached"
	cached=$(latest_answers "$server_url" "$workspace_id" "$project_name")
	question_begin 'プロジェクトの区別' 'プロジェクトの短い名前です。一式の名前の先頭に付き、同じプロジェクトなら全員が同じ値を使います。人の目印とは別です。' 'demo、shop（英小文字で始まる英小文字と数字の2〜12文字）'
	while :; do
		ask_key "$(key_default "$project_name")" "$(jq -r '.project_key // empty' <<<"$cached")" project
		project_key=$answer; answers_file="$state_root/$workspace_id/$project_key.json"; saved='{}'
		if [[ -e $answers_file ]]; then
			[[ ! -L $answers_file ]] && valid_answers "$answers_file" || die '保存済みの答えが不正です。内容を確認してください。'
			saved=$(load_answers "$answers_file")
			if ! jq -e --arg ws "$workspace_id" --arg url "$server_url" --arg name "$project_name" --arg key "$project_key" '.workspace_id==$ws and .server_url==$url and .project_name==$name and .project_key==$key' >/dev/null <<<"$saved"; then
				input_error 'そのプロジェクトの区別は別の答えに使われています。別の目印を入力してください。'; continue
			fi
		fi
		break
	done
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
			'3. 導入先のサーバー・ワークスペースで multica repo list --output json を実行し、候補に出ることを確かめてから、セットアップを流し直します。' >&2
		die '選べるリポジトリがありません。手順書の「GitHub 連携とリポジトリの紐付け」に従い、ワークスペースへ紐付けてください。'
	fi
	default=$(jq -nr --argjson items "$eligible_repos" --argjson previous "$saved" '[($previous.repositories // [])[] as $repo | $items|to_entries[]|select(.value.repository==$repo.repository)|(.key+1|tostring)]|join(" ")')
	if [[ -z $default && $(jq length <<<"$eligible_repos") == 1 ]]; then default=1; fi
	pick_numbers "$default" no
	repositories=$(jq -nc --argjson items "$eligible_repos" --argjson numbers "$picked_numbers" '[$numbers[] as $i | $items[$i-1]]')
	question_squads=$(question_list スクワッド squad list)
	question_begin 'メンバーの区別' '導入する人の短い目印です。一式の名前の末尾に付き、その人のホストと AI の利用枠で動く一式を見分けます。1人でも必要です。' 'member1（名字の頭と番号など。英小文字で始まる英小文字と数字の2〜12文字）'
	ask_key "$(key_default "${question_email%%@*}")" "$(jq -r '.member_key // empty' <<<"$saved")" member
	member_key=$answer
	members=$(read_list メンバー workspace member list)
	jq -e --arg id "$question_actor_id" 'any(.[]; .user_id==$id)' >/dev/null <<<"$members" || die 'ワークスペースの一覧で自分を確認できません。メンバーを確認してください。'
	question_begin 'スクワッドに入れる人間' '要件の確認・設計の承認・マージの判断で呼ばれる人です。ワークスペースのメンバーから複数選べます。' '1 2、または 1,2（0なら人間を入れない）'
	question_items=$(jq '[.[].name]' <<<"$members"); if [[ $(jq length <<<"$members") == 1 ]]; then question_example='1（自分）、または0（入れない）'; fi; question_zero='人間のメンバーを入れない'
	selected=$(jq -c --arg id "$question_actor_id" '.member_ids // [$id]' <<<"$saved")
	default=$(jq -nr --argjson members "$members" --argjson selected "$selected" '[$members|to_entries[]|select(.value.user_id as $id|$selected|index($id))|(.key+1|tostring)]|join(" ")'); default=${default:-0}
	pick_numbers "$default" yes
	member_ids=$(jq -nc --argjson members "$members" --argjson numbers "$picked_numbers" '[$numbers[] as $i | $members[$i-1].user_id]|unique')
	pick_runtimes "$saved"
	question_begin '外す役' '要らない役を番号で選びます。進行役は必須で、実装・修正は少なくとも一系統を残します。' '5 7、または 5,7（0なら何も外さない）'
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
		input_error '実装と修正の系統を両方は外せません。少なくとも一系統を残してください。'
	done
	pick_dependabot_webhook "$saved" "$answers_file"
	answers=$(jq -n --arg server_url "$server_url" --arg workspace_id "$workspace_id" --arg workspace_name "$workspace_name" --arg project_id "$project_id" --arg project_name "$project_name" --arg project_key "$project_key" --argjson repositories "$repositories" --arg member_key "$member_key" --argjson member_ids "$member_ids" --argjson runtimes "$runtimes" --argjson excluded_roles "$excluded_roles" --argjson dependabot_webhook "$dependabot_webhook" '{schema:1,server_url:$server_url,workspace_id:$workspace_id,workspace_name:$workspace_name,project_id:$project_id,project_name:$project_name,project_key:$project_key,repositories:$repositories,member_key:$member_key,member_ids:$member_ids,runtimes:$runtimes,excluded_roles:$excluded_roles,dependabot_webhook:$dependabot_webhook}')
	question_people=$members
}

# 候補がない質問も、説明と理由を入力なしで表示してから止める。
question_prompt_no_input() {
	question_heading
	ui_line err default '既定値: なし'
	question_notice_show
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

confirmation_plan() {
	local agents skills autopilots squad_name role name action skill_dir repo title humans resources bound='[]'
	local agent_total=0 agent_new=0 agent_existing=0 auto_plan='[]' count total new existing kind pattern i choice excluded_shown=no
	# 表示の予定だけに、選ばなかったランタイムの系統を足す。保存する答えは変えない。
	local excluded_roles=$excluded_roles
	excluded_roles=$(jq -c --argjson runtimes "$runtimes" '. + ["claude","codex" | . as $runtime | select($runtimes|index($runtime)==null) | "\($runtime)-implementer","\($runtime)-fixer"] | unique' <<<"$excluded_roles")
	agents=$(question_list エージェント agent list)
	skills=$(question_list スキル skill list)
	autopilots=$(mc autopilot list --output json) || die 'オートパイロットを取得できませんでした。'
	autopilots=$(jq -ec '.autopilots|select(type=="array" and all(.[]; (.id|type=="string") and (.title|type=="string")))' <<<"$autopilots") || die 'オートパイロット一覧の応答が不正です。'
	if [[ -n $project_id ]]; then
		resources=$(mc project resource list "$project_id" --output json) || die '既存のプロジェクトの紐付けを取得できませんでした。'
		jq -e 'type=="array" and all(.[]; (.resource_type|type=="string"))' >/dev/null <<<"$resources" || die '既存の紐付けの応答が不正です。'
		bound=$(jq -c "$repository_filter"'[.[]|select(.resource_type=="github_repo")|.resource_ref.url|repository_name]' <<<"$resources") || die '既存の紐付けの URL が不正です。'
	fi
	printf 'サーバー: %s\nワークスペース: %s（既存を使う）\n' "$server_url" "$workspace_name"
	if [[ -n $project_id ]]; then action='今あるものを使う'; else action='新しく作る'; fi
	printf 'プロジェクト: %s（%s）\n' "$project_name" "$action"
	printf '使うランタイム: %s\n' "$(jq -r 'map(if .=="claude" then "Claude Code" else "Codex" end)|join("、")' <<<"$runtimes")"
	for role in $template_roles; do
		[[ " ${extension_disabled_roles:-} " != *" $role "* ]] || { printf "外れた拡張の役（エージェントは残す）: %s\n" "$role"; continue; }
		jq -e --arg role "$role" 'index($role)!=null' >/dev/null <<<"$excluded_roles" && continue
		name=$project_key-$role-$member_key
		action=$(plan_action "$agents" name "$name" '今あるものを直す') || return 1
		agent_total=$((agent_total+1))
		if [[ $action == '新しく作る' ]]; then agent_new=$((agent_new+1)); else agent_existing=$((agent_existing+1)); fi
	done
	printf 'エージェント: %s件（新規%s件、既存%s件）\n  名前の規則: %s-<役>-%s\n' "$agent_total" "$agent_new" "$agent_existing" "$project_key" "$member_key"
	squad_name=$(printf '%s-%s' "$project_key" "$member_key" | LC_ALL=C tr '[:lower:]' '[:upper:]')
	squad_named "$question_squads" "$squad_name"
	if [[ $(jq length <<<"$matches") == 1 ]]; then
		squad_name=$(jq -r '.[0].name' <<<"$matches")
		action='今あるものを直す'
	else
		action='新しく作る'
	fi
	printf 'スクワッド: %s（%s）\n' "$squad_name" "$action"
	printf 'プロジェクトだけのスキル:\n'
	for skill_dir in "$root/skeleton/.agents/skills/"*/; do
		[[ -d $skill_dir ]] || continue
		name=$project_key-$(basename "$skill_dir")
		action=$(plan_action "$skills" name "$name" '今あるものを使う。内容は保持') || return 1
		printf '  %s（%s）\n' "$name" "$action"
	done
	printf 'リポジトリ:\n'
	while IFS= read -r repo; do
		if jq -e --arg repo "$repo" 'index($repo)!=null' >/dev/null <<<"$bound"; then action='既存の紐付けを使う'; else action='新しくプロジェクトへ紐付ける'; fi
		printf '  %s（%s）\n' "$repo" "$action"
		for role in security-reviewer dependabot-merger; do
			jq -e --arg role "$role" 'index($role)!=null' >/dev/null <<<"$excluded_roles" && continue
			title=$(autopilot_title "$role" "$repo")
			action=$(plan_autopilot_action "$autopilots" "$agents" "$title") || return 1
			auto_plan=$(jq -c --arg kind "$role" --arg title "$title" --arg action "$action" '.+[{kind:$kind,title:$title,action:$action}]' <<<"$auto_plan") || return 1
		done
	done < <(jq -r '.[].repository' <<<"$repositories")
	if [[ $(jq length <<<"${link_repositories:-[]}") != 0 ]]; then
		printf '紐付け専用のリポジトリ（既存 issue のコメントと Assignees の同期だけ。コード作業・定期処理は追加しない）:\n'
		jq -r '.[]|"  "+.' <<<"$link_repositories"
	fi
	if ! jq -e 'index("usage-monitor")!=null' >/dev/null <<<"$excluded_roles"; then
		title=$(autopilot_title usage-monitor)
		action=$(plan_autopilot_action "$autopilots" "$agents" "$title") || return 1
		auto_plan=$(jq -c --arg title "$title" --arg action "$action" '.+[{kind:"usage-monitor",title:$title,action:$action}]' <<<"$auto_plan") || return 1
	fi
	total=$(jq length <<<"$auto_plan")
	new=$(jq '[.[]|select(.action=="新しく作る")]|length' <<<"$auto_plan")
	existing=$((total-new))
	printf 'オートパイロット: %s件（新規%s件、既存%s件）\n' "$total" "$new" "$existing"
	for kind in security-reviewer dependabot-merger usage-monitor; do
		count=$(jq --arg kind "$kind" '[.[]|select(.kind==$kind)]|length' <<<"$auto_plan")
		[[ $count != 0 ]] || continue
		case $kind in
		usage-monitor) pattern=$(autopilot_title "$kind") ;;
		*) pattern=$(autopilot_title "$kind" '<OWNER/REPO>') ;;
		esac
		printf '  %s件、名前の規則: %s\n' "$count" "$pattern"
	done
	# 集計しても、別の担当等を保護する注意は隠さない。
	jq -r '.[]|select(.action|startswith("今あるものを保持"))|"  保持する既存の設定: \(.title)（別の担当またはプロジェクト）"' <<<"$auto_plan"
	if ! jq -e 'index("dependabot-merger")!=null' >/dev/null <<<"$excluded_roles"; then
		if [[ ${dependabot_webhook:-false} == true ]]; then printf 'Dependabot の PR の Webhook: 使う（リポジトリごとに登録し、フィルターの設定を起票する）\n'
		else printf 'Dependabot の PR の Webhook: 使わない（週次のスケジュールだけ。登録と起票をしない）\n'; fi
	fi
	humans=$(jq -r --argjson ids "$member_ids" '[.[]|select(.user_id as $id|$ids|index($id))|.name]|join("、")' <<<"$question_people")
	printf 'スクワッドに入れる人間: %s（既存の人をスクワッドへ追加・維持）\n' "${humans:-なし}"
	printf '外す役と、一緒に外れるもの:\n'
	for ((i=0; i<$(jq length <<<"$role_choices"); i++)); do
		choice=$(jq -c --argjson i "$i" '.[$i]' <<<"$role_choices")
		jq -e --argjson excluded "$excluded_roles" 'any(.roles[]; . as $role | $excluded|index($role))' >/dev/null <<<"$choice" || continue
		printf '  %s\n' "$(role_choice_text "$choice" '    ' "$(role_choice_note "$(jq -r '.key' <<<"$choice")")")"
		excluded_shown=yes
	done
	[[ $excluded_shown == yes ]] || printf '  なし\n'
}

confirm_answers() {
	local plan
	plan=$(confirmation_plan) || die '答えの一覧を作れませんでした。答えは保存していません。'
	while :; do
		printf '\n答えの一覧（まだ変更していません）:\n%s\n' "$plan" >&2
		ask 'この答えを保存して続けますか（yes/no）' 'no'
		case $answer in yes) return 0 ;; no) die '中止しました。答えは保存していません。' ;; *) input_error 'yes で続けるか、no で中止してください。答えはまだ保存していません。' ;; esac
	done
}
