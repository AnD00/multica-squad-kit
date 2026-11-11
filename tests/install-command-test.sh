#!/usr/bin/env bash
# README.md の 1 行のコマンドと手動の手順を取り出して、bash と zsh で流し、スタブの curl・gh と一時の置き場で確かめる。本物の GitHub には触れない。
# 1 行のコマンドは、スタブの curl が返した入口（ルートの install.sh）を、擬似端末の中で流す。入口は最新のバージョンを出して取得・確かめ・展開し、
# セットアップは端末から答えを読む。切れた入口と端末のないときは、何も取らずに終わる。
# 手動の手順は、取り直しをせず、1 行のコマンドと同じ setup.sh を同じ引数で流す。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/install-command.XXXXXX")
exec 8>&2
trap 'test_exit=$?; if [[ $test_exit != 0 ]]; then for log in "$test_dir"/*/out "$test_dir"/*/err; do [[ -f $log ]] && { echo "--- $log" >&8; cat "$log" >&8; }; done; fi; rm -rf -- "$test_dir"' EXIT
real_mktemp=$(command -v mktemp)
version=v1.6.0
asset=multica-squad-kit-$version.tar.gz
repo_name=AnD00/multica-squad-kit
default_gh_out=$'gh version 2.102.0 (2026-01-01)\nhttps://github.com/cli/cli/releases/tag/v2.102.0'

# README.md から、1 行のコマンドと、手動の手順のコードブロックを取り出す。
python3 -I - "$root/README.md" "$test_dir/oneline.sh" "$test_dir/manual.sh" <<'PY'
import re
import sys

readme, oneline_path, manual_path = sys.argv[1:4]
text = open(readme, encoding="utf-8").read()
blocks = re.findall(r"^[ ]*```bash\n(.*?)^[ ]*```$", text, re.S | re.M)
oneline = [b for b in blocks if b.lstrip().startswith("curl ")]
assert len(oneline) == 1, "1 行のコマンドのブロックが 1 つではありません"
lines = oneline[0].splitlines()
assert len(lines) == 1, "1 行のコマンドが複数の行に分かれています"
assert lines[0].strip() == "curl -fsSL https://github.com/AnD00/multica-squad-kit/releases/latest/download/install.sh | bash", "1 行のコマンドが設計と違います"
assert "bash -s --" in text, "バージョンと拡張の渡し方（bash -s --）が README にありません"
section = text.split("\n## 手動の手順\n", 1)[1].split("\n## ", 1)[0]
manual = re.findall(r"^[ ]*```bash\n(.*?)^[ ]*```$", section, re.S | re.M)
assert len(manual) >= 8, "手動の手順のコードブロックが足りません"
with open(oneline_path, "w", encoding="utf-8") as out:
    out.write(lines[0].strip() + "\n")
with open(manual_path, "w", encoding="utf-8") as out:
    out.write("".join("\n".join(l.strip() for l in b.splitlines()) + "\n" for b in manual))
PY

# スタブの gh は、呼び方を GH_LOG に 1 行で残す。release view は GH_LATEST の最新のタグを出し（GH_LATEST_FAIL で失敗）、
# release download は --pattern のファイルを GH_ASSETS から --dir へ写し、attestation verify は GH_FAIL_ON の名前のファイルだけ失敗する。
mkdir -p "$test_dir/bin"
cat >"$test_dir/bin/gh" <<'STUB'
#!/bin/bash
echo "$*" >>"$GH_LOG"
if [[ ${1:-} == --version ]]; then
	[[ -z ${GH_VERSION_FAIL:-} ]] || exit 1
	printf '%s\n' "$GH_VERSION_OUT"
	exit 0
fi
if [[ ${1:-} == release && ${2:-} == view ]]; then
	[[ -z ${GH_LATEST_FAIL:-} ]] || {
		echo 'stub: no release' >&2
		exit 1
	}
	printf '%s\n' "$GH_LATEST"
	exit 0
fi
if [[ ${1:-} == release && ${2:-} == download ]]; then
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
	if [[ ${3:-} == */"${GH_FAIL_ON:-}" ]]; then
		echo 'stub: attestation failed' >&2
		exit 1
	fi
	exit 0
fi
exit 1
STUB
# スタブの curl は、受けた引数を CURL_LOG に残し、最新の Release の入口の URL だけに、置き場の install.sh を返す。
# CURL_FAIL は HTTP の誤り（-f で本文なしの 22）、CURL_MODE=trunc は最後の閉じ括弧を欠いた入口、cut は main の関数の途中で切れた入口、mid は最後の呼び出しの `main` まででバイトの途中で切れた入口を返す。
cat >"$test_dir/bin/curl" <<'STUB'
#!/bin/bash
echo "$*" >>"$CURL_LOG"
[[ $# -eq 2 && $1 == -fsSL && $2 == "$CURL_URL" ]] || {
	echo "stub: unexpected curl call: $*" >&2
	exit 2
}
[[ -z ${CURL_FAIL:-} ]] || {
	echo 'curl: (22) The requested URL returned error: 404' >&2
	exit 22
}
case ${CURL_MODE:-} in
trunc) sed '$d' "$GH_ASSETS/install.sh" ;;
cut) head -n "$CURL_CUT_LINES" "$GH_ASSETS/install.sh" ;;
mid) { sed '$d' "$GH_ASSETS/install.sh" | sed '$d'; printf '\tmain'; } ;;
*) cat "$GH_ASSETS/install.sh" ;;
esac
STUB
# 引数なしの mktemp -d は、macOS で TMPDIR の下に作らないので、テストの置き場の下に作らせる。
cat >"$test_dir/bin/mktemp" <<'STUB'
#!/bin/bash
[[ $# -eq 1 && $1 == -d ]] || exec "$REAL_MKTEMP" "$@"
exec "$REAL_MKTEMP" -d "$MK_ROOT/d.XXXXXX"
STUB
# 手順の閲覧は、端末のないテストでは中身をそのまま出す。
cat >"$test_dir/bin/less" <<'STUB'
#!/bin/bash
cat "$@"
STUB
chmod +x "$test_dir/bin/gh" "$test_dir/bin/curl" "$test_dir/bin/mktemp" "$test_dir/bin/less"

# 配布物（展開した setup.sh は、受けた引数と流した場所を SETUP_LOG に残すスタブ）。
make_archive() {
	python3 -I - "$1" <<'PY'
import hashlib
import io
import sys
import tarfile

prefix = "multica-squad-kit-v1.6.0/"
version = b"v1.6.0\n"
setup_stub = br"""#!/bin/bash
{
	printf 'args:%s\n' "$*"
	printf 'pwd:%s\n' "$PWD"
} >"$SETUP_LOG"
if [[ -n ${SETUP_READ:-} ]]; then
	read -r answer
	printf 'stdin:%s\n' "$answer" >>"$SETUP_LOG"
fi
exit 0
"""
manifest = ("%s  ./VERSION\n" % hashlib.sha256(version).hexdigest()).encode()
with tarfile.open(sys.argv[1], "w:gz", format=tarfile.PAX_FORMAT) as tar:
    info = tarfile.TarInfo(prefix)
    info.type = tarfile.DIRTYPE
    info.mode = 0o755
    tar.addfile(info)
    for name, data in (("VERSION", version), ("MANIFEST", manifest), ("setup.sh", setup_stub)):
        info = tarfile.TarInfo(prefix + name)
        info.size = len(data)
        info.mode = 0o644
        tar.addfile(info, io.BytesIO(data))
PY
}
sha_of() {
	local out
	out=$(shasum -a 256 "$1")
	printf '%s' "${out%% *}"
}
# new_case <名前>: 置き場（配布物、本物の install.sh、SHA256SUMS）を作る。SHA256SUMS は今の配布物と合う。
new_case() {
	case_dir="$test_dir/$1"
	assets="$case_dir/assets"
	mkdir -p "$assets" "$case_dir/mk"
	make_archive "$assets/$asset"
	cp "$root/install.sh" "$assets/install.sh"
	printf '%s  %s\n%s  install.sh\n' "$(sha_of "$assets/$asset")" "$asset" "$(sha_of "$assets/install.sh")" >"$assets/SHA256SUMS"
}

# run_script <シェル> <コマンドの種類: c か e> <ファイルの中身: 1 つの文字列か、ファイル> : 終了コードを rc に置く。
# 1 行のコマンド（c）は、擬似端末の中で -c で流す。TTY_MODE=notty のときは制御端末のない新しいセッションで流す。
# 擬似端末の入力には、TTY_ANSWERS のファイルの中身を送る（セットアップが端末から読む）。
# 手動の手順（e）は、端末なしで -e のスクリプトで流す（手順は、失敗したらそこで止める）。
# 実行環境の BASH_ENV が PATH の先頭へ本物の gh を戻すことがあるので、外して、スタブを先に選ばせる。
gh_out=$default_gh_out
latest=$version
curl_url=https://github.com/$repo_name/releases/latest/download/install.sh
run_script() {
	local shell=$1 kind=$2 body=$3 flags=() envs
	[[ $shell != zsh ]] || flags=(-f)
	rc=0
	: >"$case_dir/gh.log"
	: >"$case_dir/curl.log"
	rm -f "$case_dir/setup.log"
	rm -rf "$case_dir/mk" && mkdir -p "$case_dir/mk"
	envs=(env -u BASH_ENV PATH="$test_dir/bin:$PATH" TMPDIR="$case_dir/mk" MK_ROOT="$case_dir/mk" REAL_MKTEMP="$real_mktemp"
		GH_LOG="$case_dir/gh.log" GH_ASSETS="$assets" GH_VERSION_OUT="$gh_out" GH_VERSION_FAIL="${GH_VERSION_FAIL:-}"
		GH_LATEST="$latest" GH_LATEST_FAIL="${GH_LATEST_FAIL:-}" GH_FAIL_ON="${GH_FAIL_ON:-}" SETUP_LOG="$case_dir/setup.log" SETUP_READ="${SETUP_READ:-}"
		CURL_LOG="$case_dir/curl.log" CURL_URL="$curl_url" CURL_FAIL="${CURL_FAIL:-}" CURL_MODE="${CURL_MODE:-}" CURL_CUT_LINES="${CURL_CUT_LINES:-}")
	if [[ $kind == c ]]; then
		(cd "$case_dir" && python3 -I "$root/tests/stdin-tty-run.py" "${TTY_MODE:-tty}" /dev/null "${TTY_ANSWERS:-/dev/null}" \
			"$case_dir/out" "$case_dir/err" -- "${envs[@]}" "$shell" ${flags[@]+"${flags[@]}"} -c "$body") || rc=$?
	else
		(cd "$case_dir" && "${envs[@]}" "$shell" ${flags[@]+"${flags[@]}"} -e "$body") >"$case_dir/out" 2>"$case_dir/err" </dev/null || rc=$?
	fi
}
oneline=$(<"$test_dir/oneline.sh")
shells=(bash)
if command -v zsh >/dev/null; then
	shells+=(zsh)
else
	echo 'zsh がないので、zsh のケースを飛ばします（CI では両 OS に zsh がある）'
fi

fail() {
	echo "$*" >&2
	exit 1
}
# calls <接頭辞>: gh の呼び方のうち、接頭辞で始まるものの数。
calls() { grep -c "^$1" "$case_dir/gh.log" || true; }
# normalized_attestations: attestation verify の行から、置き場のパスを外して並べる。
normalized_attestations() {
	sed -n 's|^attestation verify [^ ]*/\([^/ ]*\) |attestation verify \1 |p' "$case_dir/gh.log"
}
specs=" --repo $repo_name --signer-workflow $repo_name/.github/workflows/release-assets.yml --source-ref refs/tags/$version --deny-self-hosted-runners"
not_started() {
	[[ ! -e $case_dir/setup.log ]] || fail "セットアップが流れています"
	! grep -q '取得します' "$case_dir/out" || fail "入口のスクリプトが流れています"
}

# setup_not_run: 証明の失敗のように、取得を始めたあとで止まったときに、セットアップが流れていない。
setup_not_run() { [[ ! -e $case_dir/setup.log ]] || fail "セットアップが流れています"; }

# curl_calls: スタブの curl の呼び方の数。
curl_calls() { grep -c . "$case_dir/curl.log" || true; }
# nothing_ran: 入口が何も取らず、何も流していない（切れた入口と、curl の失敗のとき）。
nothing_ran() {
	[[ ! -s $case_dir/gh.log ]] || fail "gh が呼ばれています: $(<"$case_dir/gh.log")"
	not_started
}
# one_line_args <末尾の引数>: README の 1 行のコマンドの末尾の bash に、bash -s -- のあとの引数を足したもの。
one_line_args() { printf '%s' "${oneline%| bash}| bash -s -- $1"; }

# 1 行のコマンド: curl が最新の Release の入口を取り、入口が最新のバージョンを出して、そのバージョンで取得・確かめ・展開・セットアップを流す。
new_case oneline
for shell in "${shells[@]}"; do
	run_script "$shell" c "$oneline"
	[[ $rc == 0 ]] || fail "$shell: 1 行のコマンドが失敗しました（${rc}）"
	[[ $(<"$case_dir/curl.log") == "-fsSL $curl_url" ]] || fail "$shell: curl の呼び方が違います: $(<"$case_dir/curl.log")"
	[[ $(calls 'release view ') == 1 ]] || fail "$shell: 最新のバージョンの読みが 1 回ではありません"
	[[ $(grep -c '使うバージョン: ' "$case_dir/out") == 1 ]] || fail "$shell: バージョンを 1 回出していません"
	grep -qxF "使うバージョン: $version" "$case_dir/out" || fail "$shell: 読んだバージョンを出していません"
	# バージョンを出してから、取得する。
	[[ $(grep -n '使うバージョン: ' "$case_dir/out" | head -1 | cut -d: -f1) -lt $(grep -n '取得します' "$case_dir/out" | head -1 | cut -d: -f1) ]] || fail "$shell: バージョンを出す前に取得しています"
	# 入口の取得は curl で済んでおり、gh は配布物と SHA256SUMS を 1 回だけ取る。証明は SHA256SUMS、配布物の順に、4 つの指定で確かめる。
	[[ $(calls 'release download ') == 1 ]] || fail "$shell: 取得が 1 回ではありません"
	grep -qx "release download $version --repo $repo_name --pattern $asset --pattern SHA256SUMS --dir .*" "$case_dir/gh.log" || fail "$shell: 配布物の取得が違います"
	[[ $(normalized_attestations | tr '\n' '|') == "attestation verify SHA256SUMS$specs|attestation verify $asset$specs|" ]] || fail "$shell: 証明の確かめが違います"
	[[ $(<"$case_dir/setup.log") == $'args:\n'"pwd:"* ]] || fail "$shell: 展開した setup.sh が引数なしで流れていません"
	[[ -s $case_dir/err ]] && fail "$shell: 標準エラー出力に出ています: $(<"$case_dir/err")"
	cp "$case_dir/setup.log" "$case_dir/setup.log.$shell.oneline"
done
echo "PASS oneline: bash と zsh の擬似端末で、curl が取った入口が最新のバージョンを出し、そのバージョンで取得・確かめ・展開・セットアップが流れる"

# セットアップの質問には、端末から答える（標準入力は入口を流すパイプで、答えはそこから読まれない）。
printf 'yes\n' >"$case_dir/answers"
for shell in "${shells[@]}"; do
	TTY_ANSWERS="$case_dir/answers" SETUP_READ=1 run_script "$shell" c "$oneline"
	[[ $rc == 0 ]] || fail "$shell: 答えを読むセットアップが失敗しました（${rc}）"
	grep -qxF 'stdin:yes' "$case_dir/setup.log" || fail "$shell: セットアップが端末から答えを読めていません"
done
echo 'PASS oneline: セットアップは、端末から答えを読める'

# bash -s -- のあとのバージョンと拡張は、入口へ届く。バージョンを渡したときは最新を読まず、拡張は setup.sh へ渡る。
for shell in "${shells[@]}"; do
	run_script "$shell" c "$(one_line_args "$version")"
	[[ $rc == 0 ]] || fail "$shell: バージョンを渡した 1 行のコマンドが失敗しました（${rc}）"
	[[ $(calls 'release view ') == 0 ]] || fail "$shell: 渡したのに最新を読んでいます"
	grep -qxF "取得します: $version" "$case_dir/out" || fail "$shell: 渡したバージョンで取得していません"
	[[ $(<"$case_dir/setup.log") == $'args:\n'"pwd:"* ]] || fail "$shell: バージョンだけを渡したのに setup.sh へ引数が渡っています"
	run_script "$shell" c "$(one_line_args "--extension /ext/dir")"
	[[ $rc == 0 ]] || fail "$shell: 拡張を渡した 1 行のコマンドが失敗しました（${rc}）"
	[[ $(calls 'release view ') == 1 ]] || fail "$shell: バージョンを省いたのに最新を 1 回読んでいません"
	grep -q '^args:--extension /ext/dir$' "$case_dir/setup.log" || fail "$shell: 拡張のディレクトリが setup.sh へ渡っていません"
	cp "$case_dir/setup.log" "$case_dir/setup.log.$shell.oneline-ext"
	run_script "$shell" c "$(one_line_args "$version --extension /ext/dir")"
	[[ $rc == 0 ]] || fail "$shell: バージョンと拡張を渡した 1 行のコマンドが失敗しました（${rc}）"
	[[ $(calls 'release view ') == 0 ]] || fail "$shell: バージョンを渡したのに最新を読んでいます"
	cmp "$case_dir/setup.log" "$case_dir/setup.log.$shell.oneline-ext" || fail "$shell: バージョンを足しても setup.sh の流れ方が変わっています"
done
echo 'PASS oneline: bash -s -- のあとのバージョンと拡張が届く（バージョンを渡せば最新を読まず、拡張は setup.sh へ渡る）'

# 入口が途中で切れたとき（最後の呼び出しの閉じ括弧が欠けた、関数の途中で切れた）は、何も取らず、何も流さない。curl の失敗も、何も流さない。
main_line=$(grep -n '^main() {' "$root/install.sh" | cut -d: -f1)
for shell in "${shells[@]}"; do
	CURL_MODE=trunc run_script "$shell" c "$oneline"
	[[ $rc != 0 ]] || fail "$shell: 閉じ括弧が欠けた入口が通りました"
	nothing_ran
	[[ ! -s $case_dir/out ]] || fail "$shell: 閉じ括弧が欠けた入口が何かを出しています"
	CURL_MODE=cut CURL_CUT_LINES=$((main_line + 3)) run_script "$shell" c "$oneline"
	[[ $rc != 0 ]] || fail "$shell: 関数の途中で切れた入口が通りました"
	nothing_ran
	# 最後の呼び出しの行の途中で切れても、指定したバージョンや拡張が失われて最新版へ進まない。
	CURL_MODE=mid run_script "$shell" c "$(one_line_args "$version --extension /ext/dir")"
	[[ $rc != 0 ]] || fail "$shell: 最後の行の途中で切れた入口が通りました"
	nothing_ran
	CURL_FAIL=1 run_script "$shell" c "$oneline"
	[[ $(curl_calls) == 1 ]] || fail "$shell: curl が 1 回呼ばれていません"
	grep -qF 'curl: (22)' "$case_dir/err" || fail "$shell: curl の失敗が出ていません"
	nothing_ran
done
echo 'PASS oneline: 切れた入口と curl の失敗は、何も取らず、何も流さない'

# 端末を使えないとき（端末のない CI など）は、取得の前に止まり、ファイルに取ってから流すことを出す。
for shell in "${shells[@]}"; do
	TTY_MODE=notty run_script "$shell" c "$oneline"
	[[ $rc == 1 ]] || fail "$shell: 端末がないときの終了コードが 1 ではありません（${rc}）"
	grep -qF '端末（/dev/tty）を開けません' "$case_dir/err" || fail "$shell: 端末がないことを出していません"
	grep -qF 'bash install.sh' "$case_dir/err" || fail "$shell: ファイルに取ってから流すことを出していません"
	[[ $(calls 'release ') == 0 && $(calls 'attestation ') == 0 ]] || fail "$shell: 端末がないのに取得か確かめに進んでいます"
	not_started
done
echo 'PASS oneline: 端末がないときは、取得の前に止まる'

# gh のバージョン: 2.102.0 以上を数として比べ、足りない・読めないときは、必要なバージョンを出して、何も取らずに止まる。
for shell in "${shells[@]}"; do
	for ok_out in 'gh version 2.102.0' 'gh version 2.103.0 (2026-02-01)' 'gh version 3.0.0' 'gh version 10.0.0'; do
		gh_out=$ok_out run_script "$shell" c "$oneline"
		[[ $rc == 0 ]] || fail "$shell: 通るはずが止まりました: $ok_out"
	done
	for old_out in 'gh version 2.101.9' 'gh version 2.99.0' 'gh version 1.999.0' '' 'unknown' 'gh version dev'; do
		gh_out=$old_out run_script "$shell" c "$oneline"
		[[ $rc != 0 ]] || fail "$shell: 止まるはずが通りました: $old_out"
		grep -qF '2.102.0 以上' "$case_dir/err" || fail "$shell: 必要なバージョンを出していません: $old_out"
		[[ $(calls 'release ') == 0 && $(calls 'attestation ') == 0 ]] || fail "$shell: 古い gh で取得か確かめに進んでいます: $old_out"
		not_started
	done
	GH_VERSION_FAIL=1 run_script "$shell" c "$oneline"
	[[ $rc != 0 ]] || fail "$shell: gh --version が失敗したのに通りました"
	grep -qF '2.102.0 以上' "$case_dir/err" || fail "$shell: gh --version の失敗で必要なバージョンを出していません"
	not_started
done
echo 'PASS oneline: gh が 2.102.0 より古いか読めないときは、必要なバージョンを出して、取得も確かめも流さない'

# 失敗したらその先を流さない: 最新を読めない・形が違う、SHA256SUMS か配布物の証明が通らない。
for shell in "${shells[@]}"; do
	GH_LATEST_FAIL=1 run_script "$shell" c "$oneline"
	[[ $rc != 0 ]] || fail "$shell: 最新を読めないのに通りました"
	[[ $(calls 'release download ') == 0 ]] || fail "$shell: バージョンが決まらないのに取得しています"
	not_started
	latest='' run_script "$shell" c "$oneline"
	[[ $rc != 0 ]] || fail "$shell: バージョンが空なのに通りました"
	[[ $(calls 'release download ') == 0 ]] || fail "$shell: バージョンが空なのに取得しています"
	not_started
	GH_FAIL_ON=SHA256SUMS run_script "$shell" c "$oneline"
	[[ $rc != 0 ]] || fail "$shell: SHA256SUMS の証明が通らないのに通りました"
	grep -qF 'stub: attestation failed' "$case_dir/err" || fail "$shell: 証明の失敗が出ていません"
	[[ $(calls 'attestation ') == 1 ]] || fail "$shell: SHA256SUMS の証明の失敗のあとに進んでいます"
	setup_not_run
	GH_FAIL_ON=$asset run_script "$shell" c "$oneline"
	[[ $rc != 0 ]] || fail "$shell: 配布物の証明が通らないのに通りました"
	grep -qF "証明を確かめられませんでした: $asset" "$case_dir/err" || fail "$shell: 配布物の証明の失敗が出ていません"
	setup_not_run
done
echo 'PASS oneline: 最新を読めない・証明が通らないときは、その先（展開とセットアップ）を流さない'

# 手動の手順: 同じシェルで順に流すと、取り直しがなく、1 行のコマンドと同じ確かめをして、同じ setup.sh が同じ引数で流れる。
manual_ext="$test_dir/manual-ext.sh"
sed '$ s|$| --extension /ext/dir|' "$test_dir/manual.sh" >"$manual_ext"
for shell in "${shells[@]}"; do
	run_script "$shell" e "$test_dir/manual.sh"
	[[ $rc == 0 ]] || fail "$shell: 手動の手順が失敗しました（${rc}）"
	[[ $(calls 'release download ') == 1 ]] || fail "$shell: 手動の手順で取得が 1 回ではありません（取り直しています）"
	grep -qx "release download $version --repo $repo_name --pattern $asset --pattern SHA256SUMS --dir .*" "$case_dir/gh.log" || fail "$shell: 手動の手順の取得が違います"
	[[ $(normalized_attestations | tr '\n' '|') == "attestation verify SHA256SUMS$specs|attestation verify $asset$specs|" ]] || fail "$shell: 手動の手順の証明の確かめが違います"
	grep -qxF "使うバージョン: $version" "$case_dir/out" || fail "$shell: 手動の手順がバージョンを出していません"
	grep -qxF "$asset: OK" "$case_dir/out" || fail "$shell: 手動の手順のチェックサムの照合が通っていません"
	grep -q " multica-squad-kit-$version/\$" "$case_dir/out" || fail "$shell: 一覧を出していません"
	grep -qF 'exit 0' "$case_dir/out" || fail "$shell: 展開した setup.sh を読んでいません"
	# 1 行のコマンドと同じ setup.sh が、同じ引数と同じ場所から流れる。
	cmp "$case_dir/setup.log" "$case_dir/setup.log.$shell.oneline" || fail "$shell: 1 行のコマンドと setup.sh の流れ方が違います"
	[[ -s $case_dir/err ]] && fail "$shell: 標準エラー出力に出ています: $(<"$case_dir/err")"
	run_script "$shell" e "$manual_ext"
	[[ $rc == 0 ]] || fail "$shell: 拡張を足した手動の手順が失敗しました（${rc}）"
	cmp "$case_dir/setup.log" "$case_dir/setup.log.$shell.oneline-ext" || fail "$shell: 拡張を渡した 1 行のコマンドと setup.sh の流れ方が違います"
done
echo 'PASS manual: bash と zsh で、手動の手順は取り直さず、1 行のコマンドと同じ確かめをして、同じ setup.sh を同じ引数で流す'

# 手動の手順は、確かめが通らなければそこで止まり、展開も実行もしない。
for shell in "${shells[@]}"; do
	GH_FAIL_ON=SHA256SUMS run_script "$shell" e "$test_dir/manual.sh"
	[[ $rc != 0 ]] || fail "$shell: SHA256SUMS の証明が通らないのに手動の手順が通りました"
	[[ $(calls 'attestation ') == 1 ]] || fail "$shell: SHA256SUMS の証明の失敗のあとに進んでいます"
	[[ ! -e $case_dir/setup.log ]] || fail "$shell: セットアップが流れています"
	GH_FAIL_ON=$asset run_script "$shell" e "$test_dir/manual.sh"
	[[ $rc != 0 ]] || fail "$shell: 配布物の証明が通らないのに手動の手順が通りました"
	[[ ! -e $case_dir/setup.log ]] || fail "$shell: セットアップが流れています"
done
cp "$assets/SHA256SUMS" "$assets/SHA256SUMS.saved"
printf '%064d  %s\n' 0 "$asset" >"$assets/SHA256SUMS"
for shell in "${shells[@]}"; do
	run_script "$shell" e "$test_dir/manual.sh"
	[[ $rc != 0 ]] || fail "$shell: チェックサムが合わないのに手動の手順が通りました"
	[[ ! -e $case_dir/setup.log ]] || fail "$shell: セットアップが流れています"
	[[ $(calls 'release download ') == 1 ]] || fail "$shell: 取り直しています"
done
mv "$assets/SHA256SUMS.saved" "$assets/SHA256SUMS"
echo 'PASS manual: 証明かチェックサムが通らないときは、そこで止まり、展開もセットアップも流さない'
