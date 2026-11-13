#!/usr/bin/env bash
# .github/workflows/release-assets.yml と check.yml の配布物の検査の決まりを、読んで確認する。
# ワークフローそのものは手元で動かせないので、きっかけ、権限、固定したバージョン、実行場所の決まりだけを見る。
# 設計は docs/release.md の「発行のワークフロー」と「テストと CI」。YAML のパーサは使わず、行を読む。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/release-workflow.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
workflow=${RELEASE_WORKFLOW_FILE:-$root/.github/workflows/release-assets.yml}

# section <キー> <字下げの深さ>: そのキーの行の下にある、より深い字下げの行を出す。
section() {
	awk -v key="$1" -v indent="$2" '
		BEGIN { pad = sprintf("%" indent "s", "") }
		found && $0 !~ /^[ ]*$/ {
			match($0, /^ */)
			if (RLENGTH <= indent) found = 0
		}
		found { print }
		$0 == pad key { found = 1 }
	' "$workflow"
}
fail() {
	echo "${workflow##*/}: $*" >&2
	exit 1
}

[[ -f $workflow ]] || fail 'ファイルがありません'

# きっかけは workflow_dispatch だけ。
on_lines=$(section 'on:' 0)
[[ $(printf '%s\n' "$on_lines" | grep -c .) == 1 && $(printf '%s\n' "$on_lines" | head -1) == '  workflow_dispatch:' ]] ||
	fail "きっかけが workflow_dispatch だけではありません: $on_lines"

# 全体の権限は {}。ジョブの権限は、決めた 3 つだけ。
[[ $(grep -c '^permissions:' "$workflow") == 1 ]] || fail '全体の permissions が 1 つではありません'
grep -qx 'permissions: {}' "$workflow" || fail '全体の権限が {} ではありません'
job_permissions=$(section 'permissions:' 4 | sed 's/^ *//' | LC_ALL=C sort | tr '\n' ' ')
[[ $job_permissions == 'attestations: write contents: write id-token: write ' ]] ||
	fail "ジョブの権限が決めたものと違います: $job_permissions"
[[ $(grep -c '^ *permissions:' "$workflow") == 2 ]] || fail 'permissions が全体とジョブの 2 つだけではありません'

# ジョブは 1 つ。動かす場所は GitHub の用意した ubuntu-24.04。
[[ $(section 'jobs:' 0 | grep -c '^  [A-Za-z0-9_-]*:$') == 1 ]] || fail 'ジョブが 1 つではありません'
[[ $(grep -c 'runs-on:' "$workflow") == 1 ]] || fail 'runs-on が 1 つではありません'
grep -qx '    runs-on: ubuntu-24.04' "$workflow" || fail 'runs-on が ubuntu-24.04 ではありません'

# uses はすべて 40 桁の SHA で固定し、バージョンを注記する。
uses_count=$(grep -c 'uses:' "$workflow")
[[ $uses_count -ge 1 ]] || fail 'uses がありません'
[[ $(grep 'uses:' "$workflow" | grep -c -E 'uses: [A-Za-z0-9._/-]+@[0-9a-f]{40} # v[0-9]+\.[0-9]+\.[0-9]+$') == "$uses_count" ]] ||
	fail "uses が、40 桁の SHA と # vX.Y.Z の注記になっていません: $(grep 'uses:' "$workflow")"

# checkout は、認証情報を残さない。
grep -q 'persist-credentials: false' "$workflow" || fail 'persist-credentials: false がありません'
[[ $(grep -c 'persist-credentials:' "$workflow") == "$(grep -c 'uses: actions/checkout@' "$workflow")" ]] ||
	fail 'checkout の数と persist-credentials の数が合いません'

# 上書きの --clobber を使わない。
if grep -q -e '--clobber' "$workflow"; then fail '--clobber を使っています'; fi

# run の中に ${{ }} を書かない。値は env で渡し、シェルの文に展開しない。
if awk '
	/^ *run: / { if ($0 ~ /\$\{\{/) bad = 1 }
	/^ *run: [|>]/ { match($0, /^ */); indent = RLENGTH; inrun = 1; next }
	inrun {
		match($0, /^ */)
		if ($0 !~ /^[ ]*$/ && RLENGTH <= indent) inrun = 0
		else if ($0 ~ /\$\{\{/) bad = 1
	}
	END { exit bad ? 0 : 1 }
' "$workflow"; then
	fail 'run の中に ${{ }} があります'
fi

# 配布物の作成はスクリプトに任せる。ワークフローに処理を書かない。
grep -q 'bash scripts/build-assets.sh' "$workflow" || fail 'scripts/build-assets.sh を呼んでいません'

# PR の CI は、発行と同じ OS とスクリプトで、PR の head の木を検証する。
check_assets_job() {
	local workflow=${CHECK_WORKFLOW_FILE:-$root/.github/workflows/check.yml} assets_lines permissions_lines
	[[ -f $workflow ]] || fail 'ファイルがありません'
	assets_lines=$(section 'assets:' 2)
	[[ -n $assets_lines ]] || fail 'assets のジョブがありません'
	printf '%s\n' "$assets_lines" | grep -qxF '    runs-on: ubuntu-24.04' || fail 'assets が ubuntu-24.04 ではありません'
	printf '%s\n' "$assets_lines" | grep -qxF '    timeout-minutes: 10' || fail 'assets の時間の上限が 10 分ではありません'
	printf '%s\n' "$assets_lines" | grep -qxF '          ref: ${{ github.event.pull_request.head.sha || github.sha }}' || fail 'assets が PR の head を取り出していません'
	printf '%s\n' "$assets_lines" | grep -qxF '          persist-credentials: false' || fail 'assets の checkout に認証情報が残ります'
	printf '%s\n' "$assets_lines" | grep -qxF '        run: bash scripts/build-assets.sh --commit HEAD "$RUNNER_TEMP/assets"' || fail 'assets が --commit HEAD で配布物を検証していません'
	permissions_lines=$(section 'permissions:' 0)
	[[ $permissions_lines == '  contents: read' ]] || fail '全体の権限が contents: read だけではありません'
	if printf '%s\n' "$assets_lines" | grep -q 'permissions:'; then fail 'assets に権限を追加しています'; fi
}
check_assets_job

# この検査自身が、決まりを破る定義を見つけられることを、壊した写しで確認する。
if [[ -z ${RELEASE_WORKFLOW_FILE:-} ]]; then
	mutate() {
		local name=$1 from=$2 to=$3
		python3 -I - "$workflow" "$test_dir/$name.yml" "$from" "$to" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
text = open(src, encoding="utf-8").read()
if old not in text:
    raise SystemExit("mutation target not found: " + old)
open(dst, "w", encoding="utf-8").write(text.replace(old, new, 1))
PY
		if RELEASE_WORKFLOW_FILE="$test_dir/$name.yml" bash "$root/tests/release-workflow-test.sh" >/dev/null 2>&1; then
			fail "決まりを破る定義を通しました: $name"
		fi
	}
	mutate trigger 'workflow_dispatch:' $'workflow_dispatch:\n  push:'
	mutate global-permissions 'permissions: {}' $'permissions:\n  contents: read'
	mutate job-permissions '      attestations: write' $'      attestations: write\n      packages: write'
	mutate runner 'runs-on: ubuntu-24.04' 'runs-on: ubuntu-latest'
	mutate pin-tag '@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1' '@v7'
	mutate pin-short '@4d101475d8b20a2381f78447822ac1eab6504dd8 # v4.2.2' '@4d10147 # v4.2.2'
	mutate pin-note '@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1' '@3d3c42e5aac5ba805825da76410c181273ba90b1'
	mutate credentials 'persist-credentials: false' 'persist-credentials: true'
	mutate clobber '"$REPO" \' '"$REPO" --clobber \'
	mutate expression 'run: bash scripts/build-assets.sh "$TAG"' 'run: bash scripts/build-assets.sh ${{ steps.guard.outputs.tag }}'
fi

# CI の検証も、壊した写しを拒むことを確認する。
if [[ -z ${RELEASE_WORKFLOW_FILE:-} && -z ${CHECK_WORKFLOW_FILE:-} ]]; then
	mutate_check() {
		local name=$1 from=$2 to=$3
		python3 -I - "$root/.github/workflows/check.yml" "$test_dir/check-$name.yml" "$from" "$to" <<'PY'
import sys
from pathlib import Path
src, dst, old, new = sys.argv[1:5]
text = Path(src).read_text(encoding="utf-8")
if old not in text:
    raise SystemExit("mutation target not found: " + old)
Path(dst).write_text(text.replace(old, new, 1), encoding="utf-8")
PY
		if CHECK_WORKFLOW_FILE="$test_dir/check-$name.yml" bash "$root/tests/release-workflow-test.sh" >"$test_dir/check-$name.log" 2>&1; then
			echo "check.yml の誤りを見つけられませんでした: $name" >&2
			exit 1
		fi
	}
	mutate_check missing '  assets:' '  other-assets:'
	mutate_check os '    runs-on: ubuntu-24.04' '    runs-on: ubuntu-latest'
	mutate_check timeout '  assets:
    timeout-minutes: 10' '  assets:
    timeout-minutes: 11'
	mutate_check ref '${{ github.event.pull_request.head.sha || github.sha }}' '${{ github.sha }}'
	mutate_check credentials '          ref: ${{ github.event.pull_request.head.sha || github.sha }}
          persist-credentials: false' '          ref: ${{ github.event.pull_request.head.sha || github.sha }}
          persist-credentials: true'
	mutate_check build '--commit HEAD "$RUNNER_TEMP/assets"' 'HEAD "$RUNNER_TEMP/assets"'
	mutate_check permissions '  contents: read' '  contents: write'
fi
echo 'PASS release-workflow: きっかけは workflow_dispatch だけ、権限は全体が {} でジョブが決めた 3 つ、uses は SHA で固定、runs-on は ubuntu-24.04、persist-credentials: false、--clobber なし、run に式なしを確認した'
echo 'PASS assets-workflow: PR の head を ubuntu-24.04 で取り出し、認証を残さず、10 分の上限と contents: read の権限で --commit HEAD の配布物を検証する'
