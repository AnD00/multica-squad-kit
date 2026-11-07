# ワークスペース共通のラベルとスキル。プロジェクトや割り当ては扱わない。
prepare_workspace() (
	local workspace_work
	mkdir -p "$root/tmp" || die '作業用の置き場を作れませんでした。'
	workspace_work=$(mktemp -d "$root/tmp/workspace.XXXXXX") || die '作業用の置き場を作れませんでした。'
	trap 'rm -rf -- "$workspace_work"' EXIT
	sync_workspace_labels
	sync_common_skills
)

sync_workspace_labels() {
	local labels name color description matches id result
	awk -F'|' '
		/^[[:space:]]*($|#)/ {next}
		NF!=3 || $1=="" || $3=="" || length($2)!=7 || $2!~/^#[0-9a-fA-F]+$/ || seen[$1]++ {bad=1}
		END {exit bad}
	' "$root/common/labels" || die 'ラベルの定義が不正です。'
	labels=$(mc label list --resource-type issue --output json) || die 'ラベルを取得できませんでした。'
	jq -e 'type=="array" and all(.[]; (.id|type=="string" and length>0) and (.name|type=="string" and length>0))' >/dev/null <<<"$labels" || die 'ラベルの応答が不正です。'
	while IFS='|' read -r name color description; do
		[[ -n $name && $name != \#* ]] || continue
		matches=$(jq -c --arg name "$name" '[.[] | select(.name==$name)]' <<<"$labels")
		[[ $(jq length <<<"$matches") -le 1 ]] || die "同名のラベルが複数あります: $name"
		id=$(jq -r '.[0].id // empty' <<<"$matches")
		if [[ -z $id ]]; then
			result=$(mc label create --resource-type issue --name "$name" --color "$color" --description "$description" --output json) || die "ラベルを作れませんでした: $name"
			jq -e '(.id|type=="string" and length>0)' >/dev/null <<<"$result" || die 'ラベル作成の応答が不正です。'
		elif ! jq -e --arg color "$color" --arg description "$description" '.[0].color==$color and (.[0].description // "")==$description' >/dev/null <<<"$matches"; then
			mc label update "$id" --color "$color" --description "$description" --output json >/dev/null || die "ラベルを更新できませんでした: $name"
		fi
	done < <(awk '!/^[[:space:]]*($|#)/' "$root/common/labels")
}

# 同梱する共通スキルの front matter は一行の name / description を使う。
workspace_skill_field() {
	awk -v key="$2" '
		NR==1 && $0=="---" {inside=1; next}
		inside && $0=="---" {exit}
		inside && index($0,key ": ")==1 {sub(/^[^:]+: */, ""); print; exit}
	' "$1"
}

read_workspace_skill() {
	remote_skill=$(mc skill get "$1" --with-content --output json) || die "共通スキルを読めませんでした: $skill_name"
	jq -e --arg id "$1" --arg name "$skill_name" '
		.id==$id and .name==$name and (.content|type=="string") and
		(.files|type=="array" and all(.[]; (.id|type=="string" and length>0) and (.path|type=="string" and length>0) and (.content|type=="string")))
	' >/dev/null <<<"$remote_skill" || die "共通スキルの応答が不正です: $skill_name"
}

workspace_skill_same() {
	jq -e --rawfile content "$skill_dir/SKILL.md" --arg description "$skill_description" --argjson files "$skill_files" '
		(.content|sub("\n+$";""))==($content|sub("\n+$";"")) and (.description // "")==$description and
		(.files|map({path,content})|sort_by(.path))==($files|sort_by(.path))
	' >/dev/null <<<"$remote_skill"
}

workspace_actor() {
	local profile
	[[ -z ${workspace_actor_id:-} ]] || return 0
	profile=$(mc user profile get --output json) || die '実行する人を取得できませんでした。'
	workspace_actor_id=$(jq -er '.id | select(type=="string" and length>0)' <<<"$profile") || die '実行する人の ID が不正です。'
	workspace_people=$(mc workspace member list --output json) || die 'ワークスペースのメンバーを取得できませんでした。'
	jq -e 'type=="array" and all(.[]; (.user_id|type=="string") and (.role|type=="string") and (.name|type=="string"))' >/dev/null <<<"$workspace_people" || die 'ワークスペースのメンバーの応答が不正です。'
}

# 本文と補助ファイルを読み、取り込みの欠落も検出する。
workspace_local_files() {
	skill_description=$(workspace_skill_field "$skill_dir/SKILL.md" description)
	skill_files='[]'
	local file path
	while IFS= read -r -d '' file; do
		[[ $file != "$skill_dir/SKILL.md" ]] || continue
		path=${file#"$skill_dir"/}
		skill_files=$(jq -c --arg path "$path" --rawfile content "$file" '.+[{path:$path,content:$content}]' <<<"$skill_files") || die 'スキルの補助ファイルを読めません。'
	done < <(find "$skill_dir" -type f -print0)
}

workspace_can_update() {
	workspace_actor
	local creator creator_name
	creator=$(jq -r '.created_by // empty' <<<"$remote_skill")
	if [[ $creator == "$workspace_actor_id" ]] || jq -e --arg id "$workspace_actor_id" 'any(.[]; .user_id==$id and (.role=="owner" or .role=="admin"))' >/dev/null <<<"$workspace_people"; then return 0; fi
	creator_name=$(jq -r --arg id "$creator" '[.[] | select(.user_id==$id) | .name][0] // "最初に取り込んだ人"' <<<"$workspace_people")
	ui_warning "更新を飛ばしました: ${skill_name}。更新できる人: ワークスペースのオーナー・管理者、${creator_name}。"
	return 1
}

sync_common_skills() {
	local skills skill_dir skill_name skill_description matches id skill_files remote_skill result url config
	local workspace_actor_id='' workspace_people='[]'
	skills=$(mc skill list --output json) || die '共通スキルの一覧を取得できませんでした。'
	jq -e 'type=="array" and all(.[]; (.id|type=="string" and length>0) and (.name|type=="string" and length>0))' >/dev/null <<<"$skills" || die '共通スキル一覧の応答が不正です。'
	for skill_dir in "$root/common/skills/"*/; do
		[[ -d $skill_dir ]] || continue
		skill_dir=${skill_dir%/}; skill_name=$(basename "$skill_dir")
		[[ $skill_name =~ ^squad-[a-z0-9]+(-[a-z0-9]+)*$ && $(workspace_skill_field "$skill_dir/SKILL.md" name) == "$skill_name" ]] || die '共通スキルの名前が不正です。'
		workspace_local_files
		url="https://github.com/AnD00/multica-squad-kit/tree/${kit_version:-$(cat "$root/VERSION")}/common/skills/$skill_name"
		matches=$(jq -c --arg name "$skill_name" '[.[] | select(.name==$name)]' <<<"$skills")
		[[ $(jq length <<<"$matches") -le 1 ]] || die '同名の共通スキルが複数あります。'
		id=$(jq -r '.[0].id // empty' <<<"$matches")
		if [[ -z $id ]]; then
			result=$(mc skill import --url "$url" --on-conflict fail --output json) || die "共通スキルを取り込めませんでした: $skill_name"
			id=$(jq -er --arg name "$skill_name" 'select(.status=="created" and .skill.name==$name) | .skill.id | select(type=="string" and length>0)' <<<"$result") || die '取り込みの応答が不正です。'
		else
			read_workspace_skill "$id"
			if workspace_skill_same && jq -e --arg url "$url" '.config.origin.type=="github" and .config.origin.source_url==$url' >/dev/null <<<"$remote_skill"; then continue; fi
			workspace_can_update || continue
			config=$(jq -c --arg url "$url" '(.config // {}) | .origin={type:"github",source_url:$url}' <<<"$remote_skill")
			mc skill update "$id" --config "$config" --output json >/dev/null || die 'スキルの取り込み元を更新できませんでした。'
			mc skill refresh "$id" --output json >/dev/null || die '共通スキルの再取得に失敗しました。時間を空けて流し直してください。'
		fi
		read_workspace_skill "$id"
		workspace_skill_same || die '取得したスキルが原本と一致しません。取得の上限や対象タグを確認してから流し直してください。'
	done
}

# 拡張のスキルは手元のファイルで更新する。取り込み直さず ID を保つ。
sync_local_project_skill() {
	local skill_dir=$1 skill_name=$2 id=$3 skill_description skill_files remote_skill file path file_id
	local workspace_actor_id='' workspace_people='[]'
	workspace_local_files
	read_workspace_skill "$id"
	workspace_skill_same && return 0
	workspace_can_update || return 0
	mc skill update "$id" --description "$skill_description" --content-file "$skill_dir/SKILL.md" --output json >/dev/null || die 'プロジェクトのスキルを更新できません。'
	while IFS= read -r -d '' file; do
		[[ $file != "$skill_dir/SKILL.md" ]] || continue
		path=${file#"$skill_dir"/}
		mc skill files upsert "$id" --path "$path" --content-file "$file" --output json >/dev/null || die 'プロジェクトの補助ファイルを更新できません。'
	done < <(find "$skill_dir" -type f -print0)
	while IFS= read -r file_id; do
		mc skill files delete "$id" "$file_id" || die 'プロジェクトの古い補助ファイルを削除できません。'
	done < <(jq -r --argjson files "$skill_files" '.files[] | select(.path as $path | $files | all(.[]; .path!=$path)) | .id' <<<"$remote_skill")
	read_workspace_skill "$id"
	workspace_skill_same || die '更新したプロジェクトのスキルが手元と一致しません。'
}
