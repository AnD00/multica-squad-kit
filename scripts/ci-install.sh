#!/usr/bin/env bash
# CI の scripts ジョブで、ランナーに無いツールだけを取得する。使い方: ci-install.sh Linux|macOS
#
# 流れ: 足りないものを調べ、なければ何もしない。足りなければ、先に CI のキャッシュ
# （CI_INSTALL_CACHE_DIR）から入れ、使えないときだけミラーへ行き、再試行する。
# 最後に、必要なものが揃ったかを必ず確かめ、揃わなければ失敗で終わる。
# 取り方は GITHUB_OUTPUT の source に書く。none（取得なし）、cache（キャッシュから）、
# mirror（ミラーから。ワークフローが保存する）、mirror-uncached（ミラーから。保存するものがない）。
#
# 壊れたキャッシュで誤って通らないための決め:
# - Linux は、取得した .deb と SHA256SUMS、足りなかった一覧（PACKAGES）を保存する。復元後は、
#   一覧が今の足りないものと同じか、ファイルが記録と過不足なく一致しハッシュが合うかを
#   確かめてから dpkg -i する。1 つでも違えば捨ててミラーから取る。
# - macOS は、brew がバイナリの SHA-256 を公式の値と照らすので、その確認に任せる。
#   失敗したらキャッシュを捨てて、ミラーから取り直す。
# - どちらも入れたあとに、パッケージの状態とコマンドの動作を確かめる。
set -euo pipefail

linux_packages=(bash zsh git jq gh zip unzip python3 tzdata libdigest-sha-perl procps)
apt_attempts=4
apt_step=15
brew_attempts=3
brew_step=10

log() { printf 'ci-install: %s\n' "$*"; }
fail() { printf 'ci-install: %s\n' "$*" >&2; exit 1; }
emit_source() {
	log "source=$1"
	if [[ -n ${GITHUB_OUTPUT:-} ]]; then printf 'source=%s\n' "$1" >>"$GITHUB_OUTPUT"; fi
}
sha256() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}

# retry <回数> <間隔の単位（秒）> <コマンド...>: 失敗したら、間隔を伸ばして再試行する。
retry() {
	local attempts=$1 step=$2 i=1
	shift 2
	while :; do
		if "$@"; then return 0; fi
		if [[ $i -ge $attempts ]]; then return 1; fi
		log "失敗しました（$i/$attempts 回目）。$((i * step)) 秒後に再試行します"
		sleep $((i * step))
		i=$((i + 1))
	done
}

# ---- Linux（apt） ----

linux_missing() {
	local p
	for p in "${linux_packages[@]}"; do
		[[ $(dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null || true) == installed ]] || printf '%s\n' "$p"
	done
}

linux_cache_valid() {
	local wanted=$1 listed present
	[[ -f $cache_dir/SHA256SUMS && -f $cache_dir/PACKAGES ]] || return 1
	[[ $(cat "$cache_dir/PACKAGES") == "$wanted" ]] || return 1
	listed=$(awk '{print $2}' "$cache_dir/SHA256SUMS" | LC_ALL=C sort)
	present=$(cd "$cache_dir" && ls -1 ./*.deb 2>/dev/null | sed 's|^\./||' | LC_ALL=C sort) || present=
	[[ -n $listed && $listed == "$present" ]] || return 1
	(cd "$cache_dir" && sha256 -c SHA256SUMS >/dev/null 2>&1)
}

linux_apt_from_mirror() {
	sudo apt-get -o Acquire::Retries=3 update &&
		sudo apt-get -o Acquire::Retries=3 -o "Dir::Cache::archives=$cache_dir" -o APT::Sandbox::User=root install -y "$@"
}

linux_clear_cache() {
	sudo rm -rf -- "$cache_dir"
	mkdir -p "$cache_dir"
}

linux() {
	local missing=() p wanted
	while IFS= read -r p; do missing+=("$p"); done < <(linux_missing)
	if [[ ${#missing[@]} -eq 0 ]]; then
		log '必要なパッケージはランナーに入っています'
		emit_source none
		return 0
	fi
	wanted="${missing[*]}"
	log "足りないパッケージ: $wanted"
	mkdir -p "$cache_dir"

	if linux_cache_valid "$wanted"; then
		log 'キャッシュの .deb を検証し、入れます'
		if sudo dpkg -i "$cache_dir"/*.deb && [[ -z $(linux_missing) ]]; then
			emit_source cache
			return 0
		fi
		log 'キャッシュから入れられませんでした。キャッシュを捨ててミラーから取ります'
	elif [[ -n $(ls -A "$cache_dir") ]]; then
		log 'キャッシュが記録と合いません。キャッシュを捨ててミラーから取ります'
	else
		log 'キャッシュがありません。ミラーから取ります'
	fi

	linux_clear_cache
	retry "$apt_attempts" "$apt_step" linux_apt_from_mirror "${missing[@]}" || fail "apt-get が $apt_attempts 回失敗しました"
	[[ -z $(linux_missing) ]] || fail "取得のあとも足りないパッケージがあります: $(linux_missing | tr '\n' ' ')"

	sudo rm -rf -- "$cache_dir/partial" "$cache_dir/lock"
	sudo chown -R "$(id -u):$(id -g)" "$cache_dir"
	if ls "$cache_dir"/*.deb >/dev/null 2>&1; then
		(cd "$cache_dir" && sha256 ./*.deb | sed 's|  \./|  |' >SHA256SUMS)
		printf '%s' "$wanted" >"$cache_dir/PACKAGES"
		emit_source mirror
	else
		emit_source mirror-uncached
	fi
}

# ---- macOS（brew） ----

macos_missing() {
	jq --version >/dev/null 2>&1 || printf 'jq\n'
	if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' >/dev/null 2>&1; then
		printf 'python\n'
	fi
}

macos_brew_install() {
	if brew install "$@"; then return 0; fi
	rm -rf "$HOMEBREW_CACHE"
	mkdir -p "$HOMEBREW_CACHE"
	cache_used=0
	return 1
}

macos() {
	local missing=() p cache_used=0
	while IFS= read -r p; do missing+=("$p"); done < <(macos_missing)
	if [[ ${#missing[@]} -eq 0 ]]; then
		log '必要なツールはランナーに入っています'
		emit_source none
		return 0
	fi
	log "足りないツール: ${missing[*]}"
	export HOMEBREW_CACHE="$cache_dir/downloads" HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1
	mkdir -p "$HOMEBREW_CACHE"
	if [[ -n $(ls -A "$HOMEBREW_CACHE") ]]; then
		cache_used=1
		log 'キャッシュのダウンロードを使います。brew が SHA-256 を検証します'
	else
		log 'キャッシュがありません。ミラーから取ります'
	fi

	retry "$brew_attempts" "$brew_step" macos_brew_install "${missing[@]}" || fail "brew install が $brew_attempts 回失敗しました"
	[[ -z $(macos_missing) ]] || fail "取得のあとも足りないツールがあります: $(macos_missing | tr '\n' ' ')"

	if [[ $cache_used == 1 ]]; then
		emit_source cache
	else
		rm -rf "$HOMEBREW_CACHE/api"
		find "$HOMEBREW_CACHE" -name '*.incomplete' -delete
		if [[ -n $(ls -A "$HOMEBREW_CACHE") ]]; then emit_source mirror; else emit_source mirror-uncached; fi
	fi
}

cache_dir=${CI_INSTALL_CACHE_DIR:-}
[[ -n $cache_dir ]] || { echo 'CI_INSTALL_CACHE_DIR を指定してください' >&2; exit 2; }
case ${1:-} in
Linux) linux ;;
macOS) macos ;;
*) echo '使い方: bash scripts/ci-install.sh Linux|macOS' >&2; exit 2 ;;
esac
