# 拡張は設定の前に読み、原本のコピーへ足す。原本のファイルは書き換えない。
choose_extension() {
	kit_root=$root
	kit_version=$(cat "$kit_root/VERSION") || die 'VERSION を読めません。'
	[[ $kit_version =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'VERSION が不正です。'
	# 引数で受けたときは質問を出さず、答えたときと同じ確かめに進む。
	if [[ -n ${extension_option:-} ]]; then
		extension_dir=$extension_option
		printf '拡張のディレクトリ（引数で指定）: %s\n' "$extension_dir" >&2
	else
		printf '拡張のディレクトリ（使わない場合は Enter）: ' >&2
		IFS= read -r extension_dir || die '入力が終わりました。'
		[[ -n $extension_dir ]] || return 0
	fi
	[[ -d $extension_dir ]] || die '拡張のディレクトリがありません。'
	extension_dir=$(cd "$extension_dir" && pwd)
	mkdir -p "$kit_root/tmp"
	extension_work=$(mktemp -d "$kit_root/tmp/extension.XXXXXX") || die '拡張の作業場所を作れません。'
	[[ ${setup_cleanup_enabled:-no} == yes ]] || trap 'rm -rf -- "$extension_work"' EXIT
	python3 "$kit_root/lib/extensions.py" "$kit_root" "$extension_dir" "$extension_work" || die '拡張の確認に失敗しました。何も登録していません。'
	root=$extension_work
	extension_current_roles=$(cat "$root/extension-roles")
	template_roles+=" $extension_current_roles"
}

# 消えた拡張の名前だけを管理対象に残す。中身とバージョンの記録には使わない。
load_extension_inventory() {
	local previous role
	extension_inventory="$state_root/$workspace_id/$project_key-$member_key.extensions.json"
	extension_disabled_roles=''
	previous='{"roles":[],"autopilots":""}'
	if [[ -f $extension_inventory ]]; then
		previous=$(cat "$extension_inventory") || die '拡張の管理対象を読めません。'
		jq -e '(.roles|type=="array" and all(.[]; type=="string" and test("^[a-z]+(-[a-z]+)*$"))) and (.autopilots|type=="string")' >/dev/null <<<"$previous" || die '拡張の管理対象が不正です。'
	fi
	# 拡張を外すときも原本の一時コピーを作る。
	if [[ -z ${extension_work:-} && $(jq '.roles|length' <<<"$previous") != 0 || -z ${extension_work:-} && $(jq -r '.autopilots' <<<"$previous") != '' ]]; then
		mkdir -p "$kit_root/tmp"
		extension_work=$(mktemp -d "$kit_root/tmp/extension.XXXXXX") || die '拡張の作業場所を作れません。'
		[[ ${setup_cleanup_enabled:-no} == yes ]] || trap 'rm -rf -- "$extension_work"' EXIT
		cp -R "$kit_root/common" "$kit_root/skeleton" "$extension_work/"
		root=$extension_work
	fi
	for role in $(jq -r '.roles[]' <<<"$previous"); do
		if [[ " ${extension_current_roles:-} " != *" $role "* ]]; then
			template_roles+=" $role"
			extension_disabled_roles+=" $role"
		fi
	done
	if [[ -n ${extension_work:-} ]]; then
		cat "$root/common/autopilots.md" >"$root/common/autopilots.known.md"
		jq -r '.autopilots' <<<"$previous" >>"$root/common/autopilots.known.md"
		autopilots_known_source=$root/common/autopilots.known.md
	fi
}

save_extension_inventory() {
	[[ -n ${extension_inventory:-} ]] || return 0
	local definitions=''
	[[ -z ${extension_dir:-} || ! -f $extension_dir/autopilots.md ]] || definitions=$(cat "$extension_dir/autopilots.md")
	mkdir -p "${extension_inventory%/*}"
	jq -n --arg roles "${extension_current_roles:-}" --arg autopilots "$definitions" '{roles:($roles|split(" ")|map(select(length>0))),autopilots:$autopilots}' >"$extension_inventory.new"
	mv "$extension_inventory.new" "$extension_inventory"
}
