# テストでは保存先だけを一時ディレクトリへ向ける。質問の省略には使わない。
state_root=${TEMPLATE_STATE_ROOT:-$HOME/.multica-agent/template/answers}

# 表記が異なっても、同じ GitHub リポジトリとして比較する。
repository_filter='
def repository_name:
	if type!="string" then error("リポジトリの URL が文字列ではありません") else ascii_downcase end |
	if startswith("https://github.com/") then ltrimstr("https://github.com/")
	elif startswith("git@github.com:") then ltrimstr("git@github.com:")
	elif startswith("ssh://git@github.com/") then ltrimstr("ssh://git@github.com/")
	else error("GitHub の URL ではありません") end |
	rtrimstr("/") | sub("\\.git$"; "") |
	if test("^[a-z0-9][a-z0-9_.-]*/[a-z0-9_.-]+$") and (split("/")[1]!="." and split("/")[1]!="..")
	then . else error("OWNER/REPO の形ではありません") end;
'

# 紐付け先はコード作業先と分け、ワークスペースの登録だけを確かめる。
resolve_link_repositories() {
	local requested='[]' registered
	if [[ -f $root/extension-link-repositories.json ]]; then
		requested=$(jq -ce '
			if type=="array" and all(.[]; type=="string" and
				test("^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9_.-]+$") and
				(split("/")[1]!="." and split("/")[1]!=".."))
			then map(ascii_downcase)|unique else error("紐付け先が不正です") end
		' "$root/extension-link-repositories.json") || die '紐付け専用のリポジトリの指定が不正です。'
	fi
	if [[ $(jq length <<<"$requested") != 0 ]]; then
		registered=$(read_list リポジトリ repo list) || die '紐付け先の確認に必要なリポジトリを取得できませんでした。'
		registered=$(jq -ce "$repository_filter"'[.[]|.url|repository_name]|unique' <<<"$registered") || die '登録済みのリポジトリの URL が不正です。'
		jq -e --argjson registered "$registered" 'all(.[]; . as $repo | $registered|index($repo)!=null)' >/dev/null <<<"$requested" || die '紐付け専用のリポジトリは、選んだワークスペースに登録済みのものだけ指定できます。'
	fi
	# コード作業先は従来の選択のまま。追加分だけを別の範囲として指示に渡す。
	link_repositories=$(jq -nc --argjson requested "$requested" --argjson repos "$repositories" '$requested-($repos|map(.repository|ascii_downcase))')
	allowed_repository_names=$(jq -nc --argjson repos "$repositories" --argjson links "$link_repositories" '($repos|map(.repository|ascii_downcase))+$links|reduce .[] as $repo ([]; if index($repo)==null then .+[$repo] else . end)')
}

# 質問時と登録直前で同じ除外を使う。自分自身は実際の ID で除く。
repository_choices() {
	local registered=$1 projects_list=$2 self_id=$3 owners='{}' project other_id title resources names
	while IFS= read -r project; do
		other_id=$(jq -r '.id' <<<"$project")
		[[ $other_id != "$self_id" ]] || continue
		title=$(jq -r '.title' <<<"$project")
		resources=$(mc project resource list "$other_id" --output json) || die "プロジェクトのリポジトリを取得できませんでした: $title"
		jq -e 'type=="array" and all(.[]; (.resource_type|type=="string") and (if .resource_type=="github_repo" then (.resource_ref.url|type=="string" and length>0) else true end))' >/dev/null <<<"$resources" || die "プロジェクトのリソースの応答が不正です: $title"
		names=$(jq -c "$repository_filter"'[.[] | select(.resource_type=="github_repo") | .resource_ref.url | repository_name]' <<<"$resources") || die "プロジェクトのリポジトリの URL が不正です: $title"
		owners=$(jq -c --arg title "$title" --argjson names "$names" 'reduce $names[] as $name (.; .[$name]=((.[$name] // [])+[$title]|unique))' <<<"$owners")
	done < <(jq -c '.[]' <<<"$projects_list")
	registered=$(jq -c "$repository_filter"'[.[] | {url:.url,repository:(.url|repository_name)}] |
		reduce .[] as $entry ([]; if any(.[]; .repository==$entry.repository) then . else .+[$entry] end)' <<<"$registered") || die '選択候補のリポジトリの URL が不正です。'
	eligible_repos=$(jq -c --argjson owners "$owners" '[.[] | select($owners[.repository]==null)]' <<<"$registered")
	blocked_repos=$(jq -c --argjson owners "$owners" '[.[] | select($owners[.repository]!=null) | .+{projects:$owners[.repository]}]' <<<"$registered")
}

# 回答はリポジトリの一覧を持つ一つの形式で保存する。
load_answers() {
	jq -e "$repository_filter"'
		if type=="object" and (has("runtimes")|not) then .runtimes=["claude","codex"] else . end |
		if type=="object" and (has("dependabot_webhook")|not) then .dependabot_webhook=false else . end |
		if type=="object" and .schema==1 and
			all(.server_url,.workspace_id,.workspace_name,.project_name,.project_key,.member_key; type=="string" and length>0) and
			(.project_id|type=="string") and
			(.project_key|test("^[a-z][a-z0-9]{1,11}$")) and
			(.member_key|test("^[a-z][a-z0-9]{1,11}$")) and
			(.member_ids|type=="array" and all(.[]; type=="string" and length>0)) and
			(.runtimes|type=="array" and length>0 and length==(unique|length) and all(.[]; .=="claude" or .=="codex")) and
			(.dependabot_webhook|type=="boolean") and
			(.excluded_roles|type=="array" and all(.[]; . as $r | ["planner","designer","claude-implementer","claude-fixer","codex-implementer","codex-fixer","code-reviewer","security-reviewer","ux-reviewer","performance-reviewer","qa","ci-monitor","usage-monitor","dependabot-merger"] | index($r)!=null)) and
			((.excluded_roles|index("claude-implementer")!=null)==(.excluded_roles|index("claude-fixer")!=null)) and
			((.excluded_roles|index("codex-implementer")!=null)==(.excluded_roles|index("codex-fixer")!=null)) and
			([.excluded_roles[] | select(.=="claude-implementer" or .=="codex-implementer")]|length<2)
		then . else error("保存済みの答えの形が不正です") end |
		. as $answers |
		.repositories |
		if type=="array" and length>0 then . else error("リポジトリの一覧がありません") end |
		map(. as $entry | (.url|repository_name) as $name |
			if (.repository|type=="string") and (.repository|ascii_downcase)==$name
			then {url:$entry.url,repository:$name} else error("URL とリポジトリの名前が違います") end) |
		reduce .[] as $entry ([]; if any(.[]; .repository==$entry.repository) then . else .+[$entry] end) |
		. as $repos | $answers+{repositories:$repos}
	' "$1"
}

# 保存した中で最後に確認した答えを既定にする。質問中の試行は記録しない。
latest_answers() {
	local server=${1:-} workspace=${2:-} project=${3:-} candidate latest='' raw
	for candidate in "$state_root/"*/*.json; do
		[[ -f $candidate && ! -L $candidate ]] || continue
		valid_answers "$candidate" || continue
		raw=$(load_answers "$candidate")
		jq -e --arg server "$server" --arg workspace "$workspace" --arg project "$project" '
			($server=="" or .server_url==$server) and ($workspace=="" or .workspace_id==$workspace) and ($project=="" or .project_name==$project)
		' >/dev/null <<<"$raw" || continue
		if [[ -z $latest || $candidate -nt $latest ]]; then latest=$candidate; fi
	done
	if [[ -n $latest ]]; then load_answers "$latest"; else printf '{}\n'; fi
}

valid_answers() {
	load_answers "$1" >/dev/null 2>&1
}

save_answers() {
	local directory temporary
	directory=${answers_file%/*}
	(umask 077; mkdir -p "$directory") || die '答えの保存先を作れませんでした。'
	temporary=$(mktemp "$directory/.answers.XXXXXX") || die '答えの一時ファイルを作れませんでした。'
	if ! (umask 077; printf '%s\n' "$answers" >"$temporary") || ! mv -f "$temporary" "$answers_file"; then
		rm -f -- "$temporary"
		die '答えを保存できませんでした。前の答えを確認してください。'
	fi
	printf '%s\n' '答えを保存しました。' >&2
}
