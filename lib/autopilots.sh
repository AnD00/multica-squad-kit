# 指示の Markdown の節を読む。コードブロックの中の見出しはメタデータにしない。
autopilot_sections() {
	jq -Rs '
		reduce (split("\n")[]) as $line ({sections:[],current:null,code:false};
			if .code then
				if $line=="```" then .code=false else .current.instructions+=($line+"\n") end
			elif ($line|startswith("## ")) then
				if .current!=null then .sections+=[.current] else . end |
				.current={title:($line|ltrimstr("## ")),instructions:""}
			elif .current==null then .
			elif $line=="```text" then .code=true
			elif ($line|startswith("- 範囲: ")) then .current.scope=($line|capture("^- 範囲: `(?<scope>[^`]+)`$").scope)
			elif ($line|startswith("- 担当: ")) then .current.agent=($line|ltrimstr("- 担当: "))
			elif ($line|startswith("- 実行: ")) then .current.mode=($line|capture("^- 実行: `(?<mode>[^`]+)`$").mode)
			elif ($line|startswith("- スケジュール: ")) then
				($line|capture("^- スケジュール: `(?<cron>[^`]+)`（(?<timezone>[^）]+)）$")) as $schedule |
				.current.cron=$schedule.cron | .current.timezone=$schedule.timezone
			else . end) |
		if .code then error("閉じていない指示のコードブロック") else
			.sections + (if .current==null then [] else [.current] end)
		end | if all(.[]; (.title|type=="string" and length>0) and (.agent|type=="string" and length>0) and
			(.scope=="repository" or .scope=="member") and
			(.mode=="create_issue" or .mode=="run_only") and (.instructions|length>0) and
			(.cron|type=="string" and length>0) and (.timezone|type=="string" and length>0))
		then . else error("オートパイロットの定義が不正") end' "$1"
}

prepare_autopilots() {
	local definitions section role title repo first=yes
	jq -e 'type=="array" and length>0 and all(.[]; .repository|type=="string" and test("^[a-z0-9][a-z0-9_.-]*/[a-z0-9_.-]+$")) and ([.[].repository]|length==(unique|length))' >/dev/null <<<"$selected_repositories" || die 'オートパイロットのリポジトリの一覧が不正です。'
	template_filter "$enabled" "$root/common/autopilots.md" >"$project_work/autopilots.filtered" || die 'オートパイロットの役の印が不正です。'
	printf '[]\n' >"$project_work/autopilots.json"
	while IFS= read -r repo; do
		jq --arg repo "$repo" '.repository=$repo' "$project_work/values.json" >"$project_work/autopilot.values"
		template_apply "$project_work/autopilot.values" "$project_work/autopilots.filtered" >"$project_work/autopilots.rendered" || die 'オートパイロットを展開できませんでした。'
		autopilot_sections "$project_work/autopilots.rendered" >"$project_work/autopilots.sections" || die 'オートパイロットの定義を読めませんでした。'
		jq --arg repo "$repo" --arg first "$first" --slurpfile sections "$project_work/autopilots.sections" '.+[$sections[0][] | select(.scope=="repository" or $first=="yes") | .+{repository:(if .scope=="repository" then $repo else null end)}]' "$project_work/autopilots.json" >"$project_work/autopilots.new"
		mv "$project_work/autopilots.new" "$project_work/autopilots.json"
		first=no
	done < <(jq -r '.[].repository' <<<"$selected_repositories")
	jq -e --argjson records "$records" 'all(.[]; .agent as $name | any($records[]; .name==$name and (.id|length>0)))' "$project_work/autopilots.json" >/dev/null || die 'オートパイロットの担当が有効な役ではありません。'
	jq -e '[.[].title] | length==(unique|length)' "$project_work/autopilots.json" >/dev/null || die 'オートパイロットの名前が重複しています。'
	# 選択から外したリポジトリと、外した役を見つけるため元の名前の規則も読む。
	template_filter "$template_roles" "${autopilots_known_source:-$root/common/autopilots.md}" >"$project_work/autopilots.all" || die '元のオートパイロットの印が不正です。'
	definitions=$(autopilot_sections "$project_work/autopilots.all") || die '元のオートパイロットの定義を読めませんでした。'
	printf '[]\n' >"$project_work/autopilots.known"
	while IFS= read -r section; do
		role=$(jq -er '.agent | capture("^\\{\\{agent\\.(?<role>[a-z-]+)\\.name\\}\\}$").role' <<<"$section") || die '元のオートパイロットの担当が不正です。'
		[[ " $template_roles " == *" $role "* ]] || die '未知の役がオートパイロットの担当です。'
		if [[ $(jq -r '.scope' <<<"$section") == repository ]]; then
			jq -er '.title|select(endswith(" {{repository}}"))|rtrimstr("{{repository}}")' <<<"$section" >"$project_work/autopilot.title" || die 'リポジトリごとの名前は repository で終えてください。'
		else
			jq -jr '.title' <<<"$section" >"$project_work/autopilot.title"
		fi
		title=$(template_apply "$project_work/values.json" "$project_work/autopilot.title") || die 'オートパイロットの名前を展開できませんでした。'
		# prefix の末尾の空白は残す。コマンド置換で末尾の改行だけを除く。
		jq --arg role "$role" --arg title "$title" --arg scope "$(jq -r '.scope' <<<"$section")" '.+[{role:$role,title:$title,scope:$scope}]' "$project_work/autopilots.known" >"$project_work/known.new"
		mv "$project_work/known.new" "$project_work/autopilots.known"
	done < <(jq -c 'reduce .[] as $item ([]; if any(.[]; .title==$item.title) then . else .+[$item] end) | .[]' <<<"$definitions")
}

sync_project_autopilots() {
	local managed=$1 list current record title id role assignee mode instructions cron timezone triggers schedule result known prefix repo action
	local auto_total progress=0
	auto_total=$(jq length "$project_work/autopilots.json") || die 'オートパイロットの件数を読めませんでした。'
	printf 'オートパイロット 0/%s（既存の設定を確認中）\n' "$auto_total" >&2
	list=$(mc autopilot list --output json) || die 'オートパイロットを取得できませんでした。'
	jq -e '.autopilots|type=="array" and all(.[]; (.id|type=="string" and length>0) and (.title|type=="string") and (.assignee_id|type=="string"))' >/dev/null <<<"$list" || die 'オートパイロット一覧の応答が不正です。'
	list=$(jq -c '.autopilots' <<<"$list")
	while IFS= read -r record; do
		title=$(jq -r '.title' <<<"$record")
		progress=$((progress+1))
		printf 'オートパイロット %s/%s を設定中: %s\n' "$progress" "$auto_total" "$title" >&2
		assignee=$(jq -er --arg name "$(jq -r '.agent' <<<"$record")" '[.[]|select(.name==$name)] | select(length==1) | .[0].id' <<<"$records") || die '担当の実 ID がありません。'
		project_named "$list" title "$title"
		current=$(jq -c '.[0] // empty' <<<"$matches")
		# 同名でも他プロジェクト・他の人の担当へは書き込まない。
		if [[ -n $current ]]; then
			if ! jq -e --arg project "$project_id" --argjson managed "$managed" '.project_id==$project and .assignee_type=="agent" and (.assignee_id as $id | any($managed[]; .id==$id))' >/dev/null <<<"$current"; then
				printf 'オートパイロットを保持しました（別の担当またはプロジェクト）: %s\n' "$title" >&2
				continue
			fi
			id=$(jq -r '.id' <<<"$current")
			result=$(mc autopilot get "$id" --output json) || die 'オートパイロットを読めませんでした。'
			current=$(jq -ec --arg id "$id" '.autopilot | select(.id==$id)' <<<"$result") || die 'オートパイロットの応答が不正です。'
			jq -e --arg project "$project_id" --argjson managed "$managed" '.project_id==$project and .assignee_type=="agent" and (.assignee_id as $id | any($managed[]; .id==$id))' >/dev/null <<<"$current" || die 'オートパイロットの担当かプロジェクトが変わりました。'
		else
			id=''
		fi
		mode=$(jq -r '.mode' <<<"$record"); instructions=$(jq -r '.instructions|sub("\n+$";"")' <<<"$record")
		cron=$(jq -r '.cron' <<<"$record"); timezone=$(jq -r '.timezone' <<<"$record")
		if [[ -z $id ]]; then
			result=$(mc autopilot create --title "$title" --description "$instructions" --mode "$mode" --project "$project_id" --agent "$assignee" --output json) || die "オートパイロットを作れませんでした: $title"
			id=$(jq -er '(.id // .autopilot.id) | select(type=="string" and length>0)' <<<"$result") || die 'オートパイロット作成の応答が不正です。'
			created_autopilots=$((${created_autopilots:-0}+1))
		elif ! jq -e --arg instructions "$instructions" --arg mode "$mode" --arg assignee "$assignee" '.description==$instructions and .execution_mode==$mode and .assignee_id==$assignee' >/dev/null <<<"$current"; then
			mc autopilot update "$id" --description "$instructions" --mode "$mode" --project "$project_id" --agent "$assignee" --output json >/dev/null || die "オートパイロットを更新できませんでした: $title"
		fi
		# 作成後にも読む。作成に成功してトリガー追加で失敗した回を再実行できる。
		triggers=$(mc autopilot trigger-list "$id" --output json) || die 'オートパイロットのスケジュールを読めませんでした。'
		schedule=$(jq -ec '.triggers | select(type=="array" and all(.[]; (.id|type=="string" and length>0))) | map(select(.kind=="schedule"))' <<<"$triggers") || die 'スケジュールの応答が不正です。'
		# 先頭のスケジュールを合わせ、ほかの手動のトリガーは保つ。
		if [[ $(jq length <<<"$schedule") == 0 ]]; then
			mc autopilot trigger-add "$id" --kind schedule --cron "$cron" --timezone "$timezone" --output json >/dev/null || die 'スケジュールを追加できませんでした。'
		elif ! jq -e --arg cron "$cron" --arg timezone "$timezone" '.[0].cron_expression==$cron and .[0].timezone==$timezone' >/dev/null <<<"$schedule"; then
			mc autopilot trigger-update "$id" "$(jq -r '.[0].id' <<<"$schedule")" --cron "$cron" --timezone "$timezone" --output json >/dev/null || die 'スケジュールを更新できませんでした。'
		fi
	done < <(jq -c '.[]' "$project_work/autopilots.json")
	while IFS= read -r known; do
		role=$(jq -r '.role' <<<"$known"); prefix=$(jq -r '.title' <<<"$known")
		while IFS= read -r current; do
			title=$(jq -r '.title' <<<"$current"); action=''
			if [[ $(jq -r '.scope' <<<"$known") == repository ]]; then
				[[ $title == "$prefix"* ]] || continue
				repo=${title#"$prefix"}
				[[ $repo =~ ^[a-z0-9][a-z0-9_.-]*/[a-z0-9_.-]+$ ]] || continue
				if ! jq -e --arg repo "$repo" 'any(.[]; .repository==$repo)' >/dev/null <<<"$selected_repositories"; then action=pause; fi
			else
				[[ $title == "$prefix" ]] || continue
			fi
			if [[ -z $action ]]; then
				if [[ " $enabled " == *" $role "* ]] && jq -e --arg title "$title" 'any(.[]; .title==$title)' "$project_work/autopilots.json" >/dev/null; then continue; fi
				assignee=$(jq -r --arg role "$role" '.[$role].id // empty' <<<"$managed")
				[[ -n $assignee && $(jq -r '.assignee_id' <<<"$current") == "$assignee" ]] || continue
				action=pause
			fi
			jq -e --arg project "$project_id" '.project_id==$project' >/dev/null <<<"$current" || continue
			if ! autopilot_owned "$current" "$managed"; then
				printf 'オートパイロットを保持しました（別の担当）: %s\n' "$title" >&2
				continue
			fi
			id=$(jq -r '.id' <<<"$current")
			result=$(mc autopilot get "$id" --output json) || die '整理するオートパイロットを読めませんでした。'
			current=$(jq -ec --arg id "$id" --arg title "$title" '.autopilot | select(.id==$id and .title==$title)' <<<"$result") || die '整理するオートパイロットの応答が不正です。'
			autopilot_owned "$current" "$managed" || die '整理するオートパイロットの担当かプロジェクトが変わりました。'
			jq -e '.status=="active" or .status=="paused"' >/dev/null <<<"$current" || die '一時停止するオートパイロットの状態が不正です。'
			if [[ $(jq -r '.status' <<<"$current") != paused ]]; then
				mc autopilot update "$id" --status paused --output json >/dev/null || die "外した定義のオートパイロットを一時停止できませんでした: $title"
			fi
			printf '外したリポジトリ・役・定義のオートパイロットを一時停止しています（履歴は保持）: %s\n' "$title" >&2
		done < <(jq -c '.[]' <<<"$list")
	done < <(jq -c '.[]' "$project_work/autopilots.known")
}

autopilot_owned() {
	jq -e --arg project "$project_id" --argjson managed "$2" '.project_id==$project and .assignee_type=="agent" and (.assignee_id as $id | any($managed[]; .id==$id))' >/dev/null <<<"$1"
}
