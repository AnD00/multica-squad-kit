# 質問は stdin から読み、既定値でも Enter を待つ。質問中は登録・保存しない。
ask() {
	local label=$1 default=$2
	printf '%s [%s]: ' "$label" "$default" >&2
	IFS= read -r answer || die '入力が終わりました。答えは保存していません。'
	[[ -n $answer ]] || answer=$default
}

question_begin() {
	question_number=$((${question_number:-0}+1))
	question_title=$1; question_description=$2; question_example=$3
	question_items='[]'; question_zero=''; question_notice=''; question_fixed=''
}

question_prompt() {
	printf '\n(%s/%s) %s\n%s\n例: %s\n' "$question_number" "$question_total" "$question_title" "$question_description" "$question_example" >&2
	if [[ -n $1 ]]; then printf '既定値: %s（Enter で使います）\n' "$1" >&2
	else printf '%s\n' '既定値: なし。例と説明を見て入力してください。' >&2; fi
	if [[ -n $question_fixed ]]; then printf '常に入る役:\n%s\n外せる役:\n' "$question_fixed" >&2; fi
	jq -r 'to_entries[] | "\(.key+1): \(.value)"' <<<"$question_items" >&2
	[[ -z $question_zero ]] || printf '0: %s\n' "$question_zero" >&2
	[[ -z $question_notice ]] || printf '%s\n' "$question_notice" >&2
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
		question_notice="前回の目印「$previous」は今の形に合いません。既存の一式は残し、今回の新しい名前を確認します。"
	fi
	while :; do
		question_prompt "$default"
		if ! valid_key "$answer"; then
			printf '%s\n' '英小文字で始まる英小文字と数字の2〜12文字にしてください。大文字・ハイフン・記号は使えません。' >&2
			continue
		fi
		if [[ $kind == member ]]; then
			candidate=$(printf '%s-%s' "$project_key" "$answer" | LC_ALL=C tr '[:lower:]' '[:upper:]')
			squad_named "$question_squads" "$candidate"
			if [[ $(jq length <<<"$matches") == 1 ]]; then
				existing=$(mc squad get "$(jq -r '.[0].id' <<<"$matches")" --output json) || die 'スクワッドの所有者を取得できませんでした。'
				jq -e '(.creator_id|type=="string" and length>0)' >/dev/null <<<"$existing" || die 'スクワッドの所有者の応答が不正です。'
				if [[ $(jq -r '.creator_id' <<<"$existing") != "$question_actor_id" ]]; then
					printf '「%s」はほかの人が作ったスクワッドです。別のメンバーの目印を入力してください。\n' "$candidate" >&2
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
	question_number=0; question_total=8; question_server_checked=no
	config=$(multica config show) || die 'CLI の設定を読めませんでした。'
	configured=$(printf '%s\n' "$config" | awk '$1=="server_url:" && $2!="(not" {print $2}')
	server_url=${MULTICA_SERVER_URL:-$configured}
	if [[ -n $server_url ]]; then
		valid_server "$server_url" || die 'CLI のサーバー設定を確認し、https:// で始まる URL に直してください。'
		server_url=${server_url%/}
		printf '設定済みのサーバーを使います: %s\n' "$server_url" >&2
		return
	fi
	question_total=9
	question_begin 'サーバーの URL' 'このホストのデーモンが接続する Multica サーバーです。管理者から案内された URL を入力します。' 'https://multica.example.test（例ではなく、案内された実際の URL を入力）'
	while :; do
		question_prompt ''
		if ! valid_server "$answer"; then printf '%s\n' 'https:// で始まるサーバーの URL を入力してください。' >&2; continue; fi
		server_url=${answer%/}
		if mc auth status >/dev/null 2>&1; then question_server_checked=yes; break; fi
		printf '%s\n' 'サーバーに接続できないか、ログインしていません。URL と接続を確認してください。' >&2
		printf '未ログインなら別のターミナルで multica --server-url %q login を済ませ、同じ質問へ入力してください。\n' "$server_url" >&2
	done
}
check_login() {
	[[ ${question_server_checked:-no} != yes ]] || return 0
	if ! mc auth status >/dev/null 2>&1; then
		printf 'Multica の接続とログインを確認してください。\nmultica --server-url %q login\n' "$server_url" >&2
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
		if [[ $allow_zero == yes ]]; then printf '%s\n' '一覧の番号を半角数字で、空白かカンマで区切ってください。0 は単独で入力します。' >&2
		else printf '%s\n' '1つ以上の番号を、表示された候補から半角数字で選んでください。空のままでは進めません。' >&2; fi
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
		if [[ -z ${answer//[[:space:]]/} || $answer == *$'\r'* ]]; then printf '%s\n' 'プロジェクトの名前が空です。名前か、一覧の番号を入力してください。' >&2; continue; fi
		if [[ $answer =~ ^[0-9]+$ ]]; then
			if [[ ${#answer} -le 6 ]]; then
				index=$((10#$answer))
				if ((index>=1 && index<=$(jq length <<<"$projects"))); then
					project_id=$(jq -r --argjson i "$index" '.[$i-1].id' <<<"$projects")
					project_name=$(jq -r --argjson i "$index" '.[$i-1].title' <<<"$projects"); break
				fi
			fi
			printf '%s\n' '一覧にない番号です。新しい名前は数字だけにせず、文字を含めて入力してください。' >&2; continue
		fi
		project_name=$answer
		matches=$(jq -c --arg name "$project_name" '[.[]|select(.title==$name)]' <<<"$projects")
		if [[ $(jq length <<<"$matches") -gt 1 ]]; then printf '%s\n' '同名のプロジェクトが複数あります。一覧の番号で選んでください。' >&2; continue; fi
		project_id=$(jq -r '.[0].id // empty' <<<"$matches"); break
	done
}

# 外せる項目と、その項目に含まれる役の対応。進行役は含めない。
role_choices='[
 {"key":"planner","roles":["planner"],"text":"要件定義: 要望をまとめて人間と合意する。外すと要件を人間が補う"},
 {"key":"designer","roles":["designer"],"text":"設計: 設計と実装の段を作る。外すと設計を人間が補う"},
 {"key":"claude","roles":["claude-implementer","claude-fixer"],"text":"Claude の実装・修正: 新規実装と指摘の修正を行う。Claude の実装者と Claude の修正者の2役を一緒に外す"},
 {"key":"codex","roles":["codex-implementer","codex-fixer"],"text":"Codex の実装・修正: 新規実装と指摘の修正を行う。Codex の実装者と Codex の修正者の2役を一緒に外す"},
 {"key":"code-reviewer","roles":["code-reviewer"],"text":"コードレビュー: 正しさとテストを確認する。返事を待つ役から外れる"},
 {"key":"security-reviewer","roles":["security-reviewer"],"text":"セキュリティ: 危険な実装を確認する。返事を待つ役から外れ、週次の脆弱性チェックも外れる"},
 {"key":"ux-reviewer","roles":["ux-reviewer"],"text":"UX: 画面の使いやすさを確認する。返事を待つ役から外れる"},
 {"key":"performance-reviewer","roles":["performance-reviewer"],"text":"パフォーマンス: 遅さや負荷を確認する。返事を待つ役から外れる"},
 {"key":"qa","roles":["qa"],"text":"QA: 動作とE2Eを確認する。返事を待つ役から外れる"},
 {"key":"ci-monitor","roles":["ci-monitor"],"text":"PR の CI の見張り: CIの結果を知らせる。この見張りを外す"},
 {"key":"usage-monitor","roles":["usage-monitor"],"text":"使用上限の見張り: AIの残量を見張る。使用上限のオートパイロットも外れる"},
 {"key":"dependabot-merger","roles":["dependabot-merger"],"text":"Dependabot の PR: 更新を週次で扱う。対応するオートパイロットも外れる"}
]'

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
			printf '%s\n' '使うランタイムは一つの番号だけを選んでください。' >&2; continue
		fi
		case $(jq -r '.[0]' <<<"$picked_numbers") in
		1) runtimes='["claude","codex"]' ;; 2) runtimes='["claude"]' ;; 3) runtimes='["codex"]' ;;
		esac
		if check_runtime_tools; then break; fi
		printf '%s\n' 'コマンドが見つかるランタイムを選ぶか、導入して同じ質問に答えてください。' >&2
	done
}

ask_questions() {
	local workspaces projects repos members profile cached='{}' raw files=0 candidate default index token previous_key selected
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
		printf '%s\n' 'ワークスペースは一つの番号だけを選んでください。' >&2
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
				printf '%s\n' 'そのプロジェクトの区別は別の答えに使われています。別の目印を入力してください。' >&2; continue
			fi
		fi
		break
	done
	repos=$(read_list リポジトリ repo list)
	repository_choices "$repos" "$projects" "$project_id"
	question_begin 'リポジトリ' 'このプロジェクトのエージェントが作業し、書き込める場所です。選んだものだけに push と PR ができ、複数選べます。' '1 3、または 1,3（1つ以上）'
	question_items=$(jq '[.[].repository]' <<<"$eligible_repos")
	case $(jq length <<<"$eligible_repos") in 1) question_example='1（候補は一つです）' ;; 2) question_example='1 2、または 1,2（1つ以上）' ;; esac
	question_notice=$(jq -r '.[]|"選べないリポジトリ: \(.repository)（別プロジェクト: \(.projects|join("、"))）"' <<<"$blocked_repos")
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
	question_items=$(jq --argjson runtimes "$runtimes" '[.[] | .key as $key | .text + (if ($key=="claude" or $key=="codex") and ($runtimes|index($key))==null then "（使うランタイムにないため外れます）" else "" end)]' <<<"$role_choices"); question_zero='何も外さない'
	question_fixed='進行役（orchestrator）: 振り分けと進行を担当します。必須のため外せません。'
	default=$(jq -nr --argjson choices "$role_choices" --argjson excluded "$(jq -c '.excluded_roles // []' <<<"$saved")" '[$choices|to_entries[]|select(any(.value.roles[]; . as $role | $excluded|index($role)))|(.key+1|tostring)]|join(" ")'); default=${default:-0}
	while :; do
		pick_numbers "$default" yes
		excluded_roles=$(jq -nc --argjson choices "$role_choices" --argjson numbers "$picked_numbers" '[$numbers[] as $i | $choices[$i-1].roles[]]|unique')
		if jq -e --argjson runtimes "$runtimes" '. as $excluded | any($runtimes[]; (.+"-implementer") as $role | $excluded|index($role)==null)' >/dev/null <<<"$excluded_roles"; then break; fi
		printf '%s\n' '実装と修正の系統を両方は外せません。少なくとも一系統を残してください。' >&2
	done
	answers=$(jq -n --arg server_url "$server_url" --arg workspace_id "$workspace_id" --arg workspace_name "$workspace_name" --arg project_id "$project_id" --arg project_name "$project_name" --arg project_key "$project_key" --argjson repositories "$repositories" --arg member_key "$member_key" --argjson member_ids "$member_ids" --argjson runtimes "$runtimes" --argjson excluded_roles "$excluded_roles" '{schema:1,server_url:$server_url,workspace_id:$workspace_id,workspace_name:$workspace_name,project_id:$project_id,project_name:$project_name,project_key:$project_key,repositories:$repositories,member_key:$member_key,member_ids:$member_ids,runtimes:$runtimes,excluded_roles:$excluded_roles}')
	question_people=$members
}

# 候補がない質問も、説明と理由を入力なしで表示してから止める。
question_prompt_no_input() {
	printf '\n(%s/%s) %s\n%s\n例: %s\n既定値: なし\n%s\n' "$question_number" "$question_total" "$question_title" "$question_description" "$question_example" "$question_notice" >&2
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
	local agent_total=0 agent_new=0 agent_existing=0 auto_plan='[]' count total new existing kind pattern
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
			if [[ $role == security-reviewer ]]; then title="週 1 回の依存ライブラリの脆弱性チェック $project_key $repo"; else title="Dependabot の PR の週次の確認 $project_key $repo"; fi
			action=$(plan_autopilot_action "$autopilots" "$agents" "$title") || return 1
			auto_plan=$(jq -c --arg kind "$role" --arg title "$title" --arg action "$action" '.+[{kind:$kind,title:$title,action:$action}]' <<<"$auto_plan") || return 1
		done
	done < <(jq -r '.[].repository' <<<"$repositories")
	if ! jq -e 'index("usage-monitor")!=null' >/dev/null <<<"$excluded_roles"; then
		title="使用上限の見張り $project_key-$member_key"
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
		security-reviewer) pattern="週 1 回の依存ライブラリの脆弱性チェック $project_key <OWNER/REPO>" ;;
		dependabot-merger) pattern="Dependabot の PR の週次の確認 $project_key <OWNER/REPO>" ;;
		usage-monitor) pattern="使用上限の見張り $project_key-$member_key" ;;
		esac
		printf '  %s件、名前の規則: %s\n' "$count" "$pattern"
	done
	# 集計しても、別の担当等を保護する注意は隠さない。
	jq -r '.[]|select(.action|startswith("今あるものを保持"))|"  保持する既存の設定: \(.title)（別の担当またはプロジェクト）"' <<<"$auto_plan"
	humans=$(jq -r --argjson ids "$member_ids" '[.[]|select(.user_id as $id|$ids|index($id))|.name]|join("、")' <<<"$question_people")
	printf 'スクワッドに入れる人間: %s（既存の人をスクワッドへ追加・維持）\n' "${humans:-なし}"
	printf '外す役と、一緒に外れるもの:\n'
	jq -r --argjson excluded "$excluded_roles" --argjson runtimes "$runtimes" '.[]|select(any(.roles[]; . as $role|$excluded|index($role)))|.key as $key|"  \(.text)" + (if ($key=="claude" or $key=="codex") and ($runtimes|index($key))==null then "（使うランタイムにないため外れます）" else "" end)' <<<"$role_choices"
	if [[ $(jq length <<<"$excluded_roles") == 0 ]]; then printf '  なし\n'; fi
}

confirm_answers() {
	local plan
	plan=$(confirmation_plan) || die '答えの一覧を作れませんでした。答えは保存していません。'
	while :; do
		printf '\n答えの一覧（まだ変更していません）:\n%s\n' "$plan" >&2
		ask 'この答えを保存して続けますか（yes/no）' 'no'
		case $answer in yes) return 0 ;; no) die '中止しました。答えは保存していません。' ;; *) printf '%s\n' 'yes で続けるか、no で中止してください。答えはまだ保存していません。' >&2 ;; esac
	done
}
