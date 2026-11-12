#!/usr/bin/env bash
# ZIP のルートで bash tests/squad-dependabot-merge-advance-diff-test.sh。
# gh と multica を差し替え、実際の PR・タスクには書き込まない。advance の rebase 前後の差分の比較を確かめる。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
if [[ ${SQUAD_CLI_TEST_COMPARING:-} != 1 ]]; then
	source "$root/tests/cli-mode-test-lib.sh"
	cli_test_compare_modes "$0" "$@"
	exit $?
fi

source "$root/tests/dependabot-merge-test-lib.sh"
source "$root/tests/dependabot-merge-advance-test-lib.sh"

rebase_fixture
# blob と行番号（省略形も含む）が変わっても、文脈と変更は同じ。
sed -E 's/^index .*/index aaaaaaa..bbbbbbb 100644/; s/^@@ .* @@/@@ -10 +20,3 @@/' \
	"$test_dir/pr.diff" >"$test_dir/new.diff"
mv "$test_dir/new.diff" "$test_dir/pr.diff"
# 差分を確かめ直す時間で、どちらの締め切りも過ぎた場合もマージする。
printf '215000\n' >"$test_dir/now"
run_advance merged
jq -se --arg head "$head2" '[.[] | select(.[0:2] == ["pr","merge"])] | length == 1 and .[0][-1] == $head' "$test_dir/calls.jsonl" >/dev/null
echo 'PASS advance: rebase 前後で差分が同じなら新しい head を照合し、締め切り後でもマージ'

rebase_fixture
cp "$test_dir/checks.json" "$test_dir/next-checks.json"
printf '{"check_runs":[]}\n' >"$test_dir/checks.json"
run_advance merged
[[ $(<"$test_dir/now") == 200010 ]]
echo 'PASS advance: 同じ差分の新しい head の CI を待ち、成功後にマージ'

for change in dependency context file hunk; do
	rebase_fixture
	case $change in
	dependency) sed 's/+example v1.2.3/+example v1.2.4/' "$test_dir/pr.diff" ;;
	context) sed 's/ \/\/ dependencies/ \/\/ changed context/' "$test_dir/pr.diff" ;;
	file) sed 's@api/go.mod@api/go.sum@g' "$test_dir/pr.diff" ;;
	hunk) sed 's/@@ require (/@@ other section (/' "$test_dir/pr.diff" ;;
	esac >"$test_dir/new.diff"
	mv "$test_dir/new.diff" "$test_dir/pr.diff"
	run_advance changed
	no_writes
done
echo 'PASS advance: 変更内容・文脈・ファイル・hunk の文脈が違えば changed'

for mismatch in missing-diff author run head command; do
	rebase_fixture
	case $mismatch in
	missing-diff) filter='.[0].body |= sub(" diff: [a-f0-9]{64}"; "")' ;;
	author) filter='.[0].user.login = "other"' ;;
	run) filter='.[0].created_at = "1970-01-03T07:33:19Z"' ;;
	head) filter=".[0].body |= sub(\"$reviewed\"; \"$head2\")" ;;
	command) filter='.[0].body |= sub("@dependabot rebase"; "other command")' ;;
	esac
	jq "$filter" "$test_dir/comments.json" >"$test_dir/new-comments.json"
	mv "$test_dir/new-comments.json" "$test_dir/comments.json"
	run_advance changed
	no_writes
done
echo 'PASS advance: ハッシュなし・別の作者・過去の実行・別の head・別のコマンドのハッシュは使わない'

rebase_fixture
cp "$test_dir/comments.json" "$test_dir/comments-page2.json"
printf '[]\n' >"$test_dir/comments.json"
cat "$test_dir/comments-page2.json" >>"$test_dir/comments.json"
run_advance merged
echo 'PASS advance: 後のページに保存されたハッシュでも比較できる'

for failure in api empty malformed race; do
	rebase_fixture
	case $failure in
	api) printf 'repos/example/template/pulls/1 -H\n' >"$test_dir/fail" ;;
	empty) : >"$test_dir/pr.diff" ;;
	malformed) printf '{"message":"Unavailable"}\n' >"$test_dir/pr.diff" ;;
	race) touch "$test_dir/changed-head" ;;
	esac
	run_advance changed
	no_writes
done
echo 'PASS advance: rebase 後の差分取得失敗・空・不正な応答・head の競合は changed、書き込みなし'

