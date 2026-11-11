# 起票の土台。条件の判定と担当 ID の解決、完了の表示は呼び出す側が行う。
# ensure_setup_issue 種類 対象のJSON配列 担当ID [OWNER/REPO]
# 成功時は {id,identifier,title,action,targets} の配列を返し、失敗時は 1 を返す。
# 一時ファイルを CLI の作業ディレクトリ内に置くため、原本へ cd して使う。

setup_issue_error() { printf '%s\n' "$*" >&2; return 1; }

setup_issue_description() {
	jq -r --arg repository "$2" --arg manual_url "$3" --argjson targets "$4" '
		.body | split("{{repository}}") | join($repository) | split("{{manual_url}}") | join($manual_url) |
		split("{{targets}}") | join($targets|map("- "+.)|join("\n"))
	' <<<"$1"
}

# has_more や total が古いサーバーで不正確でも、空のページまで読む。
setup_issue_list() {
	local kind=$1 page count offset=0 issues='[]'
	local -a filter=()
	[[ -z $kind ]] || filter=(--metadata "squad_kit_task=$kind")
	while :; do
		page=$(mc issue list --project "$project_id" ${filter[@]+"${filter[@]}"} --limit 100 --offset "$offset" --output json) || { setup_issue_error '起票済みのタスクを読めませんでした。'; return 1; }
		jq -e '(.issues|type=="array") and all(.issues[];
			(.id|type=="string" and length>0) and (.identifier|type=="string" and length>0) and
			(.title|type=="string") and (.status|type=="string") and
			((.metadata // {})|type=="object") and ((.labels // [])|type=="array"))
		' >/dev/null <<<"$page" || { setup_issue_error 'タスク一覧の応答が不正です。'; return 1; }
		count=$(jq '.issues|length' <<<"$page")
		[[ $count != 0 ]] || break
		issues=$(jq -ce --argjson page "$page" '.+$page.issues | if (map(.id)|unique|length)==length then . else error("重複したページ") end' <<<"$issues") || { setup_issue_error 'タスク一覧のページが重複しています。'; return 1; }
		offset=$((offset+count))
	done
	printf '%s\n' "$issues"
}

# 取り下げ・完了を開き直さない。backlog は途中停止した起票の残りを仕上げる。
setup_issue_finish() {
	local issue=$1 label_id=$2 final_status=$3 repository=$4 id status
	id=$(jq -r '.id' <<<"$issue")
	status=$(jq -r '.status_category // .status' <<<"$issue")
	if [[ -n $repository && $(jq -r '.metadata.repository // empty' <<<"$issue") != "$repository" ]]; then
		mc issue metadata set "$id" --key repository --value "$repository" --type string >/dev/null || return 1
	fi
	if ! jq -e --arg id "$label_id" 'any(.labels[]?; .id==$id)' >/dev/null <<<"$issue"; then
		mc issue label add "$id" "$label_id" >/dev/null || return 1
	fi
	case $status in done|cancelled) return 0 ;; esac
	if [[ $(jq -r '.status' <<<"$issue") == backlog && $final_status != backlog ]]; then
		mc issue status "$id" "$final_status" >/dev/null || return 1
	fi
}

ensure_setup_issue() (
	umask 077
	local kind=$1 targets=$2 assignee=$3 repository=${4:-} definition title final_status label_id
	local issues covered missing issue id result rows='[]' work manual_url stored_targets additional
	[[ -n $assignee ]] || { setup_issue_error 'タスクの担当 ID がありません。'; return 1; }
	targets=$(jq -ce 'select(type=="array" and length>0 and all(.[]; type=="string" and length>0)) | unique' <<<"$targets") || { setup_issue_error 'タスクの対象が不正です。'; return 1; }
	definition=$(jq -ce --arg kind "$kind" '.[$kind] | select(type=="object")' "$root/common/setup-issues.json") || { setup_issue_error 'タスクの種類が定義にありません。'; return 1; }
	if [[ -z $repository ]] && jq -e '.title|contains("{{repository}}")' >/dev/null <<<"$definition"; then
		setup_issue_error 'タスクのリポジトリがありません。'; return 1
	fi
	case $(jq -r '.assignee' <<<"$definition") in squad) final_status=backlog ;; actor|skill-creator) final_status=todo ;; *) setup_issue_error 'タスクの担当の定義が不正です。'; return 1 ;; esac
	manual_url="https://github.com/AnD00/multica-squad-kit/blob/${kit_version:-$(cat "$root/VERSION")}/manual.md"
	title=$(jq -r --arg repository "$repository" '.title | split("{{repository}}") | join($repository)' <<<"$definition") || return 1
	issues=$(setup_issue_list "$kind") || return 1
	# targets は metadata の文字列。壊れた印を「未起票」として扱わない。
	issues=$(jq -ce --arg kind "$kind" 'map(select(.metadata.squad_kit_task==$kind) |
		.metadata.squad_kit_targets as $raw |
		(if ($raw|type)=="string" then ($raw|fromjson) else error("対象の印が不正") end) as $targets |
		if ($targets|type=="array" and length>0 and all(.[]; type=="string" and length>0))
		then .+{kit_targets:$targets} else error("対象の印が不正") end)
	' <<<"$issues") || { setup_issue_error '起票済みのタスクの対象の印が不正です。'; return 1; }
	covered=$(jq -c '[.[].kit_targets[]]|unique' <<<"$issues")
	missing=$(jq -c --argjson covered "$covered" '.-$covered' <<<"$targets")
	# ラベルを解決してから、作成・採用や途中停止した起票の仕上げへ進む。
	result=$(mc label list --resource-type issue --output json) || { setup_issue_error 'タスクのラベルを読めませんでした。'; return 1; }
	label_id=$(jq -er --arg name "$(jq -r '.label' <<<"$definition")" '[.[] | select(.name==$name)] | select(length==1) | .[0].id | select(type=="string" and length>0)' <<<"$result") || { setup_issue_error 'タスクのラベルを一つに決められません。'; return 1; }
	while IFS= read -r issue; do
		setup_issue_finish "$issue" "$label_id" "$final_status" "$repository" || { setup_issue_error '既存のタスクの起票を仕上げられませんでした。'; return 1; }
		rows=$(jq -c --argjson issue "$issue" --argjson targets "$targets" '.+[$issue | {id,identifier,title,action:"existing",targets:(.kit_targets- (.kit_targets-$targets))}]' <<<"$rows") || return 1
	done < <(jq -c --argjson targets "$targets" '.[] | select((.kit_targets- (.kit_targets-$targets))|length>0)' <<<"$issues")
	if [[ $(jq length <<<"$missing") == 0 ]]; then printf '%s\n' "$rows"; return 0; fi
	issues=$(setup_issue_list '') || return 1
	result=$(jq -c --arg title "$title" '[.[] | select(.title==$title and .metadata.squad_kit_task==null)]' <<<"$issues")
	[[ $(jq length <<<"$result") -le 1 ]] || { setup_issue_error '印のない同じタイトルのタスクが複数あります。'; return 1; }
	issue=$(jq -c '.[0] // empty' <<<"$result")
	local action=existing
	mkdir -p "$root/tmp" || return 1
	work=$(mktemp -d "$root/tmp/setup-issue.XXXXXX") || return 1
	trap 'rm -rf -- "$work"' EXIT
	if [[ -z $issue ]]; then
		setup_issue_description "$definition" "$repository" "$manual_url" "$missing" >"$work/description" || return 1
		# タイトルでの CLI の重複検出は使わず、上で読んだ対象の印で判定する。
		issue=$(mc issue create --title "$title" --description-file "$work/description" --project "$project_id" --assignee-id "$assignee" --status backlog --allow-duplicate --output json) || { setup_issue_error 'タスクを作れませんでした。'; return 1; }
		action=created
	fi
	id=$(jq -er 'select((.identifier|type=="string" and length>0) and (.status|type=="string")) | .id | select(type=="string" and length>0)' <<<"$issue") || { setup_issue_error 'タスク作成・採用の応答が不正です。'; return 1; }
	# task の印を最後に書き、印を途中まで書いたタスクも次回タイトルで採用する。
	stored_targets=$(jq -ce --argjson missing "$missing" '
		(.metadata.squad_kit_targets // "[]" | fromjson) as $stored |
		if ($stored|type=="array" and all(.[]; type=="string" and length>0)) then ($stored+$missing|unique) else error("対象の印が不正") end
	' <<<"$issue") || { setup_issue_error '採用するタスクの対象の印が不正です。'; return 1; }
	additional=$(jq -c --argjson missing "$missing" '$missing-(.metadata.squad_kit_targets // "[]" | fromjson)' <<<"$issue") || return 1
	if [[ $action == existing && $(jq length <<<"$additional") != 0 ]] && jq -e '.body|contains("{{targets}}")' >/dev/null <<<"$definition"; then
		# 本文を先に仕上げてから対象の印を書く。更新後に止まった再実行では追記を重ねない。
		result=$(mc issue get "$id" --output json) || { setup_issue_error '採用するタスクの本文を読めませんでした。'; return 1; }
		jq -e --arg id "$id" '.id==$id and (.description==null or (.description|type=="string"))' >/dev/null <<<"$result" || { setup_issue_error '採用するタスクの本文の応答が不正です。'; return 1; }
		setup_issue_description "$definition" "$repository" "$manual_url" "$additional" >"$work/addition" || return 1
		if ! jq -e --rawfile addition "$work/addition" '(.description // "") | contains($addition|rtrimstr("\n"))' >/dev/null <<<"$result"; then
			jq -r --rawfile addition "$work/addition" '(.description // "") + "\n\n" + ($addition|rtrimstr("\n"))' <<<"$result" >"$work/description" || return 1
			mc issue update "$id" --description-file "$work/description" >/dev/null || { setup_issue_error '採用するタスクに対象の作業を追記できませんでした。'; return 1; }
		fi
	fi
	mc issue metadata set "$id" --key squad_kit_targets --value "$stored_targets" --type string >/dev/null || { setup_issue_error 'タスクの対象の印を書けませんでした。'; return 1; }
	if [[ -n $repository ]]; then
		mc issue metadata set "$id" --key repository --value "$repository" --type string >/dev/null || { setup_issue_error 'タスクのリポジトリの印を書けませんでした。'; return 1; }
	fi
	mc issue metadata set "$id" --key squad_kit_task --value "$kind" --type string >/dev/null || { setup_issue_error 'タスクの種類の印を書けませんでした。'; return 1; }
	# 採用した完了・取り下げ済みのタスクも開き直さない。
	issue=$(jq -c --arg repository "$repository" '.metadata.repository=$repository' <<<"$issue") || return 1
	setup_issue_finish "$issue" "$label_id" "$final_status" "$repository" || { setup_issue_error 'タスクのラベル・状態を書けませんでした。'; return 1; }
	jq -c --argjson issue "$issue" --arg action "$action" --argjson targets "$stored_targets" '.+[$issue | {id,identifier,title,action:$action,targets:$targets}]' <<<"$rows"
)
