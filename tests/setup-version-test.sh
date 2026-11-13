#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/setup-fixture.sh"
manifest
base_input yes
gh_args='api repos/AnD00/multica-squad-kit/releases/latest --jq .tag_name'
running=$(cat "$test_dir/package/VERSION")
record=$TEMPLATE_AGENT_HOME/template/version
# 1 回流して、導入済みのバージョンの記録と、知らせの出力を調べる前の状態に戻す。
fresh() { rm -rf "$test_dir/state" "$test_dir/host-home" "$test_dir/gh-calls"; : >"$test_dir/gh-calls"; }
seed() { mkdir -p "$(dirname "$record")"; printf '%s\n' "$1" >"$record"; }
calls() { wc -l <"$test_dir/gh-calls" | tr -d ' '; }
export TEST_GH_CALLS="$test_dir/gh-calls"

# バージョンの比べ方は、数として X・Y・Z を順に比べる。
root=$test_dir/package
source "$root/lib/ui.sh"
source "$root/lib/version.sh"
newer() { version_newer "$1" "$2"; }
newer v1.10.0 v1.9.0
newer v2.0.0 v1.99.99
newer v1.2.10 v1.2.9
newer v1.3.0 v1.2.99
! newer v1.8.0 v1.8.0
! newer v1.9.0 v1.10.0
! newer v1.2.9 v1.2.10
version_valid v1.8.0
for bad in '' latest v1.8 1.8.0 v1.8.0-rc1 v1.8.0.1 'v1.8.0 ' vx.y.z; do ! version_valid "$bad"; done
echo 'PASS version-notice: バージョンは X・Y・Z を数として順に比べ、vX.Y.Z の形だけを受ける'

# 記録がなく、最新が今流しているバージョンと同じとき: 何も出さず、最後に記録を書く。
fresh
run
[[ $(calls) == 1 ]]
[[ $(cat "$test_dir/gh-calls") == "$gh_args" ]]
! grep -q '警告' "$test_dir/err"
! grep -q '更新します' "$test_dir/out" "$test_dir/err"
[[ $(cat "$record") == "$running" ]]
echo 'PASS version-notice: 記録がなく最新と同じなら何も出さず、終わったあとに記録を書く'

# 記録が古く、最新が今流しているバージョンと同じとき: 印なしで、この実行で更新することを標準出力へ。
fresh
seed v1.0.0
run
grep -qF "導入済みのバージョンは v1.0.0 です。この実行で最新のバージョン $running に更新します。" "$test_dir/out"
! grep -q '警告' "$test_dir/err"
[[ $(cat "$record") == "$running" ]]
echo 'PASS version-notice: 最新が導入済みより新しく今流しているものと同じなら、更新することを印なしで出す'

# 最新が今流しているバージョンよりも新しいとき: 警告で README の更新の手順を示し、流している分は続ける。
# 新しいと見なす値は、今流しているバージョンから作る（バージョンを上げても固定の値が古くならないように）。
IFS=. read -r run_major run_minor run_patch <<<"${running#v}"
for latest in "v$((run_major + 1)).0.0" "v$run_major.$((run_minor + 1)).0" "v$run_major.$run_minor.$((run_patch + 1))" "v$run_major.$((run_minor + 10)).0"; do
	fresh
	seed v1.0.0
	TEST_LATEST_TAG=$latest run
	grep -qF "警告: 新しいバージョン $latest があります。" "$test_dir/err"
	grep -qF 'README の更新の手順' "$test_dir/err"
	! grep -q '更新します' "$test_dir/out" "$test_dir/err"
	grep -qF '✔ 共通のラベルとスキル' "$test_dir/err"
	[[ $(cat "$record") == "$running" ]]
done
echo 'PASS version-notice: 最新が今流しているものより新しければ警告で更新の手順を示し、流すのは続ける'

# 記録がなければ今流しているバージョンを導入済みとみなす。最新が新しければ警告、同じか古ければ何も出さない。
fresh
TEST_LATEST_TAG=v9.0.0 run
grep -qF '警告: 新しいバージョン v9.0.0 があります。' "$test_dir/err"
for latest in "$running" v0.1.0; do
	fresh
	TEST_LATEST_TAG=$latest run
	! grep -q '警告' "$test_dir/err"
	! grep -q '更新します' "$test_dir/out" "$test_dir/err"
done
echo 'PASS version-notice: 記録がないときは、今流しているバージョンを導入済みとみなす'

# 導入済みのバージョンと同じか古いとき: 何も出さない。
for installed_latest in "$running $running" "$running v1.0.0" "v9.0.0 v9.0.0" "v9.0.0 $running"; do
	set -- $installed_latest
	fresh
	seed "$1"
	TEST_LATEST_TAG=$2 run
	! grep -q '警告' "$test_dir/err"
	! grep -q '更新します' "$test_dir/out" "$test_dir/err"
done
echo 'PASS version-notice: 最新が導入済みと同じか古いときは何も出さない'

# 読めないとき（失敗、空、形の誤り）: 警告を出して、導入は続ける。
fresh
TEST_LATEST_FAIL=yes run
grep -qF '警告: 最新のバージョンを確認できませんでした。導入は続けます。' "$test_dir/err"
grep -qF '✔ 共通のラベルとスキル' "$test_dir/err"
[[ $(cat "$record") == "$running" ]]
for bad in '' latest v1.9 1.9.0 v1.9.0-rc1 v1.9.0.1 'not a tag'; do
	fresh
	TEST_LATEST_TAG=$bad run
	grep -qF '警告: 最新のバージョンを確認できませんでした。導入は続けます。' "$test_dir/err"
	grep -qF '✔ 共通のラベルとスキル' "$test_dir/err"
	! grep -q '新しいバージョン' "$test_dir/err"
done
echo 'PASS version-notice: 読めない・形の誤りの最新は警告にし、導入は続ける'

# 知らせは、道具とログインの確認のあと、質問の前に出る。ログインできなければ、読みに行かない。
fresh
TEST_LATEST_FAIL=yes run
warn_line=$(grep -n '最新のバージョンを確認できませんでした' "$test_dir/err" | head -n 1 | cut -d: -f1)
ask_line=$(grep -n 'プロジェクト' "$test_dir/err" | head -n 1 | cut -d: -f1)
[[ -n $warn_line && -n $ask_line && $warn_line -lt $ask_line ]]
fresh
TEST_LOGIN=no deny
[[ $(calls) == 0 ]]
[[ ! -e $record ]]
echo 'PASS version-notice: 知らせはログインの確認のあと、質問の前に出て、ログイン前は読まない'

# 途中で止まったときは記録を書かず、前の記録を残す。
fresh
seed v1.0.0
TEST_SAVE_FAIL=yes deny
[[ $(calls) == 1 ]]
[[ $(cat "$record") == v1.0.0 ]]
fresh
TEST_SAVE_FAIL=yes deny
[[ ! -e $record ]]
fresh
printf '1\nOther project\nnext\n1\nmembera\n0\n1\n0\n\nno\n' >"$test_dir/input"
deny
[[ ! -e $record ]]
base_input yes
echo 'PASS version-notice: 保存の失敗やキャンセルで止まったときは記録を書かず、前の記録を残す'

# 記録を書けなくても、終わったセットアップは失敗にしない。
fresh
mkdir -p "$test_dir/host-home"
: >"$test_dir/host-home/template"
# macOS の UTF-8 ロケールでは、波括弧のない変数が句点に接すると、長い変数名として読まれて異常終了する。
LC_ALL=en_US.UTF-8 run
grep -qF '導入済みのバージョンを記録できませんでした' "$test_dir/err"
grep -qF '/template/version。セットアップ自体は終わっています。' "$test_dir/err"
grep -qF TEST-project-prepared "$test_dir/out"
[[ -f $test_dir/host-home/template && ! -e $record ]]
echo 'PASS version-notice: 記録を書けなくても警告にとどめ、終わったセットアップは失敗にしない'

# 壊れた記録は、記録がないときと同じに扱う。
fresh
seed 'garbage'
TEST_LATEST_TAG=v9.0.0 run
grep -qF '警告: 新しいバージョン v9.0.0 があります。' "$test_dir/err"
[[ $(cat "$record") == "$running" ]]
echo 'PASS version-notice: 壊れた記録は記録がないときと同じに扱い、終わったあとに書き直す'

# 変数の直後に日本語の文字が続く形は、macOS の UTF-8 ロケールで変数名の一部と読まれる。配る原本のスクリプトには残さない。
python3 -I - "$(cd "$(dirname "$0")/.." && pwd)" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
files = [root / "setup.sh", root / "install.sh"]
files += sorted((root / "lib").glob("*.sh")) + sorted((root / "scripts").glob("*.sh")) + sorted((root / "vm").glob("*.sh"))
pattern = re.compile(r"\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7f]")
bad = []
for f in files:
    if not f.is_file():
        continue
    for n, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
        if not line.lstrip().startswith("#") and pattern.search(line):
            bad.append(f"{f.relative_to(root)}:{n}")
if bad:
    sys.exit("変数の直後に日本語の文字が続いています（${変数} で区切る）: " + ", ".join(bad))
PY
echo 'PASS version-notice: 変数の直後に日本語の文字が続く形が、配るスクリプトに残っていない'
