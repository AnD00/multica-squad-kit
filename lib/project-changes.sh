# 実行前からある検証スキルの、コードブロック外のリポジトリの節だけを読む。
project_verify_repositories() {
	jq -c 'reduce (.content|split("\n")[]) as $line ({code:false,repositories:[]};
		if ($line|test("^(```|~~~)")) then .code=(.code|not)
		elif .code then .
		else .repositories += [$line | capture("^## `(?<repository>[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9_.-]+)`\\r?$")? | .repository | ascii_downcase] end)
		| .repositories | unique' <<<"$1"
}

# 共通スキルを読み直し、原本にそろっていないときだけ、更新を頼む担当 ID を返す。
project_handoff_update_assignee() (
	local skills matches id remote_skill skill_files skill_description
	local skill_name=squad-handoff skill_dir="$root/common/skills/squad-handoff" url
	skills=$(mc skill list --output json) || die '共通スキルの一覧を読み直せませんでした。'
	project_named "$skills" name "$skill_name"
	id=$(jq -er 'select(length==1) | .[0].id' <<<"$matches") || die '共通スキル squad-handoff が見つかりません。'
	read_workspace_skill "$id"
	workspace_local_files
	url="https://github.com/AnD00/multica-squad-kit/tree/${kit_version:-$(cat "$root/VERSION")}/common/skills/squad-handoff"
	if workspace_skill_same && jq -e --arg url "$url" '.config.origin.type=="github" and .config.origin.source_url==$url' >/dev/null <<<"$remote_skill"; then return 0; fi
	jq -r --argjson people "$people" --arg fallback "$host_owner_id" '.created_by as $creator |
		if any($people[]; .user_id==$creator) then $creator else $fallback end' <<<"$remote_skill"
)

prepare_project_change_issues() {
	local assignee target repo selected changes
	if assignee=$(project_handoff_update_assignee 2>"$project_work/issue-error"); then
		if [[ -n $assignee ]]; then
			target=$(jq -nc --arg tag "${kit_version:-$(cat "$root/VERSION")}" '["squad-handoff@"+$tag]')
			queue_project_issue handoff-skill-update "$target" "$assignee"
		fi
	else
		record_project_issue_failure handoff-skill-update '' '共通スキルを読み直せなかったため、更新を頼む対象を確かめられませんでした。'
	fi
	if [[ $(jq length <<<"${setup_removed_targets:-[]}") != 0 ]]; then
		queue_project_issue removed-roles "$setup_removed_targets" "$host_owner_id"
	fi
	# null は、この実行で検証スキルをひな形から作った場合。増減を起票しない。
	if [[ ${project_previous_repositories:-null} != null ]]; then
		selected=$(jq -c '[.[].repository]|unique' <<<"$selected_repositories")
		changes=$(jq -nc --argjson before "$project_previous_repositories" --argjson after "$selected" '
			[($after-$before)[]|"added:"+.] + [($before-$after)[]|"removed:"+.]')
		while IFS= read -r target; do
			repo=${target#*:}
			queue_project_issue repository-change "$(jq -nc --arg target "$target" '[$target]')" "$host_owner_id" "$repo"
		done < <(jq -r '.[]' <<<"$changes")
	fi
}
