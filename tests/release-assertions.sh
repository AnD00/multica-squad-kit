#!/usr/bin/env bash
# scripts/release.sh の動きを、一時の Git のリポジトリとスタブの gh で確かめる。
# origin は一時の bare のリポジトリで、本物の GitHub には push せず、Release もワークフローの実行も作らない。
# 設計は docs/release.md の「テストと CI」。スタブの gh は、Release の一覧を JSON の状態として持ち、
# release create、run watch、release edit で状態を動かす。配布物は、スタブが scripts/build-assets.sh をタグに流して作る。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/release.XXXXXX")
# 標準エラーを err に向けたまま止まっても、trap が err 自身へ書き足し続けないよう、元の標準エラーを控えて出す。
exec 8>&2
trap 'test_exit=$?; if [[ $test_exit != 0 ]]; then for log in "$test_dir"/*/out "$test_dir"/*/err "$test_dir"/*/gh.log; do [[ -f $log ]] && { echo "--- $log" >&8; cat "$log" >&8; }; done; fi; rm -rf -- "$test_dir"' EXIT
source "$root/tests/release-test-lib.sh"

printf 'y\n' >"$test_dir/answer-y"
printf 'n\n' >"$test_dir/answer-n"
printf '\n' >"$test_dir/answer-empty"
: >"$test_dir/answer-eof"
printf 'yes\n' >"$test_dir/answer-yes"

# gh の呼び方の記録（gh.log）を読む道具。
log_count() { grep -c -- "$1" "$case_dir/gh.log" || true; }
# log_has / log_lacks <正規表現>: 呼ばれた / 呼ばれていない。
log_has() { [[ -f $case_dir/gh.log ]] && grep -q -- "$1" "$case_dir/gh.log"; }
log_lacks() { [[ ! -f $case_dir/gh.log ]] || ! grep -q -- "$1" "$case_dir/gh.log"; }
# before_in_log <先の正規表現> <後の正規表現>: 先の最初の呼び出しが、後の最初の呼び出しより前にある。
before_in_log() {
	local a b
	a=$(grep -n -m1 -- "$1" "$case_dir/gh.log" | cut -d: -f1 || true)
	b=$(grep -n -m1 -- "$2" "$case_dir/gh.log" | cut -d: -f1 || true)
	[[ -n $a && -n $b && $a -lt $b ]]
}
# no_write: GitHub に書く gh の呼び出し（Release の作成・公開・削除、ワークフローの実行）がない。
no_write() { log_lacks '^release \(create\|edit\|delete\|upload\)\|^workflow run\|^api -X\|^api --method'; }
# no_download: 配布物を取得していない。
no_download() { log_lacks 'releases/assets/'; }
no_tag() { [[ -z $(git -C "$work" tag) && -z $(git -C "$bare" tag) ]]; }
# no_leftover: 流したあとに、一時の置き場が残っていない。
no_leftover() { [[ -z $(ls -A "$case_dir/tmp") ]]; }

# 止まるときの案内に下書きの URL を出すときは、その次の行に、→ の付いたタグの名前の URL が出る。
draft_note="      → ${published_url}"
# 公開の手順の名前（docs/release.md の「公開」の表）。確認の「すること」の一覧は、することに応じて、この名前を 1 から振り直した番号で並べる。
step_names=(
	'タグを作って push する'
	'下書きの Release を作る'
	'発行のワークフローに配布物を作らせ、終わるまで待つ'
	'配布物を確かめる'
	'Release を公開する'
)
# steps_expected <最初の手順の番号>: 確認に出す、灰の○の一覧。
steps_expected() {
	local first=$1
	while [[ $first -le 5 ]]; do
		printf '  ○ %s\n' "${step_names[$((first - 1))]}"
		first=$((first + 1))
	done
}
expect_steps() {
	[[ $(grep '^  ○ ' "$case_dir/out") == "$(steps_expected "$1")" ]]
}
# 承認したあとは、確認の一覧と同じ名前の手順が、同じ順に ✔ で出る（番号の見出しは出ない）。
expect_headings() {
	local first=$1 pattern= expected actual
	expected=$(
		while [[ $first -le 5 ]]; do
			printf '%s\n' "${step_names[$((first - 1))]}"
			first=$((first + 1))
		done
	)
	first=$1
	while [[ $first -le 5 ]]; do
		pattern="$pattern${pattern:+|}${step_names[$((first - 1))]}"
		first=$((first + 1))
	done
	actual=$(grep -E "^  ✔ ($pattern)( |\$)" "$case_dir/out" | sed -E 's/^  ✔ //; s/  +.*$//')
	[[ $actual == "$expected" ]]
	! grep -qE '^\[[0-9]/[0-9]\] ' "$case_dir/out"
}
# 失敗のときは、灰の「$ コマンドの 1 行」と、受けた内容がそのまま標準エラー出力にあり、そのあとにエラーの案内がある。
# 区切りの文字の行は出ない。
expect_command_output() {
	python3 - "$case_dir/err" "$1" "$2" <<'PY'
from pathlib import Path
import sys
output = Path(sys.argv[1]).read_bytes()
command, raw = sys.argv[2:]
start = f'$ {command}\n'.encode()
body = Path(raw).read_bytes()
if body and not body.endswith(b'\n'):
    body += b'\n'
at = output.index(start)
assert output[at + len(start):].startswith(body)
assert at + len(start) + len(body) <= output.index('エラー:'.encode())
assert '出力 ここから'.encode() not in output and '出力 ここまで'.encode() not in output
PY
}
# 配布物の確かめは、4 項目が 1 行ずつ、4 の手順の続きの行として出る。タグの install.sh の出力と、「展開も実行もしていません」は出ない。
expect_verify_rows() {
	local expected
	expected=$(
		printf '      ✔ タグの install.sh    証明  チェックサム  tar.gz の中の一覧\n'
		printf '      ✔ 配布物の install.sh  証明  SHA256SUMS の行  タグの install.sh\n'
		printf '      ✔ 配布物の中身         git archive v1.6.0\n'
		printf '      ✔ 証明                 配布物  SHA256SUMS\n'
	)
	[[ $(grep '^      ✔ ' "$case_dir/out") == "$expected" ]]
	! grep -qF '展開も実行もしていません' "$case_dir/out" "$case_dir/err"
	! grep -qF '確かめが通りました' "$case_dir/out" "$case_dir/err"
}
# expect_summary <コミット> <Release の URL> <ワークフローの実行の URL か、見つからないとき空>: 終わりの表示が設計のとおり、出力の末尾にある。
expect_summary() {
	local run_line expected
	run_line=$3
	[[ -n $run_line ]] || run_line='! 発行のワークフローの実行が見つかりません。GitHub の Actions の画面で確かめてください。'
	expected=$(
		printf '\n✔ v1.6.0  %s\n' "$2"
		printf '  %s\n\n' "$1"
		printf '  multica-squad-kit-v1.6.0.tar.gz\n  install.sh\n  SHA256SUMS\n  multica-squad-kit-v1.6.0.sigstore.json\n\n'
		printf '  %s\n' "$run_line"
	)
	[[ $(tail -n 10 "$case_dir/out") == "$expected" ]]
	grep -qE '^  ✔ Release を公開する$' "$case_dir/out"
}
# expect_screen <結果の語> <タグと Release の値> <タグを付けるコミット> <最初の手順の番号>: 確認の前の画面の全体（確かめの一覧から、することの一覧まで）が設計のとおり。
expect_screen() {
	local head12 commit12
	head12=$(git -C "$work" rev-parse HEAD)
	head12=${head12:0:12}
	commit12=${3:0:12}
	local expected
	expected=$(
		printf '  ✔ 道具              git gh tar shasum diff cmp  gh 2.102.0  2.102.0 以上\n'
		printf '  ✔ 場所              example/kit  main\n'
		printf '  ✔ 未コミットの変更  なし\n'
		printf '  ✔ origin/main       %s\n' "$head12"
		printf '  ✔ バージョン        VERSION v1.6.0  CHANGELOG.md v1.6.0\n'
		printf '  ✔ タグと Release    %s\n' "$2"
		printf '\n'
		while IFS= read -r line; do
			if [[ -n $line ]]; then printf '  │ %s\n' "$line"; else printf '  │\n'; fi
		done <<<"$notes_expected"
		printf '\n  v1.6.0  example/kit\n  %s  Release content\n\n' "$commit12"
		steps_expected "$4"
	)
	[[ $(cat "$case_dir/out") == "$expected" ]]
	grep -qF '公開しますか [y/N]: ' "$case_dir/err"
}
