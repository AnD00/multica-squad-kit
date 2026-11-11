#!/usr/bin/env bash
# scripts/ci-install.sh の動きを、スタブの apt-get・dpkg・brew などで確かめる。
# 取得を省く判定、キャッシュの検証と使い分け、壊れたキャッシュを捨てること、再試行、
# 取得後の確認を、Linux と macOS の両方の流れで見る。本物のパッケージは入れない。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/ci-install.XXXXXX")
exec 8>&2
trap 'test_exit=$?; if [[ $test_exit != 0 && -n ${case_dir:-} ]]; then for f in out err log state; do [[ -f $case_dir/$f ]] && { echo "--- $case_dir/$f" >&8; cat "$case_dir/$f" >&8; }; done; fi; rm -rf -- "$test_dir"' EXIT

packages=(bash zsh git jq gh zip unzip python3 tzdata libdigest-sha-perl procps)

# スタブは、状態のファイル（入っているものを 1 行ずつ）と記録のファイル（呼ばれた順）を使う。
# 失敗させる回数や挙動は、case_dir の中のファイルで切り替える。
stubs="$test_dir/stubs"
mkdir -p "$stubs"
cat >"$stubs/sudo" <<'STUB'
#!/bin/bash
echo "sudo $*" >>"$CASE_DIR/log"
exec "$@"
STUB
cat >"$stubs/sleep" <<'STUB'
#!/bin/bash
echo "sleep $*" >>"$CASE_DIR/log"
STUB
cat >"$stubs/dpkg-query" <<'STUB'
#!/bin/bash
pkg=${*: -1}
if grep -qx -- "$pkg" "$CASE_DIR/state"; then echo installed; else exit 1; fi
STUB
cat >"$stubs/apt-get" <<'STUB'
#!/bin/bash
echo "apt-get $*" >>"$CASE_DIR/log"
archives=
args=()
while [[ $# -gt 0 ]]; do
	if [[ $1 == -o ]]; then
		case $2 in Dir::Cache::archives=*) archives=${2#*=} ;; esac
		shift 2
		continue
	fi
	args+=("$1")
	shift
done
if [[ ${args[0]} == update ]]; then
	fails=$(cat "$CASE_DIR/update-fails" 2>/dev/null || echo 0)
	if [[ $fails -gt 0 ]]; then echo $((fails - 1)) >"$CASE_DIR/update-fails"; echo 'Temporary failure resolving' >&2; exit 100; fi
	exit 0
fi
[[ ${args[0]} == install ]]
mkdir -p "$archives/partial"
: >"$archives/lock"
for pkg in "${args[@]:2}"; do
	printf 'deb-%s\n' "$pkg" >"$archives/${pkg}_1.0_amd64.deb"
	[[ -f $CASE_DIR/apt-noop ]] || echo "$pkg" >>"$CASE_DIR/state"
done
STUB
cat >"$stubs/dpkg" <<'STUB'
#!/bin/bash
echo "dpkg $*" >>"$CASE_DIR/log"
[[ ! -f $CASE_DIR/dpkg-fails ]] || exit 1
[[ $1 == -i ]]
shift
for f in "$@"; do
	name=${f##*/}
	[[ -f $CASE_DIR/dpkg-noop ]] || echo "${name%%_*}" >>"$CASE_DIR/state"
done
STUB
cat >"$stubs/brew" <<'STUB'
#!/bin/bash
echo "brew $*" >>"$CASE_DIR/log"
fails=$(cat "$CASE_DIR/brew-fails" 2>/dev/null || echo 0)
if [[ $fails -gt 0 ]]; then echo $((fails - 1)) >"$CASE_DIR/brew-fails"; echo 'Error: download failed' >&2; exit 1; fi
if [[ -f $HOMEBREW_CACHE/corrupt ]]; then echo 'Error: SHA-256 mismatch' >&2; exit 1; fi
[[ $1 == install ]]
shift
mkdir -p "$HOMEBREW_CACHE/api"
echo "HOMEBREW_NO_AUTO_UPDATE=${HOMEBREW_NO_AUTO_UPDATE:-}" >>"$CASE_DIR/log"
for pkg in "$@"; do
	printf 'bottle-%s\n' "$pkg" >"$HOMEBREW_CACHE/$pkg--1.0.bottle.tar.gz"
	printf 'partial\n' >"$HOMEBREW_CACHE/$pkg.incomplete"
	[[ -f $CASE_DIR/brew-noop ]] || echo "$pkg" >>"$CASE_DIR/state"
done
STUB
cat >"$stubs/jq" <<'STUB'
#!/bin/bash
grep -qx jq "$CASE_DIR/state"
STUB
cat >"$stubs/python3" <<'STUB'
#!/bin/bash
grep -qx python "$CASE_DIR/state"
STUB
chmod +x "$stubs"/*

# new_case <名前> [Linux で入っているもの...]: 空のキャッシュと記録を作る。Linux は引数のもの以外を足りない状態にする。
new_case() {
	case_dir="$test_dir/$1"
	shift
	mkdir -p "$case_dir"
	cache="$case_dir/cache"
	: >"$case_dir/state"
	: >"$case_dir/log"
	: >"$case_dir/out"
	local p
	for p in "$@"; do echo "$p" >>"$case_dir/state"; done
}

# run_install <OS>: スタブを PATH の先頭に置いて流す。終了コードを rc、取り方を source に置く。
run_install() {
	rc=0
	PATH="$stubs:$PATH" CASE_DIR="$case_dir" CI_INSTALL_CACHE_DIR="$cache" GITHUB_OUTPUT="$case_dir/out" \
		bash "$root/scripts/ci-install.sh" "$1" >"$case_dir/stdout" 2>"$case_dir/err" || rc=$?
	source=$(sed -n 's/^source=//p' "$case_dir/out" | tail -1)
}

count() { grep -c -- "$1" "$case_dir/log" || true; }

# 1. Linux: 必要なものがすべて入っていれば、何も取得せずキャッシュにも触れない。
new_case linux-all "${packages[@]}"
run_install Linux
[[ $rc == 0 && $source == none ]]
[[ $(count '^apt-get') == 0 && $(count '^dpkg') == 0 ]]
[[ ! -e $cache ]]

# 2. Linux: 足りないものだけをミラーから取り、保存するキャッシュを作る。
new_case linux-mirror bash git jq gh zip unzip tzdata procps python3
run_install Linux
[[ $rc == 0 && $source == mirror ]]
[[ $(count '^apt-get .*update') == 1 && $(count '^apt-get .*install -y zsh libdigest-sha-perl') == 1 ]]
[[ $(count '^dpkg') == 0 ]]
grep -qF 'Dir::Cache::archives=' "$case_dir/log"
[[ $(cat "$cache/PACKAGES") == 'zsh libdigest-sha-perl' ]]
[[ $(wc -l <"$cache/SHA256SUMS" | tr -d ' ') == 2 ]]
[[ ! -e $cache/partial && ! -e $cache/lock ]]
(cd "$cache" && { sha256sum -c SHA256SUMS || shasum -a 256 -c SHA256SUMS; }) >/dev/null
linux_cache_snapshot="$test_dir/linux-cache"
cp -R "$cache" "$linux_cache_snapshot"

# restore_linux_cache <名前> [Linux で入っているもの...]: 上の保存済みのキャッシュを復元した状態の事例を作る。
restore_linux_cache() {
	local name=$1
	shift
	new_case "$name" "$@"
	cp -R "$linux_cache_snapshot" "$cache"
}
linux_installed=(bash git jq gh zip unzip tzdata procps python3)

# 3. Linux: 有効なキャッシュは、ミラーに行かず dpkg で入れる。
restore_linux_cache linux-cache "${linux_installed[@]}"
run_install Linux
[[ $rc == 0 && $source == cache ]]
[[ $(count '^apt-get') == 0 && $(count '^dpkg -i') == 1 ]]

# 4. Linux: .deb の中身が壊れたキャッシュは使わず、ミラーから取り直して作り直す。
restore_linux_cache linux-corrupt "${linux_installed[@]}"
printf 'tampered\n' >"$cache/zsh_1.0_amd64.deb"
run_install Linux
[[ $rc == 0 && $source == mirror ]]
[[ $(count '^dpkg') == 0 && $(count '^apt-get .*install') == 1 ]]
grep -qx 'deb-zsh' "$cache/zsh_1.0_amd64.deb"
(cd "$cache" && { sha256sum -c SHA256SUMS || shasum -a 256 -c SHA256SUMS; }) >/dev/null

# 5. Linux: 足りないものの一覧が違うキャッシュは使わない。
restore_linux_cache linux-other-set "${linux_installed[@]}" zsh
run_install Linux
[[ $rc == 0 && $source == mirror && $(count '^dpkg') == 0 ]]
[[ $(cat "$cache/PACKAGES") == libdigest-sha-perl ]]

# 6. Linux: 記録にないファイルが混ざったキャッシュは使わない。
restore_linux_cache linux-extra "${linux_installed[@]}"
printf 'extra\n' >"$cache/extra_1.0_amd64.deb"
run_install Linux
[[ $rc == 0 && $source == mirror && $(count '^dpkg') == 0 ]]
[[ ! -e $cache/extra_1.0_amd64.deb ]]

# 7. Linux: 記録がそろわないキャッシュ（ハッシュの一覧なし）は使わない。
restore_linux_cache linux-no-sums "${linux_installed[@]}"
rm "$cache/SHA256SUMS"
run_install Linux
[[ $rc == 0 && $source == mirror && $(count '^dpkg') == 0 ]]

# 8. Linux: 検証を通っても dpkg が失敗したら、キャッシュを捨ててミラーから取る。
restore_linux_cache linux-dpkg-fails "${linux_installed[@]}"
: >"$case_dir/dpkg-fails"
run_install Linux
[[ $rc == 0 && $source == mirror ]]
[[ $(count '^dpkg -i') == 1 && $(count '^apt-get .*install') == 1 ]]

# 9. Linux: dpkg が成功を返しても状態が入っていなければ、ミラーから取り直す。
restore_linux_cache linux-dpkg-noop "${linux_installed[@]}"
: >"$case_dir/dpkg-noop"
run_install Linux
[[ $rc == 0 && $source == mirror && $(count '^apt-get .*install') == 1 ]]

# 10. Linux: update が 2 回失敗しても、3 回目で通り、間隔を伸ばして待つ。
new_case linux-retry "${linux_installed[@]}"
echo 2 >"$case_dir/update-fails"
run_install Linux
[[ $rc == 0 && $source == mirror ]]
[[ $(count '^apt-get .*update') == 3 ]]
[[ $(grep -c '^sleep' "$case_dir/log") == 2 ]]
grep -qx 'sleep 15' "$case_dir/log"
grep -qx 'sleep 30' "$case_dir/log"

# 11. Linux: 4 回失敗したら、失敗で終わり、取り方を書かない。
new_case linux-exhausted "${linux_installed[@]}"
echo 99 >"$case_dir/update-fails"
run_install Linux
[[ $rc == 1 && -z $source ]]
[[ $(count '^apt-get .*update') == 4 && $(grep -c '^sleep' "$case_dir/log") == 3 ]]
grep -qF '4 回失敗しました' "$case_dir/err"

# 12. Linux: 取得が成功を返しても足りないものが残れば、失敗で終わる。
new_case linux-still-missing "${linux_installed[@]}"
: >"$case_dir/apt-noop"
run_install Linux
[[ $rc == 1 && -z $source ]]
grep -qF '取得のあとも足りない' "$case_dir/err"

# 13. macOS: jq と 3.11 以上の python3 があれば、取得しない。
new_case macos-all jq python
run_install macOS
[[ $rc == 0 && $source == none && $(count '^brew') == 0 ]]

# 14. macOS: 足りないものだけを、brew の自動更新を止めて取得し、api と途中のファイルを除いて保存の対象にする。
new_case macos-mirror jq
run_install macOS
[[ $rc == 0 && $source == mirror ]]
[[ $(count '^brew install python$') == 1 && $(count '^brew') == 1 ]]
grep -qx 'HOMEBREW_NO_AUTO_UPDATE=1' "$case_dir/log"
[[ -f $cache/downloads/python--1.0.bottle.tar.gz && ! -e $cache/downloads/api && ! -e $cache/downloads/python.incomplete ]]
macos_cache_snapshot="$test_dir/macos-cache"
cp -R "$cache" "$macos_cache_snapshot"

# 15. macOS: キャッシュがあれば、それを使い、保存し直さない。
new_case macos-cache jq
cp -R "$macos_cache_snapshot" "$cache"
run_install macOS
[[ $rc == 0 && $source == cache && $(count '^brew install python$') == 1 ]]

# 16. macOS: brew が検証で失敗したキャッシュは捨て、ミラーから取り直す。
new_case macos-corrupt jq
cp -R "$macos_cache_snapshot" "$cache"
: >"$cache/downloads/corrupt"
run_install macOS
[[ $rc == 0 && $source == mirror && $(count '^brew install python$') == 2 ]]
[[ ! -e $cache/downloads/corrupt ]]
grep -qx 'sleep 10' "$case_dir/log"

# 17. macOS: 2 回失敗しても 3 回目で通り、3 回失敗したら失敗で終わる。
new_case macos-retry jq
echo 2 >"$case_dir/brew-fails"
run_install macOS
[[ $rc == 0 && $source == mirror && $(count '^brew install') == 3 ]]
grep -qx 'sleep 20' "$case_dir/log"
new_case macos-exhausted jq
echo 99 >"$case_dir/brew-fails"
run_install macOS
[[ $rc == 1 && -z $source && $(count '^brew install') == 3 ]]
grep -qF '3 回失敗しました' "$case_dir/err"

# 18. macOS: brew が成功を返しても足りなければ、失敗で終わる。
new_case macos-noop jq
: >"$case_dir/brew-noop"
run_install macOS
[[ $rc == 1 && -z $source ]]
grep -qF '取得のあとも足りない' "$case_dir/err"

# 19. 引数と保存先の指定がなければ使い方で終わる。
new_case usage
run_install Windows
[[ $rc == 2 && -z $source ]]
rc=0
PATH="$stubs:$PATH" CASE_DIR="$case_dir" bash "$root/scripts/ci-install.sh" Linux >"$case_dir/stdout" 2>"$case_dir/err" || rc=$?
[[ $rc == 2 ]]
grep -qF 'CI_INSTALL_CACHE_DIR' "$case_dir/err"

echo 'PASS ci-install: 足りないものだけを取得し、検証したキャッシュ・ミラーの順に使う。壊れたキャッシュの破棄・再試行・取得後の確認を、Linux と macOS で確かめた'
