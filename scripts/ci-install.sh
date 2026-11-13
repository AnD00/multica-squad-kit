#!/usr/bin/env bash
# CI の scripts ジョブで、ランナーに無いツールだけを取得する。使い方: ci-install.sh Linux|macOS
#
# 流れ: 足りないものを調べ、なければ何もしない。足りなければ、先に CI のキャッシュ
# （CI_INSTALL_CACHE_DIR）から入れ、使えないときだけミラーへ行き、再試行する。
# 最後に、必要なものが揃ったかを必ず確認し、揃わなければ失敗で終わる。
# 取り方は GITHUB_OUTPUT の source に書く。none（取得なし）、cache（キャッシュから）、
# mirror（ミラーから。ワークフローが保存する）、mirror-uncached（ミラーから。保存するものがない）。
#
# 壊れた・差し替えられたキャッシュで誤って通らないための決め:
# - Linux は、取得した .deb と、足りなかった一覧（PACKAGES）、.deb を含む APT のパッケージ情報
#   （InRelease と Packages。apt-meta に保存）を保存する。キャッシュの中身は信用しない。復元後は、
#   ランナーにある Ubuntu アーカイブの公開鍵で InRelease の署名を gpgv で検証し、その InRelease が
#   記すハッシュと Packages のハッシュ、Packages が記す SHA-256 と .deb のハッシュを照合してから
#   apt-get install でローカルの .deb として入れる。.deb と一覧を一緒に書き換えても、署名は偽造できない。
#   署名が正しくても、次のどれかなら、キャッシュを捨ててミラーから取る（正しく署名された別リリース・古い情報の持ち込みを防ぐ）。
#   - 署名した情報の Codename・Suite が、ランナーのリリース（/etc/os-release の VERSION_CODENAME と、
#     その -updates・-security）でない
#   - Valid-Until がある場合に、過ぎている。Ubuntu の InRelease には Valid-Until がなく、署名は期限切れにならない。
#     そのため、期限のない一覧は受け入れるが、次の確認で古いバージョンを拒否する
#   - .deb のバージョンが、ランナー自身の APT（apt-cache policy）の候補より古い、または候補がない
#     （ランナーが信頼できるバージョンを持たないものは、署名が正しくても入れない）
#   署名・ハッシュのどれかが違う、情報が足りない、署名できる鍵が違う場合も同じ。
# - macOS は、brew がバイナリの SHA-256 を公式の値と照らすので、その確認に任せる。
#   失敗したり、入れたあとに動作の確認が通らなかったりしたら、キャッシュを捨てて、ミラーから取り直す。
# - どちらも入れたあとに、パッケージの状態とコマンドの動作を確認する。
set -euo pipefail

linux_packages=(bash zsh git jq gh zip unzip python3 tzdata libdigest-sha-perl procps gpgv)
apt_attempts=4
apt_step=15
brew_attempts=3
brew_step=10
# 署名の確認に使う公開鍵と、apt がパッケージ情報を置く場所（テストでは差し替える）。
apt_keyring=${CI_INSTALL_APT_KEYRING:-/usr/share/keyrings/ubuntu-archive-keyring.gpg}
apt_lists_dir=${CI_INSTALL_APT_LISTS_DIR:-/var/lib/apt/lists}
apt_helper=${CI_INSTALL_APT_HELPER:-/usr/lib/apt/apt-helper}
# 署名した情報を受け入れる、ランナーのリリース名（空なら /etc/os-release）。
apt_codename=${CI_INSTALL_APT_CODENAME:-}

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

# 標準入力か引数のファイルの SHA-256（16 進の値だけ）を出す。
sha256_of() { sha256 "$@" | awk '{print $1}'; }

# list_cat <ファイル>: apt が置いたパッケージ情報を、圧縮の種類に合わせて展開して出す。
# Ubuntu 24.04 の apt は lz4 で置くが、ランナーに lz4 のコマンドがあるとは限らないので、apt 自身の apt-helper で展開する。
list_cat() {
	case $1 in
	*.gz) gzip -dc "$1" ;;
	*.xz | *.lz4 | *.zst | *.bz2) "$apt_helper" cat-file "$1" ;;
	*) cat "$1" ;;
	esac
}

# to_epoch <日時>: RFC 2822 形式の日時（InRelease の Valid-Until）を UTC の秒にする（GNU と BSD の date）。
to_epoch() {
	date -u -d "$1" +%s 2>/dev/null || date -u -j -f '%a, %d %b %Y %H:%M:%S %Z' "$1" +%s 2>/dev/null
}

# linux_codename: ランナーのリリース名（noble など）。
linux_codename() {
	if [[ -n $apt_codename ]]; then printf '%s' "$apt_codename"; return; fi
	# shellcheck disable=SC1091
	( . /etc/os-release 2>/dev/null && printf '%s' "${VERSION_CODENAME:-}" )
}

# linux_release_ok <Release>: 署名された Release が、ランナーのリリースのもので、期限内かを確認する。
linux_release_ok() {
	local codename suite rel_codename until_s u
	codename=$(linux_codename)
	[[ -n $codename ]] || return 1
	suite=$(sed -n 's/^Suite: *//p' "$1" | head -n 1)
	rel_codename=$(sed -n 's/^Codename: *//p' "$1" | head -n 1)
	[[ $rel_codename == "$codename" ]] || return 1
	case $suite in "$codename" | "$codename-updates" | "$codename-security") ;; *) return 1 ;; esac
	until_s=$(sed -n 's/^Valid-Until: *//p' "$1" | head -n 1)
	if [[ -n $until_s ]]; then
		u=$(to_epoch "$until_s") || return 1
		[[ $u -gt $(date -u +%s) ]] || return 1
	fi
}

# linux_trusted_hashes <作業ディレクトリ>: キャッシュの InRelease の署名を公開鍵で検証し、
# 署名された Release が記すハッシュに合う Packages だけから、「SHA-256  ファイル名  パッケージ  バージョン」の一覧を作る。
linux_trusted_hashes() {
	local tmp=$1 meta=$cache_dir/apt-meta inrel prefix release f rel want have n=0
	: >"$tmp/trusted"
	for inrel in "$meta"/*_InRelease; do
		[[ -f $inrel ]] || continue
		prefix=${inrel##*/}
		prefix=${prefix%_InRelease}
		n=$((n + 1))
		release="$tmp/Release.$n"
		# 署名された本文は、ファイルでなく標準出力で受ける。gpgv 2.5 の --output <ファイル> は、書いた .part を
		# 最後まで確定せず、成功を返してもファイルが残らないことがある（macOS のランナーで確認）。
		if ! gpgv --homedir "$tmp" --keyring "$apt_keyring" --output - "$inrel" >"$release" 2>"$tmp/gpgv.log" || [[ ! -s $release ]]; then
			sed 's/^/ci-install: gpgv: /' "$tmp/gpgv.log" >&2
			return 1
		fi
		linux_release_ok "$release" || return 1
		for f in "$meta/$prefix"_*_Packages.gz; do
			[[ -f $f ]] || continue
			rel=${f##*/}
			rel=${rel#"${prefix}"_}
			rel=${rel%.gz}
			rel=${rel//_//}
			want=$(awk -v p="$rel" '/^SHA256:/{s=1;next} /^[^ ]/{s=0} s&&$3==p{print $1}' "$release")
			have=$(gzip -dc "$f" | sha256_of) || return 1
			[[ -n $want && $want == "$have" ]] || return 1
			gzip -dc "$f" | awk '/^Package:/{p=$2} /^Version:/{v=$2} /^Filename:/{n=$2; sub(".*/","",n)} /^SHA256:/{h=$2} /^$/{if(n!=""&&h!=""&&p!=""&&v!="")print h"  "n"  "p"  "v; n=""; h=""; p=""; v=""} END{if(n!=""&&h!=""&&p!=""&&v!="")print h"  "n"  "p"  "v}' >>"$tmp/trusted" || return 1
		done
	done
	[[ -s $tmp/trusted ]]
}

# linux_deb_not_older <パッケージ> <バージョン>: ランナー自身の APT の候補より古くなければ成功する。
# 候補がないとき（ランナーの APT がそのパッケージを知らないとき）は、信頼できるバージョンの基準がないので失敗にする。
linux_deb_not_older() {
	local cand
	cand=$(apt-cache policy "$1" 2>/dev/null | awk '/^ *Candidate:/{print $2; exit}')
	if [[ -z $cand || $cand == '(none)' ]]; then return 1; fi
	dpkg --compare-versions "$2" ge "$cand"
}

# linux_cache_valid <足りないものの一覧>: キャッシュを入れてよいかを、署名の確認まで含めて判定する。
linux_cache_valid() {
	local wanted=$1 tmp f name entry rc=0
	[[ -f $cache_dir/PACKAGES && -d $cache_dir/apt-meta ]] || return 1
	[[ $(cat "$cache_dir/PACKAGES") == "$wanted" ]] || return 1
	ls "$cache_dir"/*.deb >/dev/null 2>&1 || return 1
	command -v gpgv >/dev/null 2>&1 && [[ -f $apt_keyring ]] || return 1
	tmp=$(mktemp -d "${TMPDIR:-/tmp}/ci-install.XXXXXX") || return 1
	if linux_trusted_hashes "$tmp"; then
		for f in "$cache_dir"/*.deb; do
			# apt はバージョンの epoch の ":" を %3a にして保存する。Packages の Filename は epoch を含まない。
			name=$(printf '%s' "${f##*/}" | sed 's/_[0-9][0-9]*%3a/_/')
			entry=$(awk -v h="$(sha256_of "$f")" -v n="$name" '$1==h && $2==n {print $3" "$4; exit}' "$tmp/trusted")
			[[ -n $entry ]] || { rc=1; break; }
			# shellcheck disable=SC2086
			linux_deb_not_older $entry || { rc=1; break; }
		done
	else
		rc=1
	fi
	rm -rf -- "$tmp"
	return $rc
}

# linux_save_meta: 保存する .deb を含むパッケージ情報と、その InRelease だけを apt の置き場所から写す。
linux_save_meta() {
	local meta=$cache_dir/apt-meta tmp f base prefix
	tmp=$(mktemp -d "${TMPDIR:-/tmp}/ci-install.XXXXXX") || return 1
	mkdir -p "$meta"
	sha256_of "$cache_dir"/*.deb >"$tmp/hashes"
	for f in "$apt_lists_dir"/*_Packages "$apt_lists_dir"/*_Packages.gz "$apt_lists_dir"/*_Packages.xz "$apt_lists_dir"/*_Packages.lz4; do
		[[ -f $f ]] || continue
		list_cat "$f" >"$tmp/plain" 2>/dev/null || continue
		grep -qFf "$tmp/hashes" "$tmp/plain" || continue
		base=${f##*/}
		base=${base%.gz}
		base=${base%.xz}
		base=${base%.lz4}
		prefix=${base%_*_binary-*_Packages}
		[[ -f $apt_lists_dir/${prefix}_InRelease ]] || continue
		cp "$apt_lists_dir/${prefix}_InRelease" "$meta/"
		gzip -n -c "$tmp/plain" >"$meta/$base.gz"
	done
	rm -rf -- "$tmp"
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
		log 'キャッシュの .deb を署名済みのパッケージ情報と照らし、入れます'
		# dpkg -i を並べると、Pre-Depends の順で失敗する。順序と依存は apt に任せる（ダウンロードはしない）。
		if sudo apt-get -o "Dir::Cache::archives=$cache_dir" -o APT::Sandbox::User=root install -y --no-download "$cache_dir"/*.deb && [[ -z $(linux_missing) ]]; then
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
		printf '%s' "$wanted" >"$cache_dir/PACKAGES"
		linux_save_meta
		if linux_cache_valid "$wanted"; then
			emit_source mirror
		else
			# 署名で検証できない形のキャッシュは、次の実行で使えないので保存しない。
			log '保存するキャッシュを署名で検証できませんでした。保存しません'
			linux_clear_cache
			emit_source mirror-uncached
		fi
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

# macos_brew_install <ツール...>: 1 回分の取得。brew が失敗したときと、入れたあとに動作の確認が通らない
# ときは、キャッシュを捨てて失敗で返し、続く再試行でミラーから取り直す（動作の確認が通らなかった
# ときは、入れ済みのものを入れ直す）。ミラーから取ったあとの確認の失敗は、呼び出し側が失敗にする。
macos_brew_install() {
	if ! brew "$brew_cmd" "$@"; then
		macos_discard_cache
		return 1
	fi
	if [[ $cache_used == 1 && -n $(macos_missing) ]]; then
		log 'キャッシュから入れたあとの確認に失敗しました。キャッシュを捨ててミラーから取り直します'
		macos_discard_cache
		brew_cmd=reinstall
		return 1
	fi
}

macos_discard_cache() {
	rm -rf "$HOMEBREW_CACHE"
	mkdir -p "$HOMEBREW_CACHE"
	cache_used=0
}

macos() {
	local missing=() p cache_used=0 brew_cmd=install
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
