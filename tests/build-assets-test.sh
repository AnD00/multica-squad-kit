#!/usr/bin/env bash
# scripts/build-assets.sh の動きを、一時の Git のリポジトリで確認する。
# 展開の前の検証は、git archive を差し替えるスタブで、拒む配布物を流して検証する。本物の GitHub には触れない。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/build-assets.XXXXXX")
exec 8>&2
trap 'test_exit=$?; if [[ $test_exit != 0 ]]; then for log in "$test_dir"/*/out "$test_dir"/*/err; do [[ -f $log ]] && { echo "--- $log" >&8; cat "$log" >&8; }; done; fi; rm -rf -- "$test_dir"' EXIT
# 手元の Git の設定（環境変数で入る GIT_CONFIG_COUNT 以降を含む）から切り離す。
unset GIT_CONFIG_COUNT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME='Test User' GIT_AUTHOR_EMAIL=test@example.test
export GIT_COMMITTER_NAME='Test User' GIT_COMMITTER_EMAIL=test@example.test
real_git=$(command -v git)

# スタブの git は、archive のときだけ EVIL_TAR を -o の先へ写し、それ以外は本物の git に渡す。
mkdir -p "$test_dir/bin"
cat >"$test_dir/bin/git" <<'STUB'
#!/bin/bash
if [[ ${1:-} == archive ]]; then printf '%s\n' "$*" >>"$ARCHIVE_LOG"; fi
if [[ ${1:-} == archive && -n ${EVIL_TAR:-} ]]; then
	while [[ $# -gt 0 ]]; do
		if [[ $1 == -o ]]; then
			cp "$EVIL_TAR" "$2"
			exit 0
		fi
		shift
	done
	exit 1
fi
exec "$REAL_GIT" "$@"
STUB
chmod +x "$test_dir/bin/git"

# make_repo <名前>: タグ v1.6.0 を付けた一時のリポジトリを作る。MANIFEST は本物の scripts/manifest.sh で作る。
make_repo() {
	case_dir="$test_dir/$1"
	repo="$case_dir/repo"
	mkdir -p "$case_dir/tmp" "$repo/scripts" "$repo/lib" "$repo/dir/sub"
	git init -q -b main "$repo"
	cp "$root/scripts/build-assets.sh" "$root/scripts/manifest.sh" "$repo/scripts/"
	cp "$root/lib/ui.sh" "$repo/lib/ui.sh"
	printf 'v1.6.0\n' >"$repo/VERSION"
	cp "$root/install.sh" "$repo/install.sh"
	printf '#!/bin/sh\necho setup\n' >"$repo/setup.sh"
	chmod +x "$repo/setup.sh"
	printf 'a\n' >"$repo/dir/sub/file.txt"
	printf 'b\n' >"$repo/dir/with space.txt"
	(cd "$repo" && bash scripts/manifest.sh)
	rm -rf "$repo/tmp"
	git -C "$repo" add -A
	git -C "$repo" commit -qm 'Release content'
	git -C "$repo" tag -a v1.6.0 -m v1.6.0
}

# run_build <引数...>: 出力先の相対パスの基準は caller（既定は $case_dir）。終了コードを rc に置く。
run_build() {
	rc=0
	: >"$case_dir/archive.log"
	(cd "${caller:-$case_dir}" && env -u BASH_ENV PATH="$test_dir/bin:$PATH" REAL_GIT="$real_git" EVIL_TAR="${EVIL_TAR:-}" TMPDIR="$case_dir/tmp" \
		CHECK_INSTALL="$root/install.sh" LISTING_LOG="$case_dir/listing.log" ARCHIVE_LOG="$case_dir/archive.log" \
		bash "$repo/scripts/build-assets.sh" "$@") >"$case_dir/out" 2>"$case_dir/err" </dev/null || rc=$?
}

# 流したあとに、一時の置き場が残っていない。
no_leftover() { [[ -z $(ls -A "$case_dir/tmp") ]]; }

# 正しいタグ: 3 つが作られ、配布物は 1 つのディレクトリで、中身は git archive と同じ。SHA256SUMS は 2 行で通る。
make_repo ok
run_build v1.6.0 "$case_dir/assets"
[[ $rc == 0 ]]
[[ $(ls "$case_dir/assets" | LC_ALL=C sort | tr '\n' ' ') == 'SHA256SUMS install.sh multica-squad-kit-v1.6.0.tar.gz ' ]]
asset=$case_dir/assets/multica-squad-kit-v1.6.0.tar.gz
[[ $(tar -tzf "$asset" | cut -d/ -f1 | LC_ALL=C sort -u) == multica-squad-kit-v1.6.0 ]]
mkdir "$case_dir/x-asset" "$case_dir/x-archive"
tar -xzf "$asset" -C "$case_dir/x-asset"
git -C "$repo" archive --prefix=multica-squad-kit-v1.6.0/ v1.6.0 | tar -xf - -C "$case_dir/x-archive"
diff -r "$case_dir/x-asset" "$case_dir/x-archive"
[[ -x $case_dir/x-asset/multica-squad-kit-v1.6.0/setup.sh ]]
[[ $(wc -l <"$case_dir/assets/SHA256SUMS" | tr -d ' ') == 2 ]]
(cd "$case_dir/assets" && shasum -a 256 -c SHA256SUMS >/dev/null)
cmp "$case_dir/assets/install.sh" <(git -C "$repo" show v1.6.0:install.sh)
(cd "$case_dir/x-asset/multica-squad-kit-v1.6.0" && shasum -a 256 -c MANIFEST >/dev/null)
no_leftover
# 相対の出力先は、呼んだ場所からの相対で作る。
mkdir "$case_dir/caller"
caller=$case_dir/caller run_build v1.6.0 rel/out
[[ $rc == 0 && -f $case_dir/caller/rel/out/SHA256SUMS ]]
# 空の出力先は使える。
mkdir "$case_dir/empty-out"
run_build v1.6.0 "$case_dir/empty-out"
[[ $rc == 0 && -f $case_dir/empty-out/SHA256SUMS ]]
# 空でない出力先は、何も変えずに止まる。
run_build v1.6.0 "$case_dir/assets"
[[ $rc == 1 ]]
grep -qF '出力先が空ではありません' "$case_dir/err"
[[ $(ls "$case_dir/assets" | wc -l | tr -d ' ') == 3 ]]
no_leftover

# retag <メッセージ>: 作業コピーの変更をコミットし、一時のリポジトリの v1.6.0 を新しいコミットへ付け直す。
# 一時のリポジトリの中だけの操作で、原本のタグは動かさない。
retag() {
	git -C "$repo" add -A
	git -C "$repo" commit -qm "$1"
	git -C "$repo" tag -f -a v1.6.0 -m v1.6.0 >/dev/null
}
# regen_manifest: 作業コピーの MANIFEST を、今の中身で作り直す。
regen_manifest() { (cd "$repo" && bash scripts/manifest.sh && rm -rf tmp); }
# expect_stop <理由>: 出力先を作らずに 1 で止まり、理由を出し、一時の置き場を残さない。
expect_stop() {
	run_build v1.6.0 "$case_dir/assets"
	[[ $rc == 1 && ! -e $case_dir/assets ]] || {
		echo "止まりませんでした: $1" >&2
		exit 1
	}
	grep -qF "$1" "$case_dir/err" || {
		echo "理由が違います: $1" >&2
		exit 1
	}
	no_leftover
}

# VERSION がタグのバージョンと違う: 止まり、出力先を作らない。
make_repo version
printf 'v1.5.0\n' >"$repo/VERSION"
regen_manifest
retag 'Wrong VERSION'
expect_stop 'の VERSION（v1.5.0）が、バージョンと違います'

# HEAD がタグの指すコミットと違う: 止まる。
make_repo head
printf 'later\n' >"$repo/later.txt"
git -C "$repo" add -A
git -C "$repo" commit -qm 'After the tag'
expect_stop 'の指すコミット'

# タグがない、install.sh がない: 止まる。
make_repo notag
run_build v1.9.0 "$case_dir/assets"
[[ $rc == 1 && ! -e $case_dir/assets ]]
grep -qF 'タグ v1.9.0 がありません' "$case_dir/err"
make_repo noinstall
git -C "$repo" rm -q install.sh
regen_manifest
retag 'No install.sh'
expect_stop '通常のファイルの install.sh がありません'

# MANIFEST が合わない（ハッシュ、一覧にないファイル、一覧にあるのにないファイル）: 止まる。
make_repo manifest-hash
printf 'changed\n' >"$repo/dir/sub/file.txt"
retag 'Change a file after the MANIFEST'
expect_stop 'MANIFEST のハッシュと合いません'
make_repo manifest-extra
printf 'extra\n' >"$repo/extra.txt"
retag 'Add a file after the MANIFEST'
expect_stop 'MANIFEST の一覧と、配布物の中のファイルが一致しません'
make_repo manifest-missing
printf '%s  ./not-there.txt\n' "$(printf x | shasum -a 256 | cut -d' ' -f1)" >>"$repo/MANIFEST"
retag 'MANIFEST lists a missing file'
expect_stop 'MANIFEST の一覧と、配布物の中のファイルが一致しません'
make_repo manifest-none
git -C "$repo" rm -q MANIFEST
retag 'No MANIFEST'
expect_stop '配布物に MANIFEST がありません'

# リンクを含むタグ: 止まる。
make_repo symlink
ln -s setup.sh "$repo/link"
regen_manifest
retag 'Add a symlink'
expect_stop 'リンクか特殊なファイル'

# 展開の前の検証: git archive を、拒む配布物を返すスタブに替える。
# make_evil <モード>: 正しい配布物（MANIFEST が合う）に、モードの 1 つのものを足した tar.gz を作る。
make_evil() {
	python3 -I - "$1" "$case_dir/evil.tar.gz" <<'PY'
import hashlib
import io
import sys
import tarfile

mode, path = sys.argv[1], sys.argv[2]
prefix = "multica-squad-kit-v1.6.0/"
version = b"v1.6.0\n"
manifest = ("%s  ./VERSION\n" % hashlib.sha256(version).hexdigest()).encode()
with tarfile.open(path, "w:gz", format=tarfile.PAX_FORMAT) as tar:
    def add(name, data=None, kind=tarfile.REGTYPE, link=""):
        info = tarfile.TarInfo(name)
        info.type = kind
        info.linkname = link
        if kind == tarfile.DIRTYPE:
            info.mode = 0o755
            tar.addfile(info)
        elif kind == tarfile.REGTYPE:
            info.size = len(data)
            info.mode = 0o644
            tar.addfile(info, io.BytesIO(data))
        else:
            info.mode = 0o777
            tar.addfile(info)
    add(prefix, kind=tarfile.DIRTYPE)
    add(prefix + "VERSION", version)
    add(prefix + "MANIFEST", manifest)
    if mode == "absolute":
        add("/tmp/escape.txt", b"x")
    elif mode == "dotdot":
        add(prefix + "../escape.txt", b"x")
    elif mode == "dotdot-end":
        add(prefix + "sub/..", kind=tarfile.DIRTYPE)
    elif mode == "prefix":
        add("other-dir/file.txt", b"x")
    elif mode == "symlink":
        add(prefix + "link", kind=tarfile.SYMTYPE, link="/etc/passwd")
    elif mode == "hardlink":
        add(prefix + "hard", kind=tarfile.LNKTYPE, link=prefix + "VERSION")
    elif mode == "backslash":
        add(prefix + "a\\b.txt", b"x")
    elif mode == "control":
        add(prefix + "a\x07b.txt", b"x")
    elif mode == "newline":
        add(prefix + "a\n" + prefix + "b.txt", b"x")
    elif mode == "fifo":
        add(prefix + "fifo", kind=tarfile.FIFOTYPE)
    elif mode != "none":
        raise SystemExit("unknown mode: " + mode)
PY
}

make_repo evil
evil_cases=(
	'absolute|絶対パスがあります'
	'dotdot|上へ出るパスがあります'
	'dotdot-end|上へ出るパスがあります'
	'prefix|の下ではないものがあります'
	'symlink|リンクか特殊なファイル'
	'hardlink|リンクか特殊なファイル'
	'fifo|リンクか特殊なファイル'
	'backslash|制御文字かバックスラッシュ'
	'control|制御文字かバックスラッシュ'
)
# 対照: 足すものがなければ、同じスタブの道で最後まで通る。
make_evil none
EVIL_TAR=$case_dir/evil.tar.gz run_build v1.6.0 "$case_dir/assets"
[[ $rc == 0 && -f $case_dir/assets/SHA256SUMS ]]
rm -rf "$case_dir/assets"
for entry in "${evil_cases[@]}"; do
	mode=${entry%%|*}
	reason=${entry#*|}
	make_evil "$mode"
	EVIL_TAR=$case_dir/evil.tar.gz run_build v1.6.0 "$case_dir/assets"
	[[ $rc == 1 && ! -e $case_dir/assets ]] || {
		echo "拒まれませんでした: $mode" >&2
		exit 1
	}
	grep -qF "$reason" "$case_dir/err" || {
		echo "理由が違います: $mode" >&2
		exit 1
	}
	grep -qF 'CONTRIBUTING.md' "$case_dir/err"
	grep -qF 'docs/install.md' "$case_dir/err"
	[[ ! -e $case_dir/escape.txt ]]
	no_leftover
done
# 名前に改行がある: 2 つの一覧のどちらかの検証で止まる。
make_evil newline
EVIL_TAR=$case_dir/evil.tar.gz run_build v1.6.0 "$case_dir/assets"
[[ $rc == 1 && ! -e $case_dir/assets ]]
grep -qF 'エラー:' "$case_dir/err"
no_leftover

# タグのない HEAD でも同じ 3 ファイルを作り、git archive の中身と一致する。
make_repo commit
git -C "$repo" tag -d v1.6.0 >/dev/null
chosen=$(git -C "$repo" rev-parse HEAD)
run_build --commit HEAD "$case_dir/assets"
[[ $rc == 0 ]]
[[ $(ls "$case_dir/assets" | LC_ALL=C sort | tr '\n' ' ') == 'SHA256SUMS install.sh multica-squad-kit-v1.6.0.tar.gz ' ]]
(cd "$case_dir/assets" && shasum -a 256 -c SHA256SUMS >/dev/null)
mkdir "$case_dir/x-asset" "$case_dir/x-archive"
tar -xzf "$case_dir/assets/multica-squad-kit-v1.6.0.tar.gz" -C "$case_dir/x-asset"
git -C "$repo" archive --prefix=multica-squad-kit-v1.6.0/ "$chosen" | tar -xf - -C "$case_dir/x-archive"
diff -r "$case_dir/x-asset" "$case_dir/x-archive"
cmp "$case_dir/assets/install.sh" <(git -C "$repo" show "$chosen:install.sh")
no_leftover

# HEAD と違うコミットの VERSION・内容・install.sh を使う。検査する入口は作業ツリーから呼ぶ。
printf 'v2.0.0\n' >"$repo/VERSION"
printf '# later installer\n' >>"$repo/install.sh"
printf 'later\n' >"$repo/later.txt"
regen_manifest
git -C "$repo" add -A
git -C "$repo" commit -qm 'Later content'
cat >"$repo/install.sh" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" >"$LISTING_LOG"
exec /bin/bash "$CHECK_INSTALL" "$@"
STUB
run_build --commit "$chosen" "$case_dir/older-assets"
[[ $rc == 0 ]]
cmp "$case_dir/older-assets/install.sh" "$case_dir/assets/install.sh"
mkdir "$case_dir/x-older"
tar -xzf "$case_dir/older-assets/multica-squad-kit-v1.6.0.tar.gz" -C "$case_dir/x-older"
diff -r "$case_dir/x-older" "$case_dir/x-archive"
[[ $(sed -n '1p' "$case_dir/listing.log") == --check-listing && $(sed -n '2p' "$case_dir/listing.log") == v1.6.0 ]]
grep -qF 'multica-squad-kit-v1.6.0.tar.gz' "$case_dir/listing.log"
no_leftover

# Git の名前の検査と、同じコミットの配布物に対する入口の判定を比べる。
for kind in kanji tab backslash directory printable; do
	make_repo "name-$kind"
	case $kind in
	kanji) name='保-1.txt' ;;
	tab) name=$'tab\tname.txt' ;;
	backslash) name='back\slash.txt' ;;
	directory) name='保-1/scene.md'; mkdir "$repo/保-1" ;;
	printable) name='space ~!@#$%^&()_+-=[]{};,.txt' ;;
	esac
	printf 'x\n' >"$repo/$name"
	regen_manifest
	git -C "$repo" add -A
	git -C "$repo" commit -qm 'Named file'
	run_build --commit HEAD "$case_dir/assets"
	build_rc=$rc
	git -C "$repo" archive --format=tar.gz --prefix=multica-squad-kit-v1.6.0/ -o "$case_dir/listing.tar.gz" HEAD
	listing_rc=0
	bash "$root/install.sh" --check-listing v1.6.0 "$case_dir/listing.tar.gz" >"$case_dir/listing.out" 2>"$case_dir/listing.err" || listing_rc=$?
	[[ $build_rc == "$listing_rc" ]]
	if [[ $kind == printable ]]; then
		[[ $build_rc == 0 && -f $case_dir/assets/SHA256SUMS ]]
	else
		[[ $build_rc == 1 && ! -e $case_dir/assets && ! -s $case_dir/archive.log ]]
		grep -qF 'CONTRIBUTING.md の「ファイルとディレクトリの名前」' "$case_dir/err"
		if [[ $kind == backslash ]]; then
			grep -qF 'バックスラッシュがある' "$case_dir/err"
		else
			grep -qF '印字できる ASCII ではない文字がある' "$case_dir/err"
		fi
		if [[ $kind == tab ]]; then
			grep -qF 'tab\011name.txt' "$case_dir/err"
			! grep -q $'\t' "$case_dir/err"
		else
			grep -qF "$name" "$case_dir/err"
		fi
		if [[ $kind == directory ]]; then grep -qF 'エラー: 保-1:' "$case_dir/err"; fi
	fi
	# タグの形でも名前を検査する。
	git -C "$repo" tag -f -a v1.6.0 -m v1.6.0 >/dev/null
	run_build v1.6.0 "$case_dir/tag-assets"
	[[ $rc == "$build_rc" ]]
	no_leftover
done

# 複数の拒む名前をまとめて出し、20 件を超えた分は件数を出す。
make_repo many-names
for i in 1 2; do printf x >"$repo/保-$i.txt"; done
regen_manifest
git -C "$repo" add -A
git -C "$repo" commit -qm 'Two invalid names'
run_build --commit HEAD "$case_dir/assets"
[[ $rc == 1 && ! -e $case_dir/assets && ! -s $case_dir/archive.log ]]
[[ $(grep -c '印字できる ASCII ではない文字がある' "$case_dir/err") == 2 ]]
grep -qF '保-1.txt' "$case_dir/err"
grep -qF '保-2.txt' "$case_dir/err"
for ((i = 3; i <= 22; i++)); do printf x >"$repo/保-$i.txt"; done
regen_manifest
git -C "$repo" add -A
git -C "$repo" commit -qm 'Many invalid names'
run_build --commit HEAD "$case_dir/assets"
[[ $rc == 1 && ! -e $case_dir/assets ]]
[[ $(grep -c '印字できる ASCII ではない文字がある' "$case_dir/err") == 20 ]]
grep -qF 'ほかに 2 件' "$case_dir/err"
grep -qF '保-1.txt' "$case_dir/err"
grep -qF '保-2.txt' "$case_dir/err"
no_leftover

# コミットの VERSION が欠ける・形に合わない、参照がないときは止まる。
for kind in bad-version no-version; do
	make_repo "commit-$kind"
	if [[ $kind == bad-version ]]; then printf '1.6\n' >"$repo/VERSION"; else git -C "$repo" rm -q VERSION; fi
	regen_manifest
	git -C "$repo" add -A
	git -C "$repo" commit -qm 'Invalid VERSION'
	run_build --commit HEAD "$case_dir/assets"
	[[ $rc == 1 && ! -e $case_dir/assets ]]
	grep -qF VERSION "$case_dir/err"
	no_leftover
done
run_build --commit not-a-commit "$case_dir/assets"
[[ $rc == 1 && ! -e $case_dir/assets ]]
grep -qF 'コミットを読めません' "$case_dir/err"

# 引数: 足りない、余分、バージョンの形が違う、空の出力先は 2 か 1 で終わる。--help と -h は、使い方を出して 0 で終わる。
make_repo args
for args in "" "v1.6.0" "v1.6.0 a b" '--commit' '--commit HEAD' '--commit HEAD a b'; do
	run_build $args
	[[ $rc == 2 ]]
	grep -qF '使い方: bash scripts/build-assets.sh' "$case_dir/err"
done
run_build 1.6.0 "$case_dir/assets"
[[ $rc == 1 && ! -e $case_dir/assets ]]
grep -qF 'vX.Y.Z の形' "$case_dir/err"
run_build v1.6.0 ''
[[ $rc == 2 ]]
run_build --commit HEAD ''
[[ $rc == 2 ]]
for flag in --help -h; do
	run_build "$flag"
	[[ $rc == 0 ]]
	grep -qF '使い方: bash scripts/build-assets.sh' "$case_dir/out"
	grep -qF -- '--commit <コミット> <出力先>' "$case_dir/out"
done
echo 'PASS build-assets: タグの中身から配布物と install.sh と SHA256SUMS を作る。VERSION・HEAD・MANIFEST・リンク・拒む配布物・出力先・引数の誤りで止まることを検証した'
