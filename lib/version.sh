# 導入済みのバージョンの記録と、最新のバージョンの知らせ。setup.sh から読み込む。bash 3.2 で動かす。
# 記録はホストに 1 つだけ置き、セットアップが最後まで終わったときだけ書く。
version_record_file() { printf '%s/template/version' "${TEMPLATE_AGENT_HOME:-$HOME/.multica-agent}"; }
# 拡張を読むと root が付け替わるので、今流している原本のバージョンは、読み込んだ時点で控える。
# 道具の確かめの前に読むので、外部のコマンドは使わない。
IFS= read -r version_running_value <"$root/VERSION" || true
version_running_value=${version_running_value//[[:space:]]/}
version_running() { printf '%s' "$version_running_value"; }
version_valid() { [[ $1 =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; }
# 数として比べるため、先頭の 0 を落として桁数、同じ桁数なら文字列で比べる。
version_part_greater() {
	local x=$1 y=$2
	x=${x#"${x%%[!0]*}"}
	y=${y#"${y%%[!0]*}"}
	if [[ ${#x} != "${#y}" ]]; then [[ ${#x} -gt ${#y} ]]; else [[ $x > $y ]]; fi
}
# $1 が $2 より新しいときだけ成功する。X・Y・Z を順に比べる。
version_newer() {
	local a b i
	IFS=. read -r -a a <<<"${1#v}"
	IFS=. read -r -a b <<<"${2#v}"
	for i in 0 1 2; do
		if version_part_greater "${a[i]}" "${b[i]}"; then return 0; fi
		if version_part_greater "${b[i]}" "${a[i]}"; then return 1; fi
	done
	return 1
}
# 記録がない、または読めないときは、今流している原本のバージョンを導入済みとみなす。
version_installed() {
	local record value
	record=$(version_record_file)
	if [[ -f $record ]]; then
		IFS= read -r value <"$record" 2>/dev/null || value=${value:-}
		value=${value//[[:space:]]/}
		if version_valid "$value"; then printf '%s' "$value"; return 0; fi
	fi
	version_running
}
# 最新のバージョンを読み、導入済みより新しければ知らせる。読めなくても、セットアップは止めない。
check_update() {
	local running installed latest
	running=$(version_running)
	installed=$(version_installed)
	latest=$(gh api repos/AnD00/multica-squad-kit/releases/latest --jq .tag_name 2>/dev/null) || latest=''
	if ! version_valid "$latest" || ! version_valid "$running"; then
		ui_warning '最新のバージョンを確かめられませんでした。導入は続けます。'
		return 0
	fi
	version_newer "$latest" "$installed" || return 0
	if version_newer "$latest" "$running"; then
		ui_warning "新しいバージョン $latest があります。今流しているのは $running です。README の更新の手順で、最新のバージョンを取り直して流してください。"
	elif [[ $latest == "$running" ]]; then
		printf '導入済みのバージョンは %s です。この実行で最新のバージョン %s に更新します。\n' "$installed" "$latest"
	fi
}
# 最後まで終わったあとに呼ぶ。書けなくても、終わったセットアップは失敗にしない。
record_installed_version() {
	local file tmp
	file=$(version_record_file)
	tmp=$file.tmp.$$
	if ! { (umask 077; mkdir -p "$(dirname "$file")") && printf '%s\n' "$(version_running)" >"$tmp" && mv -f "$tmp" "$file"; }; then
		rm -f -- "$tmp" 2>/dev/null || true
		ui_warning "導入済みのバージョンを記録できませんでした: ${file}。セットアップ自体は終わっています。"
	fi
}
