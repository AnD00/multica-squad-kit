#!/usr/bin/env bash
# scripts/ci-install.sh の動きを、スタブの apt-get・brew などで確かめる。
# 取得を省く判定、キャッシュの検証と使い分け、壊れた・差し替えられたキャッシュを捨てること、再試行、
# 取得後の確認を、Linux と macOS の両方の流れで見る。本物のパッケージは入れない。
# Linux のキャッシュは、テスト用の鍵で署名した InRelease・Packages と照らして確かめる（本物の gpgv を使う）。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/ci-install.XXXXXX")
exec 8>&2
trap 'test_exit=$?; if [[ $test_exit != 0 && -n ${case_dir:-} ]]; then for f in out err log state; do [[ -f $case_dir/$f ]] && { echo "--- $case_dir/$f" >&8; cat "$case_dir/$f" >&8; }; done; fi; rm -rf -- "$test_dir"' EXIT

packages=(bash zsh git jq gh zip unzip python3 tzdata libdigest-sha-perl procps gpgv)
command -v gpgv >/dev/null 2>&1 || { echo 'FAIL: gpgv が要ります（署名の確認のテスト用）' >&8; exit 1; }

sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi | awk '{print $1}'; }

# ---- 署名したパッケージ情報（tests/fixtures/ci-install。generate.sh で作る） ----
# keyring.gpg がランナーの公開鍵（ubuntu-archive-keyring の代わり）。InRelease.attacker はこの鍵にない鍵の署名。
fx="$root/tests/fixtures/ci-install"
lists_prefix=mirror.test_ubuntu_dists_noble
# make_lists <ディレクトリ> <InRelease の元>: stub の apt-get update が置くパッケージ情報。
make_lists() {
	mkdir -p "$1"
	cp "$fx/Packages" "$1/${lists_prefix}_main_binary-amd64_Packages"
	cp "$fx/$2" "$1/${lists_prefix}_InRelease"
}
make_lists "$test_dir/lists-ok" InRelease
make_lists "$test_dir/lists-expired" InRelease.expired
lists_src="$test_dir/lists-ok"


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
	mkdir -p "$CI_INSTALL_APT_LISTS_DIR"
	cp "$LISTS_SRC"/* "$CI_INSTALL_APT_LISTS_DIR/"
	exit 0
fi
[[ ${args[0]} == install ]]
mkdir -p "$archives/partial"
: >"$archives/lock"
for pkg in "${args[@]:1}"; do
	[[ $pkg != -* ]] || continue
	# ローカルの .deb を指す install（キャッシュから入れる）。失敗や、成功なのに入らない状態を作れる。
	if [[ $pkg == /*.deb ]]; then
		[[ ! -f $CASE_DIR/local-install-fails ]] || exit 1
		name=${pkg##*/}
		[[ -f $CASE_DIR/local-install-noop ]] || echo "${name%%_*}" >>"$CASE_DIR/state"
		continue
	fi
	ver=1.0
	[[ $pkg != libdigest-sha-perl ]] || ver='1%3a1.0'
	printf 'deb-%s\n' "$pkg" >"$archives/${pkg}_${ver}_amd64.deb"
	[[ -f $CASE_DIR/apt-noop ]] || echo "$pkg" >>"$CASE_DIR/state"
done
STUB
# apt-helper cat-file: 本物は lz4 などを展開する。ここでは、.lz4 の名前で置いた gzip を展開する。
cat >"$stubs/apt-helper" <<'STUB'
#!/bin/bash
[[ $1 == cat-file ]]
gzip -dc "$2"
STUB
cat >"$stubs/brew" <<'STUB'
#!/bin/bash
echo "brew $*" >>"$CASE_DIR/log"
fails=$(cat "$CASE_DIR/brew-fails" 2>/dev/null || echo 0)
if [[ $fails -gt 0 ]]; then echo $((fails - 1)) >"$CASE_DIR/brew-fails"; echo 'Error: download failed' >&2; exit 1; fi
if [[ -f $HOMEBREW_CACHE/corrupt ]]; then echo 'Error: SHA-256 mismatch' >&2; exit 1; fi
[[ $1 == install || $1 == reinstall ]]
cmd=$1
shift
# キャッシュから入れる install は成功を返すが入らない、という状態を作る（brew-noop-cached）。
if [[ $cmd == install && -f $CASE_DIR/brew-noop-cached ]] && ls "$HOMEBREW_CACHE" | grep -q bottle; then exit 0; fi
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
# apt-cache policy: ランナーの APT の候補。case_dir の candidates（「パッケージ バージョン」を 1 行ずつ）があればそれを、なければ全部 1.0 を返す。
cat >"$stubs/apt-cache" <<'STUB'
#!/bin/bash
[[ $1 == policy ]] || exit 1
pkg=$2
if [[ -f $CASE_DIR/candidates ]]; then
	cand=$(awk -v p="$pkg" '$1==p{print $2}' "$CASE_DIR/candidates")
	[[ -n $cand ]] || cand='(none)'
else
	cand=1.0
fi
printf '%s:\n  Installed: (none)\n  Candidate: %s\n' "$pkg" "$cand"
STUB
# dpkg --compare-versions <a> ge <b>: この test のバージョンは「数字をドットでつないだもの」だけなので、数字の比較で足りる。
cat >"$stubs/dpkg" <<'STUB'
#!/bin/bash
[[ $1 == --compare-versions && $3 == ge ]] || exit 2
awk -v a="$2" -v b="$4" 'BEGIN{n=split(a,x,"."); m=split(b,y,"."); k=(n>m?n:m); for(i=1;i<=k;i++){if(x[i]+0>y[i]+0)exit 0; if(x[i]+0<y[i]+0)exit 1} exit 0}'
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
	lists_src="$test_dir/lists-ok"
	keyring=
	runner_codename=
	local p
	for p in "$@"; do echo "$p" >>"$case_dir/state"; done
}

# run_install <OS>: スタブを PATH の先頭に置いて流す。終了コードを rc、取り方を source に置く。
run_install() {
	rc=0
	PATH="$stubs:$PATH" CASE_DIR="$case_dir" CI_INSTALL_CACHE_DIR="$cache" GITHUB_OUTPUT="$case_dir/out" \
		CI_INSTALL_APT_CODENAME="${runner_codename:-noble}" CI_INSTALL_APT_KEYRING="${keyring:-$fx/keyring.gpg}" CI_INSTALL_APT_HELPER="$stubs/apt-helper" CI_INSTALL_APT_LISTS_DIR="$case_dir/lists" LISTS_SRC="$lists_src" \
		bash "$root/scripts/ci-install.sh" "$1" >"$case_dir/stdout" 2>"$case_dir/err" || rc=$?
	source=$(sed -n 's/^source=//p' "$case_dir/out" | tail -1)
}

count() { grep -c -- "$1" "$case_dir/log" || true; }

# 1. Linux: 必要なものがすべて入っていれば、何も取得せずキャッシュにも触れない。
new_case linux-all "${packages[@]}"
run_install Linux
[[ $rc == 0 && $source == none ]]
[[ $(count '^apt-get') == 0 ]]
[[ ! -e $cache ]]

# 2. Linux: 足りないものだけをミラーから取り、保存するキャッシュを作る。
new_case linux-mirror bash git jq gh zip unzip tzdata procps python3 gpgv
run_install Linux
[[ $rc == 0 && $source == mirror ]]
[[ $(count '^apt-get .*update') == 1 && $(count '^apt-get .*install -y zsh libdigest-sha-perl') == 1 ]]
[[ $(count '^apt-get .*no-download') == 0 ]]
grep -qF 'Dir::Cache::archives=' "$case_dir/log"
[[ $(cat "$cache/PACKAGES") == 'zsh libdigest-sha-perl' ]]
[[ ! -e $cache/SHA256SUMS && ! -e $cache/partial && ! -e $cache/lock ]]
[[ -f $cache/libdigest-sha-perl_1%3a1.0_amd64.deb && -f $cache/zsh_1.0_amd64.deb ]]
# 保存するのは、.deb を含むパッケージ情報と、その InRelease だけ。
[[ $(ls "$cache/apt-meta" | wc -l | tr -d ' ') == 2 && -f $cache/apt-meta/${lists_prefix}_InRelease && -f $cache/apt-meta/${lists_prefix}_main_binary-amd64_Packages.gz ]]
linux_cache_snapshot="$test_dir/snapshot-linux"
cp -R "$cache" "$linux_cache_snapshot"

# restore_linux_cache <名前> [Linux で入っているもの...]: 上の保存済みのキャッシュを復元した状態の事例を作る。
restore_linux_cache() {
	local name=$1
	shift
	new_case "$name" "$@"
	cp -R "$linux_cache_snapshot" "$cache"
}
linux_installed=(bash git jq gh zip unzip tzdata procps python3 gpgv)

# 3. Linux: 有効なキャッシュは、ミラーに行かず、ローカルの .deb として apt-get で入れる（依存の順は apt に任せる）。
restore_linux_cache linux-cache "${linux_installed[@]}"
run_install Linux
[[ $rc == 0 && $source == cache ]]
[[ $(count '^apt-get .*update') == 0 && $(count '^apt-get .*install -y [a-z]') == 0 && $(count '^apt-get .*install -y --no-download /') == 1 ]]

# 3b. Linux: Ubuntu 24.04 の apt は、パッケージ情報を .lz4 で置く。lz4 のコマンドが無くても、apt-helper で展開して保存し、あとで検証できる。
new_case linux-lz4 "${linux_installed[@]}"
mkdir "$test_dir/lists-lz4"
gzip -n -c "$fx/Packages" >"$test_dir/lists-lz4/${lists_prefix}_main_binary-amd64_Packages.lz4"
cp "$fx/InRelease" "$test_dir/lists-lz4/${lists_prefix}_InRelease"
lists_src="$test_dir/lists-lz4"
run_install Linux
[[ $rc == 0 && $source == mirror && -f $cache/apt-meta/${lists_prefix}_main_binary-amd64_Packages.gz ]]

# 4. Linux: .deb の中身が署名済みの情報と合わないキャッシュは使わず、ミラーから取り直して作り直す。
restore_linux_cache linux-corrupt "${linux_installed[@]}"
printf 'tampered\n' >"$cache/zsh_1.0_amd64.deb"
run_install Linux
[[ $rc == 0 && $source == mirror ]]
[[ $(count '^apt-get .*no-download') == 0 && $(count '^apt-get .*install -y [a-z]') == 1 ]]
grep -qx 'deb-zsh' "$cache/zsh_1.0_amd64.deb"

# 5. Linux: 足りないものの一覧が違うキャッシュは使わない。
restore_linux_cache linux-other-set "${linux_installed[@]}" zsh
run_install Linux
[[ $rc == 0 && $source == mirror && $(count '^apt-get .*no-download') == 0 ]]
[[ $(cat "$cache/PACKAGES") == libdigest-sha-perl ]]

# 6. Linux: 記録にないファイルが混ざったキャッシュは使わない。
restore_linux_cache linux-extra "${linux_installed[@]}"
printf 'extra\n' >"$cache/extra_1.0_amd64.deb"
run_install Linux
[[ $rc == 0 && $source == mirror && $(count '^apt-get .*no-download') == 0 ]]
[[ ! -e $cache/extra_1.0_amd64.deb ]]

# 7. Linux: パッケージ情報（apt-meta）がないキャッシュは、確かめられないので使わない。
restore_linux_cache linux-no-meta "${linux_installed[@]}"
rm -r "$cache/apt-meta"
run_install Linux
[[ $rc == 0 && $source == mirror && $(count '^apt-get .*no-download') == 0 ]]

# tamper_deb: キャッシュの zsh の .deb を差し替える。
tamper_deb() { printf 'evil\n' >"$cache/zsh_1.0_amd64.deb"; }
# tamper_packages: Packages を、zsh の SHA-256 を差し替えた .deb のものに書き換えたもの（Packages.tampered）にする。
tamper_packages() { gzip -n -c "$fx/Packages.tampered" >"$cache/apt-meta/${lists_prefix}_main_binary-amd64_Packages.gz"; }
# tamper_inrelease: InRelease の Packages のハッシュを、差し替えた Packages のものに書き換える。署名はそのまま。
tamper_inrelease() {
	local f=$cache/apt-meta/${lists_prefix}_InRelease
	sed -i.bak "s/^ [0-9a-f]\\{64\\} / $(sha256_of "$fx/Packages.tampered") /" "$f"
	rm "$f.bak"
}
# expect_rejected: 差し替えたキャッシュは使わず、ミラーから取り直して、本物に戻る。
expect_rejected() {
	run_install Linux
	[[ $rc == 0 && $source == mirror && $(count '^apt-get .*no-download') == 0 && $(count '^apt-get .*install -y [a-z]') == 1 ]]
	grep -qx 'deb-zsh' "$cache/zsh_1.0_amd64.deb"
}

# 7a. Linux: .deb と Packages を一緒に差し替えても、InRelease が記すハッシュと合わなければ使わない。
restore_linux_cache linux-tamper-packages "${linux_installed[@]}"
tamper_deb
tamper_packages
expect_rejected

# 7b. Linux: .deb・Packages・InRelease を一緒に書き換えても、署名が合わなければ使わない。
restore_linux_cache linux-tamper-inrelease "${linux_installed[@]}"
tamper_deb
tamper_packages
tamper_inrelease
expect_rejected

# 7c. Linux: 別の鍵（ランナーの公開鍵にない鍵）で署名し直しても使わない。
restore_linux_cache linux-tamper-attacker "${linux_installed[@]}"
tamper_deb
tamper_packages
cp "$fx/InRelease.attacker" "$cache/apt-meta/${lists_prefix}_InRelease"
expect_rejected

# 7d. Linux: 署名が正しくても、Valid-Until を過ぎた情報では使わない。
restore_linux_cache linux-expired "${linux_installed[@]}"
cp "$fx/InRelease.expired" "$cache/apt-meta/${lists_prefix}_InRelease"
run_install Linux
[[ $rc == 0 && $source == mirror && $(count '^apt-get .*no-download') == 0 ]]

# 7g. Linux: 正しく署名された別のリリース（focal）の情報と、その .deb は、ランナーのリリースでないので使わない。
restore_linux_cache linux-other-release "${linux_installed[@]}"
cp "$fx/InRelease.focal" "$cache/apt-meta/${lists_prefix}_InRelease"
run_install Linux
[[ $rc == 0 && $source == mirror && $(count '^apt-get .*no-download') == 0 ]]

# 7g2. Linux: Codename だけ、または Suite だけがランナーのリリースと違う署名済みの情報も使わない。-updates の Suite は使える。
for f in codename backports; do
	restore_linux_cache "linux-release-$f" "${linux_installed[@]}"
	cp "$fx/InRelease.$f" "$cache/apt-meta/${lists_prefix}_InRelease"
	run_install Linux
	[[ $rc == 0 && $source == mirror && $(count '^apt-get .*no-download') == 0 ]]
done
restore_linux_cache linux-release-updates "${linux_installed[@]}"
cp "$fx/InRelease.updates" "$cache/apt-meta/${lists_prefix}_InRelease"
run_install Linux
[[ $rc == 0 && $source == cache ]]

# 7h. Linux: 逆に、ランナーが focal なら、noble の署名済みキャッシュを使わない。
restore_linux_cache linux-runner-focal "${linux_installed[@]}"
runner_codename=focal
run_install Linux
[[ $source != cache && $(count '^apt-get .*no-download') == 0 ]]

# 7i. Linux: 署名が正しく Valid-Until のない（期限のない）古いバージョンの .deb は、ランナーの候補より古いので使わない。
restore_linux_cache linux-old-version "${linux_installed[@]}"
mv "$cache/zsh_1.0_amd64.deb" "$cache/zsh_0.5_amd64.deb"
gzip -n -c "$fx/Packages.old" >"$cache/apt-meta/${lists_prefix}_main_binary-amd64_Packages.gz"
cp "$fx/InRelease.old" "$cache/apt-meta/${lists_prefix}_InRelease"
run_install Linux
[[ $rc == 0 && $source == mirror && $(count '^apt-get .*no-download') == 0 ]]
[[ -f $cache/zsh_1.0_amd64.deb && ! -e $cache/zsh_0.5_amd64.deb ]]

# 7j. Linux: 7i と同じキャッシュでも、ランナーの候補が同じバージョン（0.5）なら使える（バージョンの比較だけで拒否している対照）。
restore_linux_cache linux-old-version-control "${linux_installed[@]}"
mv "$cache/zsh_1.0_amd64.deb" "$cache/zsh_0.5_amd64.deb"
gzip -n -c "$fx/Packages.old" >"$cache/apt-meta/${lists_prefix}_main_binary-amd64_Packages.gz"
cp "$fx/InRelease.old" "$cache/apt-meta/${lists_prefix}_InRelease"
printf 'zsh 0.5\nlibdigest-sha-perl 1.0\n' >"$case_dir/candidates"
run_install Linux
[[ $rc == 0 && $source == cache && $(count '^apt-get .*install -y --no-download /') == 1 ]]

# 7k. Linux: ランナーの APT に候補がないパッケージは、信頼できるバージョンの基準がないので、キャッシュを使わず、保存もしない。
restore_linux_cache linux-no-candidate "${linux_installed[@]}"
printf 'libdigest-sha-perl 1.0\n' >"$case_dir/candidates"
run_install Linux
[[ $rc == 0 && $source == mirror-uncached && $(count '^apt-get .*no-download') == 0 && ! -e $cache/PACKAGES ]]

# 7e. Linux: 公開鍵が見つからないときは、キャッシュを確かめられないので使わず、保存もしない。
restore_linux_cache linux-no-keyring "${linux_installed[@]}"
keyring="$test_dir/missing.gpg"
run_install Linux
[[ $rc == 0 && $source == mirror-uncached && $(count '^apt-get .*no-download') == 0 && $(count '^apt-get .*install -y [a-z]') == 1 ]]
[[ ! -e $cache/PACKAGES ]]

# 7f. Linux: 期限切れの情報しか手に入らないときも、取得はできるが、保存はしない。
new_case linux-expired-mirror "${linux_installed[@]}"
lists_src="$test_dir/lists-expired"
run_install Linux
[[ $rc == 0 && $source == mirror-uncached && ! -e $cache/PACKAGES ]]
grep -qF '署名で確かめられませんでした' "$case_dir/stdout"

# 8. Linux: 検証を通ってもローカルの install が失敗したら、キャッシュを捨ててミラーから取る。
restore_linux_cache linux-local-install-fails "${linux_installed[@]}"
: >"$case_dir/local-install-fails"
run_install Linux
[[ $rc == 0 && $source == mirror ]]
[[ $(count '^apt-get .*install -y --no-download /') == 1 && $(count '^apt-get .*install -y [a-z]') == 1 ]]

# 9. Linux: install が成功を返しても状態が入っていなければ、ミラーから取り直す。
restore_linux_cache linux-local-install-noop "${linux_installed[@]}"
: >"$case_dir/local-install-noop"
run_install Linux
[[ $rc == 0 && $source == mirror && $(count '^apt-get .*install -y [a-z]') == 1 ]]

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
macos_cache_snapshot="$test_dir/snapshot-macos"
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

# 16b. macOS: キャッシュから入れたあと動作の確認が通らなければ、キャッシュを捨て、ミラーから入れ直す。
new_case macos-cache-postcheck jq
cp -R "$macos_cache_snapshot" "$cache"
: >"$case_dir/brew-noop-cached"
run_install macOS
[[ $rc == 0 && $source == mirror ]]
[[ $(count '^brew install python$') == 1 && $(count '^brew reinstall python$') == 1 ]]
grep -qx 'sleep 10' "$case_dir/log"
grep -qF '確認に失敗しました' "$case_dir/stdout"
# 入れ直してもまだ確認が通らなければ、失敗で終わる。
new_case macos-cache-postcheck-fails jq
cp -R "$macos_cache_snapshot" "$cache"
: >"$case_dir/brew-noop"
run_install macOS
[[ $rc == 1 && -z $source && $(count '^brew reinstall python$') == 1 ]]
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
