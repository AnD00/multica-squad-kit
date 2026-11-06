# プロジェクトとエージェントの設定を終えてから、スクワッドを設定する。
prepare_project() (
	umask 077
	local project_work enabled role file model thinking name id result current desired skills matches field value runtime max
	local profile people member_name owner_mention squad_name squad_id records='{}' values
	local selected_repositories selected_repo
	local created_agents=0 created_squads=0 created_autopilots=0
	local agent_total progress agent_action
	local project_host_recheck=yes
	local -a selected_repo_names=()
	selected_repositories=$(jq -ce "$repository_filter"'
		if type=="array" and length>0 then . else error("リポジトリがありません") end |
		map(. as $entry | (.url|repository_name) as $name |
			if (.repository|type=="string") and (.repository|ascii_downcase)==$name
			then {url:$entry.url,repository:$name} else error("URL とリポジトリが違います") end) |
		reduce .[] as $entry ([]; if any(.[]; .repository==$entry.repository) then . else .+[$entry] end)
	' <<<"$repositories") || die '選択したリポジトリの一覧が不正です。'
	while IFS= read -r selected_repo; do selected_repo_names[${#selected_repo_names[@]}]=$selected_repo; done < <(jq -r '.[].repository' <<<"$selected_repositories")
	# プロジェクト作成のリポジトリには、選択した一覧の先頭を使う。
	repository_url=$(jq -r '.[0].url' <<<"$selected_repositories")
	repository=$(jq -r '.[0].repository' <<<"$selected_repositories")
	mkdir -p "$root/tmp"
	project_work=$(mktemp -d "$root/tmp/project.XXXXXX") || die 'プロジェクトの作業場所を作れませんでした。'
	trap 'rm -rf -- "$project_work"' EXIT
	enabled=''
	jq -e --arg known " $template_roles " 'type=="array" and all(.[]; . as $role | type=="string" and ($known|contains(" "+$role+" ")))' >/dev/null <<<"$excluded_roles" || die '外す役の指定が不正です。'
	# 登録する系統だけに反映する。保存済みの回答には自分で外した役だけを残す。
	for role in claude codex; do
		if ! uses_runtime "$role"; then
			excluded_roles=$(jq -c --arg runtime "$role" '.+[$runtime+"-implementer",$runtime+"-fixer"]|unique' <<<"$excluded_roles")
		fi
	done
	for role in $template_roles; do
		[[ " ${extension_disabled_roles:-} " != *" $role "* ]] || continue
		if ! jq -e --arg role "$role" 'index($role)!=null' >/dev/null <<<"$excluded_roles"; then enabled+=" $role"; fi
	done
	[[ " $enabled " == *' orchestrator '* ]] || die '進行の役は必須です。'
	for role in claude codex; do
		if [[ " $enabled " == *" $role-implementer "* ]]; then
			[[ " $enabled " == *" $role-fixer "* ]] || die '実装と修正は系統ごとに選んでください。'
		else
			[[ " $enabled " != *" $role-fixer "* ]] || die '実装と修正は系統ごとに選んでください。'
		fi
	done
	[[ " $enabled " == *' claude-implementer '* || " $enabled " == *' codex-implementer '* ]] || die '実装の系統を一つ以上選んでください。'
	profile=$(mc user profile get --output json) || die '実行する人を取得できませんでした。'
	[[ $(jq -r '.id // empty' <<<"$profile") == "$host_owner_id" && -n $host_owner_id ]] || die '実行する人がホスト準備時と違います。'
	people=$(mc workspace member list --output json) || die 'メンバーを取得できませんでした。'
	member_name=$(jq -er --arg id "$host_owner_id" '[.[] | select(.user_id==$id)] | select(length==1) | .[0].name | select(type=="string" and length>0)' <<<"$people") || die '実行する人の名前を取得できませんでした。'
	owner_mention="[@$member_name](mention://member/$host_owner_id)"
	values=$(jq -n --arg project_name "$project_name" --arg project_key "$project_key" --arg member_key "$member_key" --arg member_name "$member_name" --arg repository "$repository" --arg owner_mention "$owner_mention" '{project_name:$project_name,project_key:$project_key,member_key:$member_key,member_name:$member_name,repository:$repository,owner_mention:$owner_mention}')
	project_repository_values
	printf '%s\n' "$values" >"$project_work/values.json"
	# 名前で現在のレコードを探し直す。保存済みの ID は信頼しない。
	result=$(mc project list --output json) || die 'プロジェクトを取得できませんでした。'
	project_named "$result" title "$project_name"
	current=$matches
	project_id=$(jq -r '.[0].id // empty' <<<"$current")
	if [[ -z $project_id ]]; then
		template_apply "$project_work/values.json" "$root/skeleton/project.md" >"$project_work/description" || die 'プロジェクトの説明を展開できませんでした。'
		result=$(mc project create --title "$project_name" --description "$(cat "$project_work/description")" --repo "$repository_url" --output json) || die 'プロジェクトを作れませんでした。'
		project_id=$(project_result_id "$result") || die 'プロジェクト作成の応答が不正です。'
		prepare_project_host "$project_id" "${selected_repo_names[@]}"
	else
		current=$(mc project get "$project_id" --output json) || die 'プロジェクトを読めませんでした。'
		[[ $(project_result_id "$current") == "$project_id" ]] || die 'プロジェクトの応答が不正です。'
		prepare_project_host "$project_id" "${selected_repo_names[@]}"
		if [[ -z $(jq -r '.description // empty' <<<"$current") ]]; then
			template_apply "$project_work/values.json" "$root/skeleton/project.md" >"$project_work/description" || die 'プロジェクトの説明を展開できませんでした。'
			mc project update "$project_id" --description "$(cat "$project_work/description")" --output json >/dev/null || die 'プロジェクトの説明を作れませんでした。'
		fi
	fi
	project_resources
	values=$(jq -c --arg id "$project_id" '.+{project_id:$id}' <<<"$values")
	printf '%s\n' "$values" >"$project_work/values.json"
	# 条件の評価とモデルの確定は初期化用レコードを作る前に済ませる。
	for role in $enabled; do
		template_filter "$enabled" "$root/common/agents/$role.md" >"$project_work/$role.filtered" || die "役の印が不正です: $role"
		model=$(template_field "$project_work/$role.filtered" model) || die 'モデルの書式が不正です。'
		thinking=$(template_field "$project_work/$role.filtered" thinking_level) || die '思考の深さの書式が不正です。'
		[[ -n $model && -n $thinking ]] || die 'モデルと考え方が必要です。'
		case $model in
		claude-*)
			uses_runtime claude || die "使うランタイムにないモデルです: $role ($model)。拡張の front matter をランタイムの印で分けてください。"
			runtime=$claude_runtime_id ;;
		gpt-*)
			uses_runtime codex || die "使うランタイムにないモデルです: $role ($model)。拡張の front matter をランタイムの印で分けてください。"
			runtime=$codex_runtime_id ;;
		*) die "未知のモデルです: $model" ;;
		esac
		[[ -n $runtime ]] || die 'オンラインのランタイムがありません。'
		name=$(template_field "$project_work/$role.filtered" name) || die '名前の書式が不正です。'
		printf '%s' "$name" >"$project_work/name"
		name=$(template_apply "$project_work/values.json" "$project_work/name") || die '名前を展開できませんでした。'
		[[ $name == "$project_key-$role-$member_key" ]] || die '役の名前が規則と違います。'
		max=$(template_field "$project_work/$role.filtered" max_concurrent_tasks)
		max=${max:-6}
		[[ $max =~ ^[0-9]+$ && $max -ge 1 && $max -le 50 ]] || die '同時実行数が不正です。'
		records=$(jq -c --arg role "$role" --arg name "$name" --arg model "$model" --arg thinking "$thinking" --arg runtime "$runtime" --argjson max "$max" '.+{($role):{name:$name,model:$model,thinking_level:$thinking,runtime_id:$runtime,max_concurrent_tasks:$max}}' <<<"$records")
	done
	result=$(mc agent list --output json) || die 'エージェントを取得できませんでした。'
	agent_total=$(jq length <<<"$records")
	printf 'エージェント %s 件の既存設定を確認しています。\n' "$agent_total" >&2
	# 既存の所有者の衝突も、新規作成より先に調べる。
	for role in $enabled; do
		name=$(jq -r --arg role "$role" '.[$role].name' <<<"$records")
		project_named "$result" name "$name"
		id=$(jq -r '.[0].id // empty' <<<"$matches")
		if [[ -n $id ]]; then
			current=$(mc agent get "$id" --output json) || die "エージェントを読めませんでした: $name"
			[[ $(jq -r '.owner_id // empty' <<<"$current") == "$host_owner_id" ]] || die "ほかの人のエージェントです。メンバーの区別を変えてください: $name"
			printf '%s\n' "$current" >"$project_work/$role.current"
			records=$(jq -c --arg role "$role" --arg id "$id" '.[$role].id=$id' <<<"$records")
		fi
	done
	progress=0
	printf 'エージェント 0/%s（ID の準備）\n' "$agent_total" >&2
	for role in $enabled; do
		project_role "$role"
		project_desired_env "$role" "$model" >"$project_work/$role.env"
		id=$(jq -r --arg role "$role" '.[$role].id // empty' <<<"$records")
		if [[ -z $id ]]; then
			agent_action=新規作成
			result=$(mc agent create --name "$name" --runtime-id "$runtime" --model "$model" --thinking-level "$thinking" --max-concurrent-tasks "$max" --permission-mode private --instructions '初期化中です。本作業、タスクの状態変更、コメント、他者の呼び出しを行わず、セットアップの完了を待って停止してください。' --custom-env-file "$project_work/$role.env" --output json) || die "初期化用のエージェントを作れませんでした: $name"
			id=$(project_result_id "$result") || die 'エージェント作成の応答が不正です。'
			created_agents=$((created_agents+1))
			records=$(jq -c --arg role "$role" --arg id "$id" '.[$role].id=$id' <<<"$records")
		else
			agent_action=既存を利用
		fi
		progress=$((progress+1))
		printf 'エージェント %s/%s（ID の準備: %s）: %s\n' "$progress" "$agent_total" "$agent_action" "$name" >&2
	done
	squad_name=$(printf '%s-%s' "$project_key" "$member_key" | LC_ALL=C tr '[:lower:]' '[:upper:]')
	printf 'スクワッドを準備しています: %s\n' "$squad_name" >&2
	result=$(mc squad list --output json) || die 'スクワッドを取得できませんでした。'
	squad_named "$result" "$squad_name"
	squad_id=$(jq -r '.[0].id // empty' <<<"$matches")
	if [[ -z $squad_id ]]; then
		result=$(mc squad create --name "$squad_name" --leader "$(jq -r '.orchestrator.id' <<<"$records")" --output json) || die 'スクワッドの器を作れませんでした。'
		squad_id=$(project_result_id "$result") || die 'スクワッド作成の応答が不正です。'
		created_squads=$((created_squads+1))
	else
		squad_name=$(jq -r '.[0].name' <<<"$matches")
		result=$(mc squad get "$squad_id" --output json) || die 'スクワッドを読めませんでした。'
		[[ $(jq -r '.creator_id // empty' <<<"$result") == "$host_owner_id" ]] || die 'ほかの人のスクワッドです。メンバーの区別を変えてください。'
	fi
	values=$(jq -c --arg id "$squad_id" --arg mention "[@$squad_name](mention://squad/$squad_id)" --argjson records "$records" '
		.+{squad_id:$id,squad_mention:$mention} | reduce ($records|to_entries[]) as $r (.;
		.["agent."+$r.key+".id"]=$r.value.id | .["agent."+$r.key+".name"]=$r.value.name |
		.["agent."+$r.key+".mention"]=("[@"+$r.value.name+"](mention://agent/"+$r.value.id+")"))' <<<"$values")
	printf 'エージェント %s 件の指示を展開・検証しています。\n' "$agent_total" >&2
	# 全役を完成させ、検証が一つでも失敗したら本指示もスキルも公開設定も書かない。
	for role in $enabled; do
		project_role "$role"
		jq --arg model "$model" --arg thinking "$thinking" '.+{model:$model,thinking_level:$thinking}' <<<"$values" >"$project_work/values.json"
		template_apply "$project_work/values.json" "$project_work/$role.filtered" >"$project_work/$role.rendered" || die "指示を展開できませんでした: $role"
		template_body "$project_work/$role.rendered" >"$project_work/$role.body"
		[[ -s $project_work/$role.body ]] || die '指示の本文がありません。'
		for field in name description model thinking_level skills role max_concurrent_tasks; do
			template_field "$project_work/$role.rendered" "$field" >/dev/null || die "指示の front matter が不正です: $role"
		done
	done
	printf '%s\n' "$values" >"$project_work/values.json"
	project_skills
	progress=0
	printf 'エージェントの設定 0/%s\n' "$agent_total" >&2
	# 先に全役の環境・本指示・割り当てを完成させ、公開は最後のループにする。
	for role in $enabled; do
		project_role "$role"
		current=$(mc agent get "$id" --output json) || die 'エージェントを読めませんでした。'
		result=$(mc agent env get "$id" --output json) || die '環境変数を読めませんでした。'
		jq -e '(.custom_env // {}) | type=="object" and all(.[]; type=="string")' >/dev/null <<<"$result" || die '環境変数の応答が不正です。'
		jq --slurpfile desired "$project_work/$role.env" '(.custom_env // {} | del(.SQUAD_KIT_GH_DEPENDABOT_MERGE,.CLAUDE_CONFIG_DIR,.ENABLE_CLAUDEAI_MCP_SERVERS,.CLAUDE_CODE_SHELL,.CLAUDE_CODE_AUTO_COMPACT_WINDOW)) + $desired[0]' <<<"$result" >"$project_work/env.json"
		if [[ $(jq -Sc '.custom_env // {}' <<<"$result") != "$(jq -Sc . "$project_work/env.json")" ]]; then
			mc agent env set "$id" --custom-env-file "$project_work/env.json" --output json >/dev/null || die '環境変数を反映できませんでした。'
		fi
		value=$(template_field "$project_work/$role.rendered" description)
		desired=$(jq -c --arg role "$role" --arg description "$value" --argjson mcp "$(project_mcp "$role")" --rawfile instructions "$project_work/$role.body" '.[$role] | del(.id,.name) | .+{description:$description,instructions:($instructions|sub("\n+$";"")),mcp_config:$mcp}' <<<"$records")
		if ! jq -e --argjson desired "$desired" '. as $current | all($desired|to_entries[]; $current[.key]==.value)' >/dev/null <<<"$current"; then
			mc agent update "$id" --runtime-id "$runtime" --model "$model" --thinking-level "$thinking" --max-concurrent-tasks "$max" --description "$value" --instructions "$(cat "$project_work/$role.body")" --mcp-config "$(project_mcp "$role")" --output json >/dev/null || die "本指示を反映できませんでした: $name"
		fi
		desired=$(cat "$project_work/$role.skills")
		if [[ $(jq -r '[.skills[]?.id] | sort | join(",")' <<<"$current") != "$desired" ]]; then
			mc agent skills set "$id" --skill-ids "$desired" --output json >/dev/null || die "スキルを割り当てられませんでした: $name"
		fi
		progress=$((progress+1))
		printf 'エージェントの設定 %s/%s: %s\n' "$progress" "$agent_total" "$name" >&2
	done
	progress=0
	printf 'エージェントの公開 0/%s\n' "$agent_total" >&2
	for role in $enabled; do
		project_role "$role"
		current=$(mc agent get "$id" --output json) || die '公開前の状態を読めませんでした。'
		if ! jq -e '.permission_mode=="public_to" and ([.invocation_targets[]?.target_type]|sort)==["workspace"]' >/dev/null <<<"$current"; then
			mc agent update "$id" --permission-mode public_to --public-to-workspace --output json >/dev/null || die "公開設定を反映できませんでした: $name"
		fi
		progress=$((progress+1))
		printf 'エージェントの公開 %s/%s: %s\n' "$progress" "$agent_total" "$name" >&2
	done
	complete_project
	project_completion
)

# 実際に成功した create の件数だけを出す。再実行の既存利用は数えない。
project_completion() {
	printf '\nプロジェクトの設定が終わりました: %s（%s）\n' "$project_name" "${workspace_name:-$workspace_id}"
	printf '今回作った件数: エージェント %s 件、スクワッド %s 件、オートパイロット %s 件\n' "$created_agents" "$created_squads" "$created_autopilots"
	printf '%s\n' '次にすること:'
	printf '%s\n' '1. Multica の画面で、スクワッド・エージェント・スキル・ラベル・オートパイロットと、使うランタイムがオンラインかを確認してください。'
	printf '%s\n' '2. skeleton/ の案内に従い、各リポジトリの AGENTS.md・作業別のルールと、プロジェクトの説明・検証スキルを記入してください。'
	if [[ " $enabled " == *' dependabot-merger '* ]]; then
		printf '%s\n' '3. 選んだ各リポジトリに Dependabot の Webhook を登録してください（manual.md の「人間が行う Webhook の登録」）。'
	else
		printf '%s\n' '3. Dependabot の役は外したため、この役の Webhook の登録は不要です。'
	fi
	printf '%s\n' 'エージェント用のログインが切れた場合は、次を実行してから bash setup.sh を流し直してください。'
	if uses_runtime claude; then printf '  CLAUDE_CONFIG_DIR=%q claude\n' "$agent_home/claude"; fi
	if uses_runtime codex; then printf '  CODEX_HOME=%q codex login\n' "$agent_home/codex"; fi
}

# 質問中・ホスト準備中に変わりうるため、許可ファイルを書く直前に全件を確かめ直す。
project_repositories_recheck() {
	local latest_projects eligible_repos blocked_repos
	latest_projects=$(read_list プロジェクト project list) || die '許可先の再確認に必要なプロジェクトを取得できませんでした。'
	jq -e --arg id "$project_id" 'any(.[]; .id==$id)' >/dev/null <<<"$latest_projects" || die '許可先の再確認で対象のプロジェクトを確認できませんでした。'
	repository_choices "$selected_repositories" "$latest_projects" "$project_id"
	if [[ $(jq length <<<"$blocked_repos") != 0 ]]; then
		jq -r '.[] | "別プロジェクトに紐付いたため許可できません: \(.repository)（\(.projects|join("、"))）"' <<<"$blocked_repos" >&2
		die 'リポジトリの紐付けが選択時から変わりました。従来の許可を保って停止します。最初から選び直してください。'
	fi
}

# 一覧を文字列として一度だけ差し込む。記入欄は自動で補わない。
project_repository_values() {
	local repo
	: >"$project_work/repository-checks"
	while IFS= read -r repo; do
		jq -n --arg repository "$repo" '{repository:$repository}' >"$project_work/repository-value.json"
		template_apply "$project_work/repository-value.json" "$root/skeleton/verify-repository.md" >"$project_work/repository-check" || die 'リポジトリごとの検証のひな形を展開できませんでした。'
		sed 's/^#/##/' "$project_work/repository-check" >>"$project_work/repository-checks"
		printf '\n' >>"$project_work/repository-checks"
	done < <(jq -r '.[].repository' <<<"$selected_repositories")
	values=$(jq --argjson repos "$selected_repositories" --rawfile checks "$project_work/repository-checks" '.+{
		repositories:($repos|map("`"+.repository+"`")|join("、")),
		repository_roles:("| リポジトリ | 入っているもの・役割 | ここで受けるタスク |\n| --- | --- | --- |\n"+($repos|map("| `"+.repository+"` | [記入: 入っているもの・役割] | [記入: ここで受けるタスク] |")|join("\n"))),
		repository_checks:($checks|sub("\n+$";""))}' <<<"$values") || die 'リポジトリの一覧を指示の値にできませんでした。'
}

# 新規作成で付いた先頭も読み直し、足りない選択だけを追加する。外した紐付けは消さない。
project_resources() {
	local resources bound entry url repo
	resources=$(mc project resource list "$project_id" --output json) || die 'プロジェクトのリポジトリを読めませんでした。'
	jq -e 'type=="array" and all(.[]; (.resource_type|type=="string") and (if .resource_type=="github_repo" then (.resource_ref.url|type=="string" and length>0) else true end))' >/dev/null <<<"$resources" || die 'プロジェクトのリソースの応答が不正です。'
	bound=$(jq -c "$repository_filter"'[.[] | select(.resource_type=="github_repo") | .resource_ref.url | repository_name]' <<<"$resources") || die 'プロジェクトのリポジトリの URL が不正です。'
	while IFS= read -r entry; do
		url=$(jq -r '.url' <<<"$entry")
		repo=$(jq -r '.repository' <<<"$entry")
		if ! jq -e --arg repo "$repo" 'index($repo)!=null' >/dev/null <<<"$bound"; then
			mc project resource add "$project_id" --type github_repo --url "$url" --output json >/dev/null || die "リポジトリを紐付けられませんでした: $repo"
		fi
	done < <(jq -c '.[]' <<<"$selected_repositories")
}

project_result_id() { jq -er '.id | select(type=="string" and length>0)' <<<"$1"; }
project_named() {
	jq -e 'type=="array" and all(.[]; (.id|type=="string" and length>0))' >/dev/null <<<"$1" || die '一覧の応答が不正です。'
	matches=$(jq -c --arg field "$2" --arg value "$3" '[.[] | select(.[$field]==$value)]' <<<"$1")
	[[ $(jq length <<<"$matches") -le 1 ]] || die "同名のものが複数あります: $3"
}
project_role() {
	name=$(jq -r --arg role "$1" '.[$role].name' <<<"$records")
	id=$(jq -r --arg role "$1" '.[$role].id // empty' <<<"$records")
	model=$(jq -r --arg role "$1" '.[$role].model' <<<"$records")
	thinking=$(jq -r --arg role "$1" '.[$role].thinking_level' <<<"$records")
	runtime=$(jq -r --arg role "$1" '.[$role].runtime_id' <<<"$records")
	max=$(jq -r --arg role "$1" '.[$role].max_concurrent_tasks' <<<"$records")
}
project_desired_env() {
	local use_claude=false
	if uses_runtime claude; then use_claude=true; fi
	jq -n --arg a "$allowed_repos_file" --arg z "$project_shell_dir" --arg h "$agent_home/git-hooks" --arg c "$agent_home/claude" --arg role "$1" --arg model "$2" --argjson use_claude "$use_claude" '
		{SQUAD_KIT_ALLOWED_REPOS:$a,ZDOTDIR:$z,BASH_ENV:($z+"/env.sh"),GIT_CONFIG_COUNT:"1",GIT_CONFIG_KEY_0:"core.hooksPath",GIT_CONFIG_VALUE_0:$h} |
		if ($model|startswith("claude-")) then .+{CLAUDE_CONFIG_DIR:$c,ENABLE_CLAUDEAI_MCP_SERVERS:"false",CLAUDE_CODE_SHELL:"/bin/zsh",CLAUDE_CODE_AUTO_COMPACT_WINDOW:"150000"} else . end |
		if $role=="usage-monitor" and $use_claude then .+{CLAUDE_CONFIG_DIR:$c} else . end |
		if $role=="dependabot-merger" then .+{SQUAD_KIT_GH_DEPENDABOT_MERGE:"1"} else . end'
}

project_skills() {
	local skills dir skill_name skill_base result skill_id wanted key target skill_source
	skills=$(mc skill list --output json) || die 'スキルを取得できませんでした。'
	# 作る前に、共通スキルの不足と名前の重複もまとめて検証する。
	for role in $enabled; do
		wanted='[]'
		while IFS= read -r key; do
			[[ -n $key ]] || continue
			case $key in squad-*) target=$key ;; *) target=$project_key-$key ;; esac
			project_named "$skills" name "$target"
			if [[ $(jq length <<<"$matches") == 0 ]]; then
				[[ $key != squad-* && -f $root/skeleton/.agents/skills/$key/SKILL.md ]] || die "必要なスキルがありません: $target"
			fi
			wanted=$(jq -c --arg name "$target" '.+[$name]' <<<"$wanted")
		done < <(template_field "$project_work/$role.rendered" skills | tr ',' '\n' | sed 's/^ *//;s/ *$//')
		printf '%s\n' "$wanted" >"$project_work/$role.skill-names"
	done
	for dir in "$root/skeleton/.agents/skills/"*/; do
		[[ -d $dir ]] || continue
		skill_base=$(basename "$dir")
		skill_name=$project_key-$skill_base
		[[ $(template_field "$dir/SKILL.md" name) == "$skill_base" ]] || die 'プロジェクトのスキル名が不正です。'
		project_named "$skills" name "$skill_name"
		skill_id=$(jq -r '.[0].id // empty' <<<"$matches")
		if [[ -n $skill_id ]] && { [[ ! -f $root/extension-skills ]] || ! grep -qx "$skill_base" "$root/extension-skills"; }; then continue; fi
		mkdir -p "$project_work/skills/$skill_name"
		cp -R "$dir". "$project_work/skills/$skill_name/" || die 'スキルを準備できませんでした。'
		skill_source="$dir/SKILL.md"
		if [[ $skill_base == verify ]]; then
			template_apply "$project_work/values.json" "$skill_source" >"$project_work/verify.rendered" || die '検証のスキルを展開できませんでした。'
			skill_source="$project_work/verify.rendered"
		fi
		awk -v name="$skill_name" 'NR==1 {inside=1; print; next} inside && /^---$/ {inside=0} inside && /^name: / {$0="name: " name} {print}' "$skill_source" >"$project_work/skills/$skill_name/SKILL.md"
		if [[ -n $skill_id ]]; then
			sync_local_project_skill "$project_work/skills/$skill_name" "$skill_name" "$skill_id"
			continue
		fi
		(cd "$project_work/skills/$skill_name" && zip -qr "$project_work/$skill_name.zip" .) || die 'スキルを ZIP にできませんでした。'
		result=$(mc skill import --file "$project_work/$skill_name.zip" --on-conflict fail --output json) || die 'プロジェクトのスキルを取り込めませんでした。'
		skill_id=$(jq -er --arg name "$skill_name" 'select(.status=="created" and .skill.name==$name) | .skill.id | select(type=="string" and length>0)' <<<"$result") || die 'スキル取り込みの応答が不正です。'
		skills=$(jq -c --arg id "$skill_id" --arg name "$skill_name" '.+[{id:$id,name:$name}]' <<<"$skills")
	done
	for role in $enabled; do
		jq -nr --argjson skills "$skills" --slurpfile names "$project_work/$role.skill-names" '[$names[0][] as $name | $skills[] | select(.name==$name) | .id] | unique | sort | join(",")' >"$project_work/$role.skills"
	done
}

project_mcp() {
	if [[ -f $root/extension-mcp.json ]]; then jq -c --arg role "$1" '.[$role] // null' "$root/extension-mcp.json"; else printf 'null\n'; fi
}
