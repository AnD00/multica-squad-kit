# 登録時の応答を使わず、現在の値を定義と比べる。失敗も対象ごとの要確認にする。
installation_result() {
	local status=要確認 reason=${3:-定義と一致しません。}
	if [[ $2 == yes ]]; then status=一致; reason=''; fi
	setup_installation_rows=$(jq -c --arg name "$1" --arg status "$status" --arg reason "$reason" '.+[{name:$name,status:$status,reason:$reason}]' <<<"$setup_installation_rows")
}

installation_workspace() {
	local skills labels name color description matched reason=''
	skills=$(mc skill list --output json 2>/dev/null | jq -ce 'select(type=="array") | map({id,name})' 2>/dev/null) || { skills='[]'; reason='CLI の読み直しに失敗しました。'; }
	matched=no
	if jq -e '[.[]|select(.name=="squad-handoff" and (.id|type=="string" and length>0))]|length==1' >/dev/null <<<"$skills"; then matched=yes; fi
	installation_result '共通スキル squad-handoff' "$matched" "$reason"
	reason=''
	labels=$(mc label list --resource-type issue --output json 2>/dev/null | jq -ce 'select(type=="array") | map({id,name})' 2>/dev/null) || { labels='[]'; reason='CLI の読み直しに失敗しました。'; }
	while IFS='|' read -r name color description; do
		[[ -n $name && $name != \#* ]] || continue
		matched=no
		if jq -e --arg name "$name" '[.[]|select(.name==$name and (.id|type=="string" and length>0))]|length==1' >/dev/null <<<"$labels"; then matched=yes; fi
		installation_result "ラベル $name" "$matched" "$reason"
	done <"$root/common/labels"
}

installation_agents() {
	local role desired name id current skills matched reason
	installation_agents_read=yes
	installation_agent_list=$(mc agent list --output json 2>/dev/null | jq -ce 'select(type=="array" and all(.[]; (.id|type=="string") and (.name|type=="string"))) | map({id,name})' 2>/dev/null) || { installation_agent_list='[]'; installation_agents_read=no; }
	for role in $enabled; do
		reason=''
		[[ $installation_agents_read == yes ]] || reason='CLI の読み直しに失敗しました。'
		desired=$(jq -c --arg role "$role" '.[$role]' <<<"$records")
		name=$(jq -r '.name' <<<"$desired"); id=$(jq -r '.id' <<<"$desired")
		skills=$(cat "$project_work/$role.skills")
		current=$(mc agent get "$id" --output json 2>/dev/null | jq -ce 'select(.id|type=="string" and length>0) | {id,name,owner_id,model,thinking_level,runtime_id,max_concurrent_tasks,permission_mode,invocation_targets,skills}' 2>/dev/null) || { current='{}'; reason='CLI の読み直しに失敗しました。'; }
		matched=no
		if jq -e --argjson desired "$desired" --arg owner "$host_owner_id" --arg skills "$skills" --argjson list "$installation_agent_list" '
			([ $list[] | select(.name==$desired.name) ]|length)==1 and any($list[]; .id==$desired.id and .name==$desired.name) and
			.id==$desired.id and .name==$desired.name and .owner_id==$owner and
			.model==$desired.model and .thinking_level==$desired.thinking_level and .runtime_id==$desired.runtime_id and
			.max_concurrent_tasks==$desired.max_concurrent_tasks and .permission_mode=="public_to" and
			([.invocation_targets[]?.target_type]|sort)==["workspace"] and
			([.skills[]?.id]|sort|join(","))==$skills
		' >/dev/null 2>&1 <<<"$current"; then matched=yes; fi
		installation_result "エージェント $name" "$matched" "$reason"
	done
}

installation_squad() {
	local current roster expected='[]' role wanted id names known matched=no reason=''
	[[ $installation_agents_read == yes ]] || reason='CLI の読み直しに失敗しました。'
	for role in $enabled; do
		wanted=$(template_field "$project_work/$role.rendered" role)
		[[ -n $wanted ]] || continue
		[[ $role != orchestrator ]] || wanted=leader
		id=$(jq -r --arg role "$role" '.[$role].id' <<<"$records")
		expected=$(jq -c --arg id "$id" --arg role "$wanted" '.+[{id:$id,role:$role}]' <<<"$expected")
	done
	names=$(jq -nc --arg roles "$template_roles" --arg prefix "$project_key-" --arg suffix "-$member_key" '[$roles|split(" ")[]|select(length>0)|$prefix+.+$suffix]')
	known=$(jq -c --argjson names "$names" --argjson records "$records" '[.[]|select(.name as $name|$names|index($name)!=null)|.id]+[$records[].id]|unique' <<<"$installation_agent_list")
	current=$(mc squad get "$squad_id" --output json 2>/dev/null | jq -ce 'select(.id|type=="string" and length>0) | {id,name,creator_id,leader_id,instructions}' 2>/dev/null) || { current='{}'; reason='CLI の読み直しに失敗しました。'; }
	roster=$(mc squad member list "$squad_id" --output json 2>/dev/null | jq -ce 'select(type=="array" and all(.[]; (.member_type=="agent" or .member_type=="member") and (.member_id|type=="string"))) | map({member_id,member_type,role})' 2>/dev/null) || { roster=null; reason='CLI の読み直しに失敗しました。'; }
	if [[ $installation_agents_read == yes ]] && jq -e --arg id "$squad_id" --arg name "$squad_name" --arg owner "$host_owner_id" --arg leader "$(jq -r '.orchestrator.id' <<<"$records")" --rawfile instructions "$project_work/squad.instructions" --argjson roster "$roster" --argjson expected "$expected" --argjson known "$known" --argjson people "$member_ids" '
		.id==$id and .name==$name and .creator_id==$owner and .leader_id==$leader and
		.instructions==($instructions|sub("\n+$";"")) and ($roster|type=="array") and
		all($expected[]; . as $wanted | [$roster[]|select(.member_type=="agent" and .member_id==$wanted.id)] | length==1 and .[0].role==$wanted.role) and
		all($people[]; . as $id | any($roster[]; .member_type=="member" and .member_id==$id)) and
		all($roster[]|select(.member_type=="agent"); .member_id as $id |
			($known|index($id))==null or any($expected[]; .id==$id))
	' >/dev/null 2>&1 <<<"$current"; then matched=yes; fi
	installation_result "スクワッド $squad_name" "$matched" "$reason"
}

installation_autopilots() {
	local list desired title id assignee current matched reason list_reason=''
	list=$(mc autopilot list --output json 2>/dev/null | jq -ce '.autopilots | select(type=="array") | map({id,title})' 2>/dev/null) || { list='[]'; list_reason='CLI の読み直しに失敗しました。'; }
	while IFS= read -r desired; do
		reason=$list_reason
		title=$(jq -r '.title' <<<"$desired")
		id=$(jq -r --arg title "$title" '[.[]|select(.title==$title)] | if length==1 then .[0].id else empty end' <<<"$list")
		matched=no
		if [[ -n $id ]]; then
			assignee=$(jq -r --arg name "$(jq -r '.agent' <<<"$desired")" '[.[]|select(.name==$name)|.id] | if length==1 then .[0] else empty end' <<<"$records")
			# Webhook の認証情報は通常の取得結果からも除いてから受け取る。
			current=$(mc autopilot get "$id" --output json 2>/dev/null | jq -ce 'select(.autopilot.id|type=="string" and length>0) | {autopilot:(.autopilot|{id,title,status,project_id,assignee_type,assignee_id,execution_mode,description}),triggers:[.triggers[]|{kind,enabled,cron_expression,timezone}]}' 2>/dev/null) || { current='{}'; reason='CLI の読み直しに失敗しました。'; }
			if jq -e --arg id "$id" --arg project "$project_id" --arg assignee "$assignee" --argjson desired "$desired" '
				.autopilot as $current | $current.id==$id and $current.title==$desired.title and $current.status=="active" and
				$current.project_id==$project and $current.assignee_type=="agent" and $current.assignee_id==$assignee and
				$current.execution_mode==$desired.mode and $current.description==($desired.instructions|sub("\n+$";"")) and
				(if $desired.trigger=="webhook" then any(.triggers[]; .kind=="webhook" and .enabled==true) and all(.triggers[]; .kind!="schedule")
				else [.triggers[]|select(.kind=="schedule")][0] | .enabled==true and .cron_expression==$desired.cron and .timezone==$desired.timezone end)
			' >/dev/null 2>&1 <<<"$current"; then matched=yes; fi
		fi
		installation_result "オートパイロット $title" "$matched" "$reason"
	done < <(jq -c '.[]' "$project_work/autopilots.json")
}

installation_runtimes() {
	local list provider id matched reason=''
	list=$(mc runtime list --output json 2>/dev/null | jq -ce 'select(type=="array") | map({id,provider,status})' 2>/dev/null) || { list='[]'; reason='CLI の読み直しに失敗しました。'; }
	for provider in claude codex; do
		uses_runtime "$provider" || continue
		case $provider in claude) id=${claude_runtime_id:-} ;; codex) id=${codex_runtime_id:-} ;; esac
		matched=no
		if jq -e --arg id "$id" --arg provider "$provider" '[.[]|select(.id==$id and .provider==$provider and .status=="online")]|length==1' >/dev/null <<<"$list"; then matched=yes; fi
		installation_result "ランタイム $provider" "$matched" "$reason"
	done
}

verify_project_installation() {
	local installation_agent_list='[]' installation_agents_read=no targets
	setup_installation_rows='[]'
	installation_workspace
	installation_agents
	installation_squad
	installation_autopilots
	installation_runtimes
	targets=$(jq -c '[.[]|select(.status=="要確認")|.name]|unique' <<<"$setup_installation_rows")
	if [[ $(jq length <<<"$targets") != 0 ]]; then queue_project_issue installation-check "$targets" "$host_owner_id"; fi
}

project_installation_completion() {
	[[ $(jq length <<<"${setup_installation_rows:-[]}") != 0 ]] || return 0
	printf '%s\n' '導入の確認:'
	jq -r '.[] | "  \(.name): \(.status)" + (if .reason=="" then "" else "。\(.reason)" end)' <<<"$setup_installation_rows"
}
