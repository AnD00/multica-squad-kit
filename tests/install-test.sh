#!/usr/bin/env bash
# install.sh の確かめ（gh のバージョン、証明、チェックサム、一覧、--verify、引数、バージョンの省略、標準入力からの実行）と、
# 取得・展開・セットアップの流し・片付けを、スタブの gh と一時の置き場で確かめる。本物の GitHub には触れない。展開した setup.sh はスタブで、受けた引数を残す。
# 表示の部品は lib/ui.sh と同じかも照らす。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/install.XXXXXX")
exec 8>&2
trap 'test_exit=$?; if [[ $test_exit != 0 ]]; then for log in "$test_dir"/*/out "$test_dir"/*/err; do [[ -f $log ]] && { echo "--- $log" >&8; cat "$log" >&8; }; done; fi; rm -rf -- "$test_dir"' EXIT
real_uname=$(command -v uname)
real_tar=$(command -v tar)
version=v1.6.0
asset=multica-squad-kit-$version.tar.gz
repo_name=AnD00/multica-squad-kit
default_gh_out=$'gh version 2.102.0 (2026-01-01)\nhttps://github.com/cli/cli/releases/tag/v2.102.0'

# スタブの gh は、--version で GH_VERSION_OUT を出し、呼び方を GH_LOG に 1 行で残す。
# attestation verify は、GH_FAIL_ON に名前を渡したファイルの確かめだけが失敗する。
# release view は、GH_LATEST の最新のタグを出す（GH_LATEST_FAIL で失敗）。
# release download は、--pattern のファイルを GH_ASSETS から --dir へ写す（GH_DOWNLOAD_FAIL で失敗、GH_DOWNLOAD_EMPTY で何も写さず成功）。
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
if [[ ${1:-} == release && ${2:-} == view ]]; then
	[[ -z ${GH_LATEST_FAIL:-} ]] || {
		echo 'stub: no release' >&2
		exit 1
	}
	printf '%s\n' "$GH_LATEST"
	exit 0
fi
if [[ ${1:-} == release && ${2:-} == download ]]; then
	[[ -z ${GH_DOWNLOAD_FAIL:-} ]] || {
		echo 'stub: release not found' >&2
		exit 1
	}
	shift 3
	dir=
	patterns=()
	while [[ $# -gt 0 ]]; do
		case $1 in
		--pattern) patterns+=("$2"); shift 2 ;;
		--dir) dir=$2; shift 2 ;;
		*) shift ;;
		esac
	done
	[[ -d $dir ]] || exit 1
	[[ -z ${GH_DOWNLOAD_EMPTY:-} ]] || exit 0
	for pattern in "${patterns[@]}"; do
		[[ -f $GH_ASSETS/$pattern ]] || {
			echo "stub: no assets match the file pattern $pattern" >&2
			exit 1
		}
		cp "$GH_ASSETS/$pattern" "$dir/$pattern"
	done
	exit 0
fi
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
# スタブの tar は、呼び方を TAR_LOG に残し、本物の tar に任せる。PLANT があれば、展開のあとに、一覧の確かめをすり抜けたものを 1 つ足す。
cat >"$test_dir/bin/tar" <<'STUB'
#!/bin/bash
echo "$*" >>"$TAR_LOG"
"$REAL_TAR" "$@" || exit $?
if [[ ${1:-} == -xzf && -n ${PLANT:-} ]]; then
	top=${4:-}/multica-squad-kit-v1.6.0
	case $PLANT in
	symlink) ln -s /etc/passwd "$top/planted" ;;
	hardlink) ln "$top/VERSION" "$top/hard" ;;
	fifo) mkfifo "$top/fifo" ;;
	esac
fi
exit 0
STUB
chmod +x "$test_dir/bin/gh" "$test_dir/bin/uname" "$test_dir/bin/tar"

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
# 展開した setup.sh のスタブ。受けた引数と流した場所を SETUP_LOG に残し、SETUP_EXIT で終わる。
setup_stub = br"""#!/bin/bash
[[ -z ${SETUP_STARTED:-} ]] || : >"$SETUP_STARTED"
{
	printf 'args:%s\n' "$*"
	printf 'pwd:%s\n' "$PWD"
} >"$SETUP_LOG"
if [[ -n ${SETUP_READ:-} ]]; then
	read -r answer
	printf 'stdin:%s\n' "$answer" >>"$SETUP_LOG"
fi
[[ -z ${SETUP_SLEEP:-} ]] || sleep "$SETUP_SLEEP"
exit "${SETUP_EXIT:-0}"
"""
manifest = ("%s  ./VERSION\n" % hashlib.sha256(version).hexdigest()).encode()
with tarfile.open(path, "w:gz", format=tarfile.PAX_FORMAT) as tar:
    def add(name, data=None, kind=tarfile.REGTYPE, link="", dir_mode=0o755):
        info = tarfile.TarInfo(name)
        info.type = kind
        info.linkname = link
        if kind == tarfile.DIRTYPE:
            info.mode = dir_mode
            tar.addfile(info)
        elif kind == tarfile.REGTYPE:
            info.size = len(data)
            info.mode = 0o644
            tar.addfile(info, io.BytesIO(data))
        else:
            info.mode = 0o777
            tar.addfile(info)
    add(prefix, kind=tarfile.DIRTYPE)
    if mode != "no-version":
        add(prefix + "VERSION", b"v1.6.1\n" if mode == "bad-version" else version)
    add(prefix + "MANIFEST", manifest)
    if mode != "no-setup":
        add(prefix + "setup.sh", setup_stub)
    if mode == "readonly-dir":
        add(prefix + "ro/", kind=tarfile.DIRTYPE, dir_mode=0o555)
        add(prefix + "ro/file", b"x")
    elif mode == "absolute":
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
    elif mode not in ("none", "no-version", "bad-version", "no-setup"):
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
# stub_env: スタブの gh・tar・uname と setup.sh のスタブを使う環境の指定を、配列 envs に置く。
# 一時の置き場は $case_dir/tmp の下に作らせる。
# 実行環境の BASH_ENV が PATH の先頭へ本物の gh を戻すことがあるので、外して、スタブを先に選ばせる。
stub_env() {
	mkdir -p "$case_dir/tmp"
	envs=(env -u BASH_ENV PATH="$test_dir/bin:$PATH" TMPDIR="$case_dir/tmp" GH_LOG="$case_dir/gh.log" GH_ASSETS="$assets"
		GH_VERSION_OUT="$gh_out" GH_VERSION_FAIL="${GH_VERSION_FAIL:-}" GH_FAIL_ON="${GH_FAIL_ON:-}"
		GH_DOWNLOAD_FAIL="${GH_DOWNLOAD_FAIL:-}" GH_DOWNLOAD_EMPTY="${GH_DOWNLOAD_EMPTY:-}"
		GH_LATEST="${GH_LATEST-$version}" GH_LATEST_FAIL="${GH_LATEST_FAIL:-}"
		TAR_LOG="$case_dir/tar.log" REAL_TAR="$real_tar" PLANT="${PLANT:-}"
		SETUP_LOG="$case_dir/setup.log" SETUP_EXIT="${SETUP_EXIT:-0}" SETUP_READ="${SETUP_READ:-}"
		SETUP_SLEEP="${SETUP_SLEEP:-}" SETUP_STARTED="${SETUP_STARTED:-}"
		FAKE_UNAME="${FAKE_UNAME:-}" REAL_UNAME="$real_uname")
}
# reset_logs: gh と tar の記録と、setup.sh のスタブの記録を空にする。
reset_logs() {
	: >"$case_dir/gh.log"
	: >"$case_dir/tar.log"
	rm -f "$case_dir/setup.log"
}
# run_install <引数...>: 終了コードを rc に置く。gh と tar の呼び方は $case_dir/gh.log と tar.log、展開した setup.sh のスタブの記録は setup.log に残る。
# 標準入力は INSTALL_STDIN のファイル（なければ空）。ファイルとして流す（bash install.sh）。
run_install() {
	rc=0
	reset_logs
	stub_env
	(cd "$case_dir" && "${envs[@]}" bash "$root/install.sh" "$@") \
		>"$case_dir/out" 2>"$case_dir/err" <"${INSTALL_STDIN:-/dev/null}" || rc=$?
}
# run_stdin <tty|notty> <引数...>: 入口を標準入力から流す（bash -s -- の引数、cat install.sh | bash と同じ）。終了コードを rc に置く。
# tty は端末（/dev/tty）を使え、TTY_ANSWERS のファイルの中身が端末から読まれる。notty は端末を使えない。
run_stdin() {
	local tty_mode=$1
	shift
	rc=0
	reset_logs
	stub_env
	(cd "$case_dir" && python3 -I "$root/tests/stdin-tty-run.py" "$tty_mode" "${INSTALL_SCRIPT:-$root/install.sh}" "${TTY_ANSWERS:-/dev/null}" \
		"$case_dir/out" "$case_dir/err" -- "${envs[@]}" bash -s -- "$@") || rc=$?
}
# tar_extracts: 展開した回数。
tar_extracts() { grep -c '^-xzf ' "$case_dir/tar.log" || true; }
# not_run: セットアップは流れておらず、一時の置き場は残っておらず、取得は 1 回だけ（取り直していない）。
# 展開したかどうかは、tar の呼び方が残るので、引数の expect_extract で確かめる（yes か no）。
not_run() {
	[[ ! -e $case_dir/setup.log ]] || {
		echo "セットアップが流れています" >&2
		exit 1
	}
	[[ -z $(ls -A "$case_dir/tmp") ]] || {
		echo "一時の置き場が残っています: $(ls -A "$case_dir/tmp")" >&2
		exit 1
	}
	[[ $(grep -c '^release download ' "$case_dir/gh.log" || true) -le 1 ]]
	[[ $(tar_extracts) == "${1:-0}" ]]
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
# 通常の流し方（--verify なし）も、取得の前にバージョンで止まる。
gh_out='gh version 2.101.9' run_install "$version"
expect_stop 1 'gh のバージョンが古く'
! grep -q '^release ' "$case_dir/gh.log"

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
for args in "--verify" "--verify $version" "--verify $version $assets extra" "$version --bogus" "--bogus" "$version --extension" "$version --extension a --extension b" "$version stray"; do
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
run_install ''
[[ $rc == 2 ]]
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

# 流す: 取得、確かめ、展開、確かめのあとで、展開した setup.sh を子のプロセスとして流し、一時の置き場を消す。
new_case run
for os in Darwin Linux; do
	FAKE_UNAME=$os run_install "$version"
	[[ $rc == 0 ]]
	[[ ! -s $case_dir/err ]]
	grep -qF "取得します: $version" "$case_dir/out"
	grep -qF 'セットアップを流します' "$case_dir/out"
	# 引数は渡さず、流した場所のまま流す。
	[[ $(cat "$case_dir/setup.log") == "args:
pwd:$case_dir" ]]
	# 取得は 1 回で、確かめは取ってきたファイルに、証明は SHA256SUMS、配布物の順に行う。
	dl_dir=$(sed -n 's/.* --dir //p' "$case_dir/gh.log")
	[[ $dl_dir == "$case_dir"/tmp/*/assets && $(printf '%s\n' "$dl_dir" | wc -l) -eq 1 ]]
	{
		echo '--version'
		echo "release download $version --repo $repo_name --pattern $asset --pattern SHA256SUMS --dir $dl_dir"
		expected_call "$dl_dir/SHA256SUMS"
		expected_call "$dl_dir/$asset"
	} >"$case_dir/expected.log"
	cmp "$case_dir/gh.log" "$case_dir/expected.log"
	# 展開は 1 回で、確かめた配布物を、新しい空のディレクトリへ。
	[[ $(tar_extracts) == 1 ]]
	grep -qF -- "-xzf $dl_dir/$asset -C ${dl_dir%/assets}/src" "$case_dir/tar.log"
	# 片付け: 一時の置き場は消え、置いてあった配布物はそのまま、流した場所には何も増えない。
	[[ -z $(ls -A "$case_dir/tmp") ]]
	no_extract
	[[ $(ls "$case_dir" | LC_ALL=C sort | tr '\n' ' ') == "assets err expected.log gh.log out setup.log tar.log tmp " ]]
done
# --extension は、そのまま setup.sh へ渡す（相対のまま。絶対にするのは setup.sh）。--no-checkout は渡さない。
run_install "$version" --extension ext
[[ $rc == 0 ]]
[[ $(cat "$case_dir/setup.log") == "args:--extension ext
pwd:$case_dir" ]]
run_install "$version" --extension "$case_dir/ext dir"
[[ $rc == 0 ]]
[[ $(cat "$case_dir/setup.log") == "args:--extension $case_dir/ext dir
pwd:$case_dir" ]]
[[ -z $(ls -A "$case_dir/tmp") && ! -e $case_dir/ext && ! -e "$case_dir/ext dir" ]]
# setup.sh の終了コードで終わり、成否によらず一時の置き場を消す。
for code in 1 2 7 130; do
	SETUP_EXIT=$code run_install "$version"
	[[ $rc == "$code" ]] || {
		echo "setup.sh の終了コード $code で終わっていません（${rc}）" >&2
		exit 1
	}
	[[ -e $case_dir/setup.log && -z $(ls -A "$case_dir/tmp") ]]
done
# 質問に答えられるよう、標準入力は setup.sh へ渡る。
printf 'yes\n' >"$case_dir/stdin"
INSTALL_STDIN="$case_dir/stdin" SETUP_READ=1 run_install "$version"
[[ $rc == 0 ]]
grep -qxF 'stdin:yes' "$case_dir/setup.log"
# setup.sh の流れている途中で止められても、一時の置き場を消す（終了コードは 128 + シグナル）。
# INT は、バックグラウンドで流すと無視される設定で始まるので、ここでは確かめない（install.sh は INT でも同じに止まる trap を持つ）。
for entry in TERM:143 HUP:129; do
	sig=${entry%%:*}
	: >"$case_dir/gh.log"
	rm -f "$case_dir/started"
	(cd "$case_dir" && exec env -u BASH_ENV PATH="$test_dir/bin:$PATH" TMPDIR="$case_dir/tmp" GH_LOG="$case_dir/gh.log" GH_ASSETS="$assets" \
		GH_VERSION_OUT="$gh_out" TAR_LOG="$case_dir/tar.log" REAL_TAR="$real_tar" SETUP_LOG="$case_dir/setup.log" \
		SETUP_STARTED="$case_dir/started" SETUP_SLEEP=1 REAL_UNAME="$real_uname" bash "$root/install.sh" "$version") \
		>"$case_dir/out" 2>"$case_dir/err" </dev/null &
	install_pid=$!
	waited=0
	until [[ -e $case_dir/started ]]; do
		waited=$((waited + 1))
		[[ $waited -le 100 ]] || {
			kill -KILL "$install_pid" 2>/dev/null || true
			echo "setup.sh が流れ始めません" >&2
			exit 1
		}
		sleep 0.1
	done
	[[ -n $(ls -A "$case_dir/tmp") ]]
	kill "-$sig" "$install_pid"
	rc=0
	wait "$install_pid" || rc=$?
	[[ $rc == "${entry#*:}" ]] || {
		echo "シグナル $sig で終わった終了コードが違います（${rc}、期待 ${entry#*:}）" >&2
		exit 1
	}
	[[ -z $(ls -A "$case_dir/tmp") ]] || {
		echo "シグナル $sig のあとに一時の置き場が残っています" >&2
		exit 1
	}
done
# 展開した中が読み取り専用のディレクトリでも、片付けられる。
new_case readonly-dir readonly-dir
run_install "$version"
[[ $rc == 0 ]]
[[ -z $(ls -A "$case_dir/tmp") ]]

# バージョンの省略: 最新を gh release view で 1 回だけ読み、使うバージョンとして出して、そのバージョンで取る。読み直さない。
new_case latest
run_install
[[ $rc == 0 ]]
[[ ! -s $case_dir/err ]]
grep -qxF "使うバージョン: $version" "$case_dir/out"
grep -qF "取得します: $version" "$case_dir/out"
dl_dir=$(sed -n 's/.* --dir //p' "$case_dir/gh.log")
{
	echo '--version'
	echo "release view --repo $repo_name --json tagName --jq .tagName"
	echo "release download $version --repo $repo_name --pattern $asset --pattern SHA256SUMS --dir $dl_dir"
	expected_call "$dl_dir/SHA256SUMS"
	expected_call "$dl_dir/$asset"
} >"$case_dir/expected.log"
cmp "$case_dir/gh.log" "$case_dir/expected.log"
[[ $(grep -c '^release view ' "$case_dir/gh.log") == 1 ]]
[[ $(cat "$case_dir/setup.log") == "args:
pwd:$case_dir" ]]
[[ -z $(ls -A "$case_dir/tmp") ]]
# 版を渡したときは、最新を読まない。
run_install "$version"
[[ $rc == 0 ]]
! grep -q '^release view ' "$case_dir/gh.log"
! grep -q '使うバージョン' "$case_dir/out"
# 版を省いても、--extension は setup.sh へ渡る。
run_install --extension ext
[[ $rc == 0 ]]
[[ $(cat "$case_dir/setup.log") == "args:--extension ext
pwd:$case_dir" ]]
# 最新を読めない、vX.Y.Z の形でない: 何も取らず、確かめも流しもせずに 1 で止まる。
GH_LATEST_FAIL=1 run_install
expect_stop 1 '最新のバージョンを読めませんでした'
grep -qF 'stub: no release' "$case_dir/err"
grep -qF 'gh auth status' "$case_dir/err"
! grep -q '^release download ' "$case_dir/gh.log"
not_run 0
for bad_latest in '' latest v1.6 1.6.0 v1.6.0-rc1 'v1.6.0 x'; do
	GH_LATEST=$bad_latest run_install
	expect_stop 1 '最新の Release のバージョンが vX.Y.Z の形ではありません'
	! grep -q '^release download ' "$case_dir/gh.log"
	not_run 0
done
# --verify は、バージョンを省けない（最新を読まない）。
run_install --verify
[[ $rc == 2 ]]
! grep -q '^release view ' "$case_dir/gh.log"

# 標準入力から流す（cat install.sh | bash -s -- と同じ）: 端末から答えを読み、入口の残りを子のプロセスに読ませない。
new_case stdin
printf 'yes\n' >"$case_dir/answers"
TTY_ANSWERS="$case_dir/answers" SETUP_READ=1 run_stdin tty
[[ $rc == 0 ]]
[[ ! -s $case_dir/err ]]
grep -qxF "使うバージョン: $version" "$case_dir/out"
grep -qxF 'stdin:yes' "$case_dir/setup.log"
[[ $(grep -c '^release view ' "$case_dir/gh.log") == 1 ]]
[[ $(sed -n 's/^args://p' "$case_dir/setup.log") == '' && $(grep -c '^release download ' "$case_dir/gh.log") == 1 ]]
[[ -z $(ls -A "$case_dir/tmp") ]]
# bash -s -- のあとの引数（版と拡張）が届く。
TTY_ANSWERS="$case_dir/answers" SETUP_READ=1 run_stdin tty "$version" --extension ext
[[ $rc == 0 ]]
! grep -q '^release view ' "$case_dir/gh.log"
grep -qxF 'args:--extension ext' "$case_dir/setup.log"
grep -qxF 'stdin:yes' "$case_dir/setup.log"
# 引数の誤りと --help は、標準入力から流しても同じ（端末は要らない）。
run_stdin notty --bogus
[[ $rc == 2 ]]
grep -qF '使い方:' "$case_dir/err"
run_stdin notty --help
[[ $rc == 0 ]]
grep -qF '使い方:' "$case_dir/out"
# setup.sh の終了コードで終わり、一時の置き場を消す。
SETUP_EXIT=7 run_stdin tty
[[ $rc == 7 && -z $(ls -A "$case_dir/tmp") ]]
# 端末を開けないときは、取得の前に、ファイルに取ってから流すことを出して 1 で止まる。
run_stdin notty
expect_stop 1 '端末（/dev/tty）を開けません'
grep -qF 'bash install.sh' "$case_dir/err"
[[ $(cat "$case_dir/gh.log") == '--version' ]]
not_run 0
# --verify は、セットアップを流さないので、端末がなくても確かめられる。
run_stdin notty --verify "$version" "$assets"
[[ $rc == 0 ]]
grep -qF '展開も実行もしていません' "$case_dir/out"
# ファイルとして流すときは、端末を確かめず、標準入力をそのまま setup.sh へ渡す（上の「質問に答えられるよう」と同じ）。
# 最後の行（main の呼び出し）が欠けた入口は、何も取らず、何も流さない。
sed '$d' "$root/install.sh" >"$case_dir/truncated.sh"
[[ $(tail -n 1 "$root/install.sh") == 'main "$@"' && $(wc -l <"$case_dir/truncated.sh") -eq $(($(wc -l <"$root/install.sh") - 1)) ]]
TTY_ANSWERS="$case_dir/answers" INSTALL_SCRIPT="$case_dir/truncated.sh" run_stdin tty
[[ $rc == 0 && ! -s $case_dir/out && ! -s $case_dir/err && ! -s $case_dir/gh.log ]]
not_run 0
# 途中で切れた入口（関数の途中まで）は、構文の誤りで止まり、何も取らない。
head -n "$(($(grep -n '^main() {' "$root/install.sh" | cut -d: -f1) + 3))" "$root/install.sh" >"$case_dir/cut.sh"
TTY_ANSWERS="$case_dir/answers" INSTALL_SCRIPT="$case_dir/cut.sh" run_stdin tty
[[ $rc != 0 && ! -s $case_dir/gh.log ]]
not_run 0

# 取得できない: gh の出した理由と gh auth status の確認を出して 1 で止まる。確かめも展開も流しもしない。取り直さない。
new_case fetch-fail
GH_DOWNLOAD_FAIL=1 run_install "$version"
expect_stop 1 "$version を取得できませんでした"
grep -qF 'stub: release not found' "$case_dir/err"
grep -qF 'gh auth status' "$case_dir/err"
[[ $(attest_calls) == 0 ]]
not_run 0
# Release に配布物がない、SHA256SUMS がない: 取れなかったものとして止まる。
mv "$assets/$asset" "$case_dir/asset.keep"
run_install "$version"
expect_stop 1 "$version を取得できませんでした"
grep -qF "no assets match the file pattern $asset" "$case_dir/err"
not_run 0
mv "$case_dir/asset.keep" "$assets/$asset"
mv "$assets/SHA256SUMS" "$case_dir/sums.keep"
run_install "$version"
expect_stop 1 "$version を取得できませんでした"
not_run 0
mv "$case_dir/sums.keep" "$assets/SHA256SUMS"
# gh が成功と言いながらファイルを置かなかったときも、確かめの前に止まる。
GH_DOWNLOAD_EMPTY=1 run_install "$version"
expect_stop 1 '通常のファイルの SHA256SUMS がありません'
not_run 0

# 確かめに通らないものは、展開も流しもしない（取得のあとの 5 つのどれで止まっても、一時の置き場は消える）。
new_case run-attest-sums
GH_FAIL_ON=SHA256SUMS run_install "$version"
expect_stop 1 '証明を確かめられませんでした: SHA256SUMS'
[[ $(attest_calls) == 1 ]]
not_run 0
GH_FAIL_ON=$asset run_install "$version"
expect_stop 1 "証明を確かめられませんでした: $asset"
[[ $(attest_calls) == 2 ]]
not_run 0
# 配布物を 1 バイト書き換える。
new_case run-tampered
printf 'x' >>"$assets/$asset"
run_install "$version"
expect_stop 1 'チェックサムが、SHA256SUMS と違います'
[[ $(attest_calls) == 1 ]]
not_run 0
# SHA256SUMS の配布物の行がない、2 行ある。
new_case run-sums-missing
printf '%s  install.sh\n' "$(sha_of "$assets/install.sh")" >"$assets/SHA256SUMS"
run_install "$version"
expect_stop 1 "SHA256SUMS に $asset の行がありません"
not_run 0
new_case run-sums-dup
sums_hash=$(sha_of "$assets/$asset")
printf '%s  %s\n%s  %s\n' "$sums_hash" "$asset" "$sums_hash" "$asset" >"$assets/SHA256SUMS"
run_install "$version"
expect_stop 1 "SHA256SUMS に $asset の行が 2 行以上あります"
not_run 0
# 絶対パス、..、別の置き場の下、リンク、特殊なファイルを含む配布物は、展開の前に拒む（展開先の外に何もできない）。
for entry in "${evil_cases[@]}"; do
	mode=${entry%%|*}
	reason=${entry#*|}
	new_case "run-evil-$mode" "$mode"
	run_install "$version"
	expect_stop 1 "$reason"
	[[ $(attest_calls) == 2 ]]
	not_run 0
	[[ ! -e $case_dir/escape.txt && ! -e $case_dir/tmp/escape.txt ]]
done
new_case run-evil-newline newline
run_install "$version"
[[ $rc == 1 ]]
not_run 0

# 展開したものの確かめ: 一覧の確かめをすり抜けたものがあっても、流す前に止まる。
for entry in 'bad-version||VERSION が、指定したバージョン' 'no-version||VERSION がありません' 'no-setup||setup.sh がありません'; do
	mode=${entry%%||*}
	reason=${entry#*||}
	new_case "run-$mode" "$mode"
	run_install "$version"
	expect_stop 1 "$reason"
	not_run 1
done
for plant in symlink hardlink fifo; do
	new_case "run-plant-$plant"
	PLANT=$plant run_install "$version"
	[[ $rc == 1 ]]
	grep -q '^エラー: ' "$case_dir/err"
	not_run 1
done
grep -qF 'リンクか特殊なファイル' "$case_dir/err"
new_case run-plant-hardlink
PLANT=hardlink run_install "$version"
expect_stop 1 'ハードリンクのファイルがあります'
not_run 1
# 展開できない配布物（tar.gz として読めるが、展開に失敗する）は、tar のスタブで再現できないので、確かめない。

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
echo 'PASS install: gh のバージョン・証明・チェックサム・一覧・--verify・引数・バージョンの省略・標準入力からの実行・取得・展開・setup.sh の流し・片付けを、スタブの gh と一時の置き場で確かめた。表示の部品は lib/ui.sh と揃っている'
