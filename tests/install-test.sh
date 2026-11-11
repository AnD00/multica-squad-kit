#!/usr/bin/env bash
# install.sh の確かめ（gh のバージョン、証明、チェックサム、一覧、--verify、引数）を、スタブの gh と一時の置き場で確かめる。
# 本物の GitHub には触れず、展開もしない。表示の部品は lib/ui.sh と同じかも照らす。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/install.XXXXXX")
exec 8>&2
trap 'test_exit=$?; if [[ $test_exit != 0 ]]; then for log in "$test_dir"/*/out "$test_dir"/*/err; do [[ -f $log ]] && { echo "--- $log" >&8; cat "$log" >&8; }; done; fi; rm -rf -- "$test_dir"' EXIT
real_uname=$(command -v uname)
version=v1.6.0
asset=multica-squad-kit-$version.tar.gz
repo_name=AnD00/multica-squad-kit
default_gh_out=$'gh version 2.102.0 (2026-01-01)\nhttps://github.com/cli/cli/releases/tag/v2.102.0'

# スタブの gh は、--version で GH_VERSION_OUT を出し、attestation verify の呼び方を GH_LOG に 1 行で残す。
# GH_FAIL_ON に名前を渡したファイルの確かめだけが失敗する。
mkdir -p "$test_dir/bin"
cat >"$test_dir/bin/gh" <<'STUB'
#!/bin/bash
if [[ ${1:-} == --version ]]; then
	echo '--version' >>"$GH_LOG"
	[[ -z ${GH_VERSION_FAIL:-} ]] || exit 1
	printf '%s\n' "$GH_VERSION_OUT"
	exit 0
fi
echo "$*" >>"$GH_LOG"
if [[ ${1:-} == attestation && ${2:-} == verify ]]; then
	file=${3:-}
	if [[ ${file##*/} == "${GH_FAIL_ON:-}" ]]; then
		echo 'stub: attestation failed' >&2
		exit 1
	fi
	exit 0
fi
exit 1
STUB
cat >"$test_dir/bin/uname" <<'STUB'
#!/bin/bash
if [[ ${1:-} == -s && -n ${FAKE_UNAME:-} ]]; then
	echo "$FAKE_UNAME"
else
	exec "$REAL_UNAME" "$@"
fi
STUB
chmod +x "$test_dir/bin/gh" "$test_dir/bin/uname"

# make_archive <モード> <出力先>: 正しい配布物（MANIFEST が合う）に、モードの 1 つのものを足した tar.gz を作る。
make_archive() {
	python3 -I - "$1" "$2" <<'PY'
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
    elif mode == "bare-file":
        add("multica-squad-kit-v1.6.0", b"x")
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

# sha_of <ファイル>: sha256 の 16 進。
sha_of() {
	local out
	out=$(shasum -a 256 "$1")
	printf '%s' "${out%% *}"
}

# new_case <名前> [モード]: 置き場（SHA256SUMS、配布物、install.sh の 3 つ）を作る。SHA256SUMS は今の配布物と合う。
new_case() {
	case_dir="$test_dir/$1"
	assets="$case_dir/assets"
	mkdir -p "$assets"
	make_archive "${2:-none}" "$assets/$asset"
	printf '#!/bin/sh\necho install\n' >"$assets/install.sh"
	write_sums "$(sha_of "$assets/$asset")"
}
# write_sums <配布物の sha256>: SHA256SUMS を 2 行で書く。
write_sums() {
	printf '%s  %s\n%s  install.sh\n' "$1" "$asset" "$(sha_of "$assets/install.sh")" >"$assets/SHA256SUMS"
}

gh_out=$default_gh_out
# run_install <引数...>: 終了コードを rc に置く。gh の呼び方は $case_dir/gh.log に残る。
# 実行環境の BASH_ENV が PATH の先頭へ本物の gh を戻すことがあるので、外して、スタブを先に選ばせる。
run_install() {
	rc=0
	: >"$case_dir/gh.log"
	(cd "$case_dir" && env -u BASH_ENV PATH="$test_dir/bin:$PATH" GH_LOG="$case_dir/gh.log" GH_VERSION_OUT="$gh_out" GH_VERSION_FAIL="${GH_VERSION_FAIL:-}" \
		GH_FAIL_ON="${GH_FAIL_ON:-}" FAKE_UNAME="${FAKE_UNAME:-}" REAL_UNAME="$real_uname" bash "$root/install.sh" "$@") \
		>"$case_dir/out" 2>"$case_dir/err" </dev/null || rc=$?
}
# attest_calls: 証明を確かめた回数。
attest_calls() { grep -c '^attestation verify ' "$case_dir/gh.log" || true; }
# expect_stop <終了コード> <理由>: 理由を標準エラー出力に出して、その終了コードで止まった。
expect_stop() {
	[[ $rc == "$1" ]] || {
		echo "終了コードが違います（${rc}、期待 $1）: $2" >&2
		exit 1
	}
	grep -qF -- "$2" "$case_dir/err" || {
		echo "理由が違います: $2" >&2
		exit 1
	}
}
# no_extract: 置き場に何も増えず、展開もされていない。
no_extract() {
	[[ $(ls "$assets" | LC_ALL=C sort | tr '\n' ' ') == "SHA256SUMS install.sh $asset " ]]
	[[ ! -e $case_dir/multica-squad-kit-$version && ! -e $assets/multica-squad-kit-$version ]]
}

expected_call() {
	printf 'attestation verify %s --repo %s --signer-workflow %s/.github/workflows/release-assets.yml --source-ref refs/tags/%s --deny-self-hosted-runners\n' \
		"$1" "$repo_name" "$repo_name" "$version"
}

# 全部が合う置き場: 両方の OS で通る。証明は SHA256SUMS、配布物の順に、4 つの指定をそろえて確かめる。展開も実行もしない。
new_case ok
for os in Darwin Linux; do
	FAKE_UNAME=$os run_install --verify "$version" "$assets"
	[[ $rc == 0 ]]
	grep -qF "確かめが通りました: $version" "$case_dir/out"
	grep -qF '展開も実行もしていません' "$case_dir/out"
	[[ ! -s $case_dir/err ]]
	{
		echo '--version'
		expected_call "$assets/SHA256SUMS"
		expected_call "$assets/$asset"
	} >"$case_dir/expected.log"
	cmp "$case_dir/gh.log" "$case_dir/expected.log"
	no_extract
done
# 相対の置き場も使える。
run_install --verify "$version" assets
[[ $rc == 0 ]]
grep -qF -- 'attestation verify assets/SHA256SUMS ' "$case_dir/gh.log"
# 対応しない OS では、gh を呼ぶ前に止まる。
FAKE_UNAME=FreeBSD run_install --verify "$version" "$assets"
expect_stop 1 '対応するのは macOS と Linux'
[[ ! -s $case_dir/gh.log ]]

# gh のバージョン: 2.102.0 以上を数として比べ、足りない・読めないときは証明を確かめずに止まる。
new_case gh-version
for ok_out in 'gh version 2.102.0' 'gh version 2.102.1' 'gh version 2.103.0 (2026-02-01)' 'gh version 3.0.0' 'gh version 10.0.0' 'gh version 2.200.7'; do
	gh_out=$ok_out run_install --verify "$version" "$assets"
	[[ $rc == 0 ]] || {
		echo "通るはずが止まりました: $ok_out" >&2
		exit 1
	}
done
for old_out in 'gh version 2.101.9' 'gh version 2.99.0' 'gh version 2.10.0' 'gh version 1.999.0' 'gh version 2.101.99 (2026-01-01)'; do
	gh_out=$old_out run_install --verify "$version" "$assets"
	expect_stop 1 'gh のバージョンが古く'
	grep -qF '必要: 2.102.0 以上' "$case_dir/err"
	[[ $(attest_calls) == 0 ]]
done
for bad_out in '' 'unknown' 'gh version' 'gh version dev' 'gh version 2.102' 'GH version 2.102.0' 'x gh version 2.102.0'; do
	gh_out=$bad_out run_install --verify "$version" "$assets"
	expect_stop 1 'gh のバージョンを読めません'
	[[ $(attest_calls) == 0 ]]
done
# 1 行目が読めなければ、2 行目にバージョンがあっても通さない。
gh_out=$'unknown\ngh version 2.102.0' run_install --verify "$version" "$assets"
expect_stop 1 'gh のバージョンを読めません'
# gh --version が失敗しても、読めないときと同じに止まる。
GH_VERSION_FAIL=1 run_install --verify "$version" "$assets"
expect_stop 1 'gh のバージョンを読めません'
[[ $(attest_calls) == 0 ]]
# 通常の流し方（--verify なし）も、証明の前にバージョンで止まる。
gh_out='gh version 2.101.9' run_install "$version"
expect_stop 1 'gh のバージョンが古く'

# 証明が通らない: SHA256SUMS の証明で止まれば、チェックサムも配布物の証明も見ない。
new_case attest-sums
GH_FAIL_ON=SHA256SUMS run_install --verify "$version" "$assets"
expect_stop 1 '証明を確かめられませんでした: SHA256SUMS'
grep -qF 'stub: attestation failed' "$case_dir/err"
[[ $(attest_calls) == 1 ]]
no_extract
# 配布物の証明が通らない: SHA256SUMS の証明とチェックサムは通ったあとで止まる。
GH_FAIL_ON=$asset run_install --verify "$version" "$assets"
expect_stop 1 "証明を確かめられませんでした: $asset"
[[ $(attest_calls) == 2 ]]
no_extract

# チェックサム: 配布物と SHA256SUMS の行が違えば、配布物の証明の前に止まる。
new_case sums-mismatch
write_sums "$(printf '%064d' 0)"
run_install --verify "$version" "$assets"
expect_stop 1 'チェックサムが、SHA256SUMS と違います'
[[ $(attest_calls) == 1 ]]
no_extract
# 配布物の中身を差し替えると、SHA256SUMS の行と合わなくなる。
new_case swapped
make_archive absolute "$assets/$asset.new"
mv "$assets/$asset.new" "$assets/$asset"
run_install --verify "$version" "$assets"
expect_stop 1 'チェックサムが、SHA256SUMS と違います'
# 配布物の行がない。ほかのファイル名の行や、名前が似た行は数えない。
new_case sums-missing
printf '%s  install.sh\n%s  %s.bak\n%s  x%s\n' "$(sha_of "$assets/install.sh")" "$(sha_of "$assets/$asset")" "$asset" "$(sha_of "$assets/$asset")" "$asset" >"$assets/SHA256SUMS"
run_install --verify "$version" "$assets"
expect_stop 1 "SHA256SUMS に $asset の行がありません"
# 配布物の行が 2 行ある: 同じ値でも止まる。
new_case sums-dup
sums_hash=$(sha_of "$assets/$asset")
printf '%s  %s\n%s  %s\n' "$sums_hash" "$asset" "$sums_hash" "$asset" >"$assets/SHA256SUMS"
run_install --verify "$version" "$assets"
expect_stop 1 "SHA256SUMS に $asset の行が 2 行以上あります"
# 値が 16 進 64 桁でない行は、配布物の行に数えない。
new_case sums-short
printf '%s  %s\n' 'abc123' "$asset" >"$assets/SHA256SUMS"
run_install --verify "$version" "$assets"
expect_stop 1 "SHA256SUMS に $asset の行がありません"
# 末尾の改行がない最後の行も読む。
new_case sums-nonl
printf '%s  %s' "$(sha_of "$assets/$asset")" "$asset" >"$assets/SHA256SUMS"
run_install --verify "$version" "$assets"
[[ $rc == 0 ]]

# 置き場: ないもの、ディレクトリでないもの、リンクは、証明を確かめずに止まる。
new_case place
run_install --verify "$version" "$case_dir/none"
expect_stop 1 '置き場がディレクトリではありません'
: >"$case_dir/file"
run_install --verify "$version" "$case_dir/file"
expect_stop 1 '置き場がディレクトリではありません'
mv "$assets/SHA256SUMS" "$case_dir/SHA256SUMS.keep"
run_install --verify "$version" "$assets"
expect_stop 1 '通常のファイルの SHA256SUMS がありません'
ln -s ../SHA256SUMS.keep "$assets/SHA256SUMS"
run_install --verify "$version" "$assets"
expect_stop 1 '通常のファイルの SHA256SUMS がありません'
rm "$assets/SHA256SUMS"
mv "$case_dir/SHA256SUMS.keep" "$assets/SHA256SUMS"
mv "$assets/$asset" "$case_dir/asset.keep"
run_install --verify "$version" "$assets"
expect_stop 1 "通常のファイルの $asset がありません"
ln -s ../asset.keep "$assets/$asset"
run_install --verify "$version" "$assets"
expect_stop 1 "通常のファイルの $asset がありません"
[[ $(attest_calls) == 0 ]]
# 別のバージョンの置き場: 配布物の名前が違うので止まる。
rm "$assets/$asset"
mv "$case_dir/asset.keep" "$assets/$asset"
run_install --verify v1.6.1 "$assets"
expect_stop 1 'multica-squad-kit-v1.6.1.tar.gz がありません'

# 一覧: 展開先の外へ書くもの、読み違えのおそれがあるものは、2 つの証明とチェックサムが通っても拒む。
evil_cases=(
	'absolute|絶対パスがあります'
	'dotdot|上へ出るパスがあります'
	'dotdot-end|上へ出るパスがあります'
	'prefix|の下ではないものがあります'
	'bare-file|の下ではないものがあります'
	'symlink|リンクか特殊なファイル'
	'hardlink|リンクか特殊なファイル'
	'fifo|リンクか特殊なファイル'
	'backslash|制御文字かバックスラッシュ'
	'control|制御文字かバックスラッシュ'
)
for entry in "${evil_cases[@]}"; do
	mode=${entry%%|*}
	reason=${entry#*|}
	new_case "evil-$mode" "$mode"
	run_install --verify "$version" "$assets"
	expect_stop 1 "$reason"
	[[ $(attest_calls) == 2 ]]
	no_extract
	[[ ! -e $case_dir/escape.txt ]]
done
# 名前に改行がある: 2 つの一覧のどちらかの確かめで止まる。
new_case evil-newline newline
run_install --verify "$version" "$assets"
[[ $rc == 1 ]]
grep -qF 'エラー:' "$case_dir/err"
no_extract
# 配布物が tar.gz として読めない。
new_case not-tar
printf 'not a tar\n' >"$assets/$asset"
write_sums "$(sha_of "$assets/$asset")"
run_install --verify "$version" "$assets"
expect_stop 1 '配布物の一覧を読めません'

# 引数の誤り: 2 で終わり、使い方を出し、gh は呼ばない。
new_case args
for args in "" "--verify" "--verify $version" "--verify $version $assets extra" "$version --bogus" "--bogus" "$version --extension" "$version --extension a --extension b" "$version stray"; do
	# shellcheck disable=SC2086
	run_install $args
	[[ $rc == 2 ]] || {
		echo "終了コードが 2 ではありません: $args" >&2
		exit 1
	}
	grep -qF '使い方:' "$case_dir/err"
	[[ ! -s $case_dir/gh.log ]]
done
for bad in 1.6.0 v1.6 v1.6.0.1 v1.6.x 'v1.6.0 ' vv1.6.0; do
	run_install "$bad"
	[[ $rc == 2 ]] || {
		echo "終了コードが 2 ではありません: $bad" >&2
		exit 1
	}
	grep -qF 'vX.Y.Z の形' "$case_dir/err"
	run_install --verify "$bad" "$assets"
	[[ $rc == 2 ]]
done
run_install --verify "$version" ''
[[ $rc == 2 ]]
run_install "$version" --extension ''
[[ $rc == 2 ]]
[[ ! -s $case_dir/gh.log ]]
# --help と -h は、使い方を標準出力に出して 0 で終わる。ほかの引数を付けると 2。
for flag in --help -h; do
	run_install "$flag"
	[[ $rc == 0 ]]
	grep -qF '使い方:' "$case_dir/out"
	grep -qF -- '--verify <バージョン> <置き場>' "$case_dir/out"
	[[ ! -s $case_dir/err && ! -s $case_dir/gh.log ]]
done
run_install --help "$version"
[[ $rc == 2 ]]

# 通常の流し方（--verify なし）は、取得と展開が入るまでは、何も取得せず 1 で止まる。
run_install "$version"
expect_stop 1 '取得と展開は、まだこの install.sh に入っていません'
run_install "$version" --extension "$case_dir/ext"
expect_stop 1 '取得と展開は、まだこの install.sh に入っていません'
[[ $(attest_calls) == 0 && ! -e $case_dir/ext ]]

# 表示の部品は、lib/ui.sh と同じ値と同じ書き方を持つ（install.sh は lib/ui.sh を読めないので、写しを持つ）。
func_body() { awk -v n="$1" 'index($0, n "() {") == 1 { p = 1; if ($0 ~ /\}$/) { print; exit } } p { print } p && /^}$/ { exit }' "$2"; }
for fn in ui_init ui_paint ui_line ui_error ui_warning; do
	[[ -n $(func_body "$fn" "$root/lib/ui.sh") ]]
	[[ $(func_body "$fn" "$root/lib/ui.sh") == "$(func_body "$fn" "$root/install.sh")" ]] || {
		echo "install.sh の $fn が lib/ui.sh と違います" >&2
		exit 1
	}
done
for kind in success warning error; do
	[[ -n $(grep -E "^[[:space:]]+$kind\)" "$root/lib/ui.sh") ]]
	[[ $(grep -E "^[[:space:]]+$kind\)" "$root/lib/ui.sh") == "$(grep -E "^[[:space:]]+$kind\)" "$root/install.sh")" ]] || {
		echo "install.sh の $kind の色が lib/ui.sh と違います" >&2
		exit 1
	}
done
# 印は色の有無によらず同じ文字を出す（端末ではないので、色は付かない）。
new_case ui
gh_out=garbage run_install --verify "$version" "$assets"
grep -q '^エラー: ' "$case_dir/err"
! grep -q $'\033' "$case_dir/err"
echo 'PASS install: gh のバージョン・証明・チェックサム・一覧・--verify・引数を、スタブの gh と一時の置き場で確かめた。表示の部品は lib/ui.sh と揃っている'
