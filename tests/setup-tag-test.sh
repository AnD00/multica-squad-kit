#!/usr/bin/env bash
# clone した原本は最新のリリースのタグを取り出して流し直し、ZIP の原本と --no-checkout は今の版のまま流すことを確かめる。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/setup-tag-test.XXXXXX")
exec 8>&2
trap 'test_exit=$?; if [[ $test_exit != 0 && -f $test_dir/err ]]; then cat "$test_dir/out" "$test_dir/err" >&8; fi; rm -rf -- "$test_dir"' EXIT
g() { git -c user.name=test -c user.email=test@example.test -c init.defaultBranch=main -c advice.detachedHead=false "$@"; }

# タグの版の setup.sh は、受け取った印と引数を出すだけの偽物にする。main の setup.sh は本物にする。
work=$test_dir/work
origin=$test_dir/origin.git
g init -q "$work"
stub_release() {
	printf '#!/usr/bin/env bash\nprintf "STUB %s|%%s|%%s\\n" "${SQUAD_KIT_TAG_CHECKED_OUT-unset}" "$*"\n' "$1" >"$work/setup.sh"
	g -C "$work" add -A
	g -C "$work" commit -q -m "$1"
	g -C "$work" tag "$1"
}
stub_release v1.2.0
stub_release v1.10.0
stub_release v2.0.0-rc.1
cp "$root/setup.sh" "$work/setup.sh"
printf 'payload\n' >"$work/payload.txt"
g -C "$work" add -A
g -C "$work" commit -q -m main
g clone -q --bare "$work" "$origin"
# ホストの push の関所は、この一時リポジトリへの push の間だけ外す。
push_tag() (
	unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
	g -C "$work" push -q "$origin" "refs/tags/$1"
)
fresh() { rm -rf -- "$test_dir/kit"; g clone -q "$origin" "$test_dir/kit"; }
run() { (cd "$test_dir" && /bin/bash "$test_dir/kit/setup.sh" "$@" </dev/null >"$test_dir/out" 2>"$test_dir/err"); }
head_is() { [[ $(git -C "$test_dir/kit" rev-parse HEAD) == $(git -C "$test_dir/kit" rev-parse "$1^{commit}") ]]; }
mkdir -p "$test_dir/ext"

fresh
# clone のあとに出たリリースも、流したときに取ってくる。main は動かさない。
g -C "$work" checkout -q --detach main
stub_release v1.11.0
g -C "$work" checkout -q main
push_tag v1.11.0
run --extension ext
grep -qxF "STUB v1.11.0|v1.11.0|--extension $test_dir/ext" "$test_dir/out"
grep -qF '最新のタグ v1.11.0 を取り出しました' "$test_dir/err"
head_is v1.11.0
echo 'PASS setup-tag: main で流すと、origin の最新のリリースのタグを取り出し、拡張の絶対パスだけを渡して流し直す'

fresh
if run --no-checkout; then exit 1; fi
grep -qF 'MANIFEST がありません' "$test_dir/err"
! grep -qF '取り出しました' "$test_dir/err"
head_is main
echo 'PASS setup-tag: --no-checkout では取り出さず、今の版のまま検査に進む'

fresh
if SQUAD_KIT_TAG_CHECKED_OUT=v1.11.0 run; then exit 1; fi
grep -qF 'MANIFEST がありません' "$test_dir/err"
head_is main
echo 'PASS setup-tag: 流し直した側では、もう一度取り出さない'

fresh
printf 'changed\n' >>"$test_dir/kit/payload.txt"
if run; then exit 1; fi
grep -qF '未コミットの変更がある' "$test_dir/err"
grep -qF -- '--no-checkout' "$test_dir/err"
head_is main
grep -qxF changed "$test_dir/kit/payload.txt"
echo 'PASS setup-tag: 未コミットの変更があると、取り出さずに止まる'

fresh
g -C "$test_dir/kit" remote set-url origin "$test_dir/missing.git"
if run; then exit 1; fi
grep -qF 'origin からタグを取れません' "$test_dir/err"
head_is main
echo 'PASS setup-tag: origin からタグを取れないと、取り出さずに止まる'

fresh
rm -rf -- "$test_dir/kit/.git"
if run; then exit 1; fi
grep -qF 'MANIFEST がありません' "$test_dir/err"
! grep -qF '取り出しました' "$test_dir/err"
echo 'PASS setup-tag: .git のない原本（ZIP）は、展開した版のまま検査に進む'

g -C "$work" tag v1.12.0 main
push_tag v1.12.0
fresh
if run; then exit 1; fi
grep -qF 'MANIFEST がありません' "$test_dir/err"
! grep -qF '取り出しました' "$test_dir/err"
head_is main
echo 'PASS setup-tag: 最新のタグと同じコミットなら、取り出さずにそのまま流す'

if run --no-checkout --no-checkout; then exit 1; fi
grep -qF '使い方: bash setup.sh [--extension <拡張のディレクトリ>] [--no-checkout]' "$test_dir/err"
echo 'PASS setup-tag: 重なった --no-checkout は使い方を出して止まる'
