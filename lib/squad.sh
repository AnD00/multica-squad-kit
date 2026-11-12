# プロジェクトとエージェントの実 ID を使い、スクワッドとオートパイロットを設定する。
complete_project() {
	local squad_current roster agents managed role file id name wanted current person matches
	squad_member_count=${squad_member_count:-0}
	# 指示とオートパイロットの定義は、書き込みより先にすべて展開して確かめる。
	template_filter "$enabled" "$root/common/squad.md" >"$project_work/squad.filtered" || die 'スクワッドの役の印が不正です。'
	template_apply "$project_work/values.json" "$project_work/squad.filtered" >"$project_work/squad.instructions" || die 'スクワッドの指示を展開できませんでした。'
	prepare_autopilots
	squad_current=$(mc squad get "$squad_id" --output json) || die 'スクワッドを読めませんでした。'
	jq -e --arg id "$squad_id" --arg owner "$host_owner_id" '.id==$id and .creator_id==$owner' >/dev/null <<<"$squad_current" || die 'スクワッドの ID か所有者が違います。'
	roster=$(mc squad member list "$squad_id" --output json) || die 'スクワッドのメンバーを読めませんでした。'
	jq -e 'type=="array" and all(.[]; (.member_type=="agent" or .member_type=="member") and (.member_id|type=="string" and length>0))' >/dev/null <<<"$roster" || die 'スクワッドのメンバーの応答が不正です。'
	agents=$(mc agent list --output json) || die '外した役のエージェントを取得できませんでした。'
	jq -e 'type=="array" and all(.[]; (.id|type=="string" and length>0) and (.name|type=="string"))' >/dev/null <<<"$agents" || die 'エージェント一覧の応答が不正です。'
	jq -e 'type=="array" and all(.[]; type=="string" and length>0)' >/dev/null <<<"$member_ids" || die '選んだ人間の ID が不正です。'
	# 削除の対象を、既知の役の完成名・所有者・実 ID に限定する。
	managed='{}'
	for role in $template_roles; do
		name=$project_key-$role-$member_key
		project_named "$agents" name "$name"
		current=$(jq -c '.[0] // empty' <<<"$matches")
		[[ -n $current ]] || continue
		[[ $(jq -r '.owner_id // empty' <<<"$current") == "$host_owner_id" ]] || continue
		managed=$(jq -c --arg role "$role" --argjson agent "$current" '.+{($role):$agent}' <<<"$managed")
	done
	for role in $enabled; do
		jq -e --arg role "$role" --argjson records "$records" '.[$role].id==$records[$role].id and .[$role].owner_id!=null' >/dev/null <<<"$managed" || die '有効な役の ID か所有者が変わっています。'
	done
	if ! jq -e --rawfile instructions "$project_work/squad.instructions" --arg leader "$(jq -r '.orchestrator.id' <<<"$records")" '.leader_id==$leader and (.instructions // "")==($instructions|sub("\n+$";""))' >/dev/null <<<"$squad_current"; then
		mc squad update "$squad_id" --leader "$(jq -r '.orchestrator.id' <<<"$records")" --instructions "$(cat "$project_work/squad.instructions")" --output json >/dev/null || die 'スクワッドの指示を反映できませんでした。'
	fi
	# 更新によりリーダーが自動追加される場合があるので、現在の一覧を読み直す。
	roster=$(mc squad member list "$squad_id" --output json) || die '更新後のメンバーを読めませんでした。'
	jq -e 'type=="array" and all(.[]; (.member_type=="agent" or .member_type=="member") and (.member_id|type=="string" and length>0))' >/dev/null <<<"$roster" || die '更新後のメンバーの応答が不正です。'
	for role in $enabled; do
		id=$(jq -r --arg role "$role" '.[$role].id' <<<"$records")
		wanted=$(template_field "$project_work/$role.rendered" role) || die '役の説明を読めませんでした。'
		[[ -n $wanted ]] || continue
		if [[ $role == orchestrator ]]; then
			if ! jq -e --arg id "$id" 'any(.[]; .member_type=="agent" and .member_id==$id)' >/dev/null <<<"$roster"; then
				mc squad member add "$squad_id" --member-id "$id" --type agent --role leader --output json >/dev/null || die 'リーダーを追加できませんでした。'
			fi
			squad_member_count=$((squad_member_count+1))
			continue
		fi
		squad_member_count=$((squad_member_count+1))
		current=$(jq -c --arg id "$id" '[.[] | select(.member_type=="agent" and .member_id==$id)]' <<<"$roster")
		[[ $(jq length <<<"$current") -le 1 ]] || die '同じエージェントが複数登録されています。'
		if [[ $(jq length <<<"$current") == 0 ]]; then
			mc squad member add "$squad_id" --member-id "$id" --type agent --role "$wanted" --output json >/dev/null || die '役をスクワッドに追加できませんでした。'
		elif [[ $(jq -r '.[0].role // empty' <<<"$current") != "$wanted" ]]; then
			mc squad member set-role "$squad_id" --member-id "$id" --member-type agent --role "$wanted" --output json >/dev/null || die 'スクワッドの役を更新できませんでした。'
		fi
	done
	while IFS= read -r person; do
		[[ -n $person ]] || continue
		jq -e --arg id "$person" 'any(.[]; .user_id==$id)' >/dev/null <<<"$people" || die '選んだ人間がワークスペースに見つかりません。'
		squad_member_count=$((squad_member_count+1))
		if ! jq -e --arg id "$person" 'any(.[]; .member_type=="member" and .member_id==$id)' >/dev/null <<<"$roster"; then
			mc squad member add "$squad_id" --member-id "$person" --type member --role member --output json >/dev/null || die '人間をスクワッドに追加できませんでした。'
		fi
	done < <(jq -r 'unique[]' <<<"$member_ids")
	for role in $template_roles; do
		current=$(jq -c --arg role "$role" '.[$role] // empty' <<<"$managed")
		[[ -n $current ]] || continue
		wanted=''
		if [[ " $enabled " == *" $role "* ]]; then wanted=$(template_field "$project_work/$role.rendered" role); fi
		[[ -z $wanted ]] || continue
		id=$(jq -r '.id' <<<"$current"); name=$(jq -r '.name' <<<"$current")
		if jq -e --arg id "$id" 'any(.[]; .member_type=="agent" and .member_id==$id)' >/dev/null <<<"$roster"; then
			mc squad member remove "$squad_id" --member-id "$id" --type agent --output json >/dev/null || die "外した役をスクワッドから外せませんでした: $name"
		fi
		if [[ " $enabled " != *" $role "* ]]; then
			ui_notice warn "エージェントは残しています（削除は人間が判断）: $name" || ui_warning "エージェントは残しています（削除は人間が判断）: $name"
			setup_removed_targets=$(jq -c --arg name "$name" '.+[$name]|unique' <<<"${setup_removed_targets:-[]}")
		fi
	done
	ui_phase_done "$squad_member_count"
	sync_project_autopilots "$managed"
}
