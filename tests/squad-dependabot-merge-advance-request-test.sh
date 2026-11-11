#!/usr/bin/env bash
# ZIP のルートで bash tests/squad-dependabot-merge-advance-request-test.sh。
# gh と multica を差し替え、実際の PR・タスクには書き込まない。advance のマージ・引数の検査と、rebase・recreate の依頼・再試行を確かめる。
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

advance_fixture
run_advance merged
jq -se --arg head "$reviewed" '[.[] | select(.[0:2] == ["pr","merge"])] ==
	[["pr","merge","1","--repo","example/template","--merge","--match-head-commit",$head]]' "$test_dir/calls.jsonl" >/dev/null
echo 'PASS advance: 成功した必須 CI の head を照合して通常のマージを呼ぶ'

for invalid in '.state = "CLOSED"' '.state = "MERGED"' '.author.login = "human"' '.author.is_bot = false' '.isDraft = true' '.baseRefName = "other"'; do
	advance_fixture
	edit_pr "$invalid"
	if bash "$script" example/template project-a advance 1 --reviewed-head "$reviewed" --run-deadline "$run_deadline" >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
	[[ ! -s $test_dir/output && -s $test_dir/error ]]
	no_writes
done
advance_fixture
add_pr 1 dependabot/go_modules/api/example "$(metadata major)"
if bash "$script" example/template project-a advance 1 --reviewed-head "$reviewed" --run-deadline "$run_deadline" >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
no_writes
echo 'PASS advance: 閉じた PR・他の作者・draft・main 以外・メジャーは操作せず拒否'

advance_fixture
for args in '1' "1 --reviewed-head invalid --run-deadline 214400" \
	"1 --reviewed-head $reviewed --run-deadline -1" \
	"1 --reviewed-head $reviewed --run-deadline 214400 --admin true" \
	"1 --reviewed-head $reviewed --run-deadline 214400 --pr-deadline 201800" \
	"1 --reviewed-head $reviewed --run-deadline 214400 --retry --retry" \
	"1 --reviewed-head $reviewed --run-deadline"; do
	if bash "$script" example/template project-a advance $args >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
done
no_writes
echo 'PASS advance: 必須引数・SHA・締め切り・未知の引数を検査'

for limit in ci run; do
	advance_fixture
	if [[ $limit == ci ]]; then printf '201800\n' >"$test_dir/now"
	else printf '214400\n' >"$test_dir/now"; commit_time "$reviewed" 214399; fi
	run_advance merged
	advance_fixture
	if [[ $limit == ci ]]; then printf '201800\n' >"$test_dir/now"; expected=ci-timeout
	else printf '214400\n' >"$test_dir/now"; commit_time "$reviewed" 214399; expected=run-timeout; fi
	printf '{"check_runs":[]}\n' >"$test_dir/checks.json"
	run_advance "$expected"
	no_writes
done
echo 'PASS advance: CI・実行全体の上限後でもマージ可能なら merged、未完了なら上限ごとの結果'

advance_fixture
# ハッシュがないときは同じバージョンの rebase も再確認する。
add_pr 2 dependabot/go_modules/api/example "$(metadata patch)"
head2=$(printf '%040d' 2)
edit_pr ".headRefOid = \"$head2\""
run_advance changed
no_writes
reviewed=$head2
run_advance merged
jq -se --arg head "$head2" 'any(.[]; .[0:2] == ["pr","merge"] and .[-1] == $head)' "$test_dir/calls.jsonl" >/dev/null
# 同じ更新の種類の中で新しいバージョンになった場合も、取り違えない。
add_pr 3 dependabot/go_modules/api/example "$(metadata patch | sed 's/1.2.3/1.2.4/')"
head3=$(printf '%040d' 3)
edit_pr ".headRefOid = \"$head3\""
: >"$test_dir/calls.jsonl"
run_advance changed
no_writes
echo 'PASS advance: ハッシュのない rebase は同じバージョンでも changed、確認済み head に替えてからマージ'

advance_fixture
add_pr 1 dependabot/docker/debian "$(metadata '')"
add_pr 2 dependabot/docker/debian "$(metadata '')"
digest_files >"$test_dir/files.json"
for head in "$reviewed" "$head2"; do
	jq --argjson files "$(digest_files)" '. + {files:$files}' "$test_dir/$head.json" >"$test_dir/edit.json"
	mv "$test_dir/edit.json" "$test_dir/$head.json"
done
edit_pr ".headRefOid = \"$head2\""
run_advance changed
no_writes
reviewed=$head2
run_advance merged
jq '.files[0].patch |= sub("sha256:0+2"; "sha256:0000000000000000000000000000000000000000000000000000000000000003")' \
	"$test_dir/$head2.json" >"$test_dir/$head3.json"
edit_pr ".headRefOid = \"$head3\""
: >"$test_dir/calls.jsonl"
run_advance changed
no_writes
echo 'PASS advance: ハッシュのない Docker の rebase は同じ digest でも changed'

for state in BEHIND CONFLICTING; do
	advance_fixture
	if [[ $state == BEHIND ]]; then edit_pr '.mergeStateStatus = "BEHIND"'; command=rebase
	else edit_pr '.mergeable = "CONFLICTING" | .mergeStateStatus = "DIRTY"'; command=recreate; fi
	run_advance waiting
	jq -e --arg command "@dependabot $command" --arg head "$reviewed" 'length == 1 and
		(.[0].body | startswith($command + "\n\n")) and (.[0].body | contains($head))' "$test_dir/comments.json" >/dev/null
	# 依頼したファイルは残さず、2 回目は同じ依頼を繰り返さない。
	while IFS= read -r file; do [[ ! -e $file ]]; done <"$test_dir/body-files"
	run_advance waiting
	jq -e 'length == 1' "$test_dir/comments.json" >/dev/null
	if [[ $state == CONFLICTING ]]; then
		add_pr 2 dependabot/go_modules/api/example "$(metadata patch)"
		edit_pr ".headRefOid = \"$head2\""
		: >"$test_dir/calls.jsonl"
		run_advance conflict
		no_writes
	fi
done
echo 'PASS advance: 未反映の rebase・recreate は重複依頼せず、作り直し後も衝突なら conflict'

advance_fixture
edit_pr '.mergeStateStatus = "BEHIND"'
# 過去の実行・別の作者の依頼は、今回の依頼として数えない。ページもまたぐ。
printf '[{"id":1,"user":{"login":"test-user"},"created_at":"1970-01-03T07:33:19Z","body":"@dependabot rebase"}]\n[{"id":2,"user":{"login":"other"},"created_at":"1970-01-03T07:33:20Z","body":"@dependabot rebase"}]\n' >"$test_dir/comments.json"
# mock の追記は配列 1 個を扱うため、まず既存のページをまとめる。
jq -s add "$test_dir/comments.json" >"$test_dir/comments-flat.json"
mv "$test_dir/comments-flat.json" "$test_dir/comments.json"
run_advance waiting
jq -e 'length == 3' "$test_dir/comments.json" >/dev/null
# 今回の依頼が 2 ページ目にあっても、追加で依頼しない。
jq '.[2:]' "$test_dir/comments.json" >"$test_dir/comments-page2.json"
jq '.[0:2]' "$test_dir/comments.json" >"$test_dir/edit.json"
mv "$test_dir/edit.json" "$test_dir/comments.json"
cat "$test_dir/comments-page2.json" >>"$test_dir/comments.json"
: >"$test_dir/calls.jsonl"
run_advance waiting
no_writes
echo 'PASS advance: 過去の実行と他の作者の依頼は今回の依頼に混ぜない'

for state in BEHIND CONFLICTING; do
	advance_fixture
	if [[ $state == BEHIND ]]; then edit_pr '.mergeStateStatus = "BEHIND"'
	else edit_pr '.mergeable = "CONFLICTING" | .mergeStateStatus = "DIRTY"'; fi
	run_advance waiting --retry
	# 反映の待ちは、呼び出した時刻ではなく依頼コメントの時刻から数える。
	printf '200599\n' >"$test_dir/now"
	: >"$test_dir/calls.jsonl"
	run_advance waiting --retry
	no_writes
	printf '200600\n' >"$test_dir/now"
	run_advance no-response
	no_writes
	run_advance waiting --retry
	jq -e 'length == 2 and (.[1].body | contains("<!-- squad-dependabot-merger retry -->"))
		and .[1].created_at == "1970-01-03T07:43:20Z"' "$test_dir/comments.json" >/dev/null
	: >"$test_dir/calls.jsonl"
	printf '201199\n' >"$test_dir/now"
	run_advance waiting --retry
	no_writes
	printf '201200\n' >"$test_dir/now"
	run_advance no-response --retry
	run_advance no-response --retry
	no_writes
	jq -e 'length == 2' "$test_dir/comments.json" >/dev/null
done
echo 'PASS advance: rebase・recreate は 10 分で no-response、--retry は呼び直しても 1 回だけ'

for mixed in false true; do
	advance_fixture
	edit_pr '.mergeStateStatus = "BEHIND"'
	run_advance waiting
	for n in 2 3 4; do
		add_pr "$n" dependabot/go_modules/api/example "$(metadata patch)"
		new_head=$(printf '%040d' "$n")
		edit_pr ".headRefOid = \"$new_head\" | .mergeable = \"MERGEABLE\" | .mergeStateStatus = \"BEHIND\""
		if [[ $mixed == true && $n == 2 ]]; then edit_pr '.mergeable = "CONFLICTING" | .mergeStateStatus = "DIRTY"'; fi
		: >"$test_dir/calls.jsonl"
		if [[ $n == 4 ]]; then run_advance behind-limit --retry; no_writes
		else run_advance waiting --retry; fi
		jq -e --argjson expected "$((n < 4 ? n : 3))" 'length == $expected' "$test_dir/comments.json" >/dev/null
	done
done
echo 'PASS advance: 反映後に main に遅れれば頼み直し、rebase・recreate の合計 3 回で behind-limit'

retries_after_response() {
	advance_fixture
	edit_pr '.mergeStateStatus = "BEHIND"'
	run_advance waiting
	printf '200600\n' >"$test_dir/now"
	run_advance waiting --retry
	add_pr 2 dependabot/go_modules/api/example "$(metadata patch)"
	head2=$(printf '%040d' 2)
	edit_pr ".headRefOid = \"$head2\""
	# 反映後の再依頼も、全体の 3 回の中に含める。
	run_advance waiting --retry
	jq -e 'length == 3 and ([.[] | select(.body | contains("<!-- squad-dependabot-merger retry -->"))] | length) == 1' "$test_dir/comments.json" >/dev/null
}
retries_after_response
printf '201200\n' >"$test_dir/now"
: >"$test_dir/calls.jsonl"
run_advance no-response --retry
no_writes
echo 'PASS advance: 無反応への頼み直しも合計 3 回に含め、head が変わっても無反応の再依頼は増やさない'

for state in BEHIND CONFLICTING; do
	advance_fixture
	if [[ $state == BEHIND ]]; then edit_pr '.mergeStateStatus = "BEHIND"'
	else edit_pr '.mergeable = "CONFLICTING" | .mergeStateStatus = "DIRTY"'; fi
	printf '214400\n' >"$test_dir/now"
	run_advance run-timeout --retry
	no_writes
done
advance_fixture
edit_pr '.mergeStateStatus = "BEHIND"'
printf '214390\n' >"$test_dir/now"
run_advance waiting
printf '214400\n' >"$test_dir/now"
: >"$test_dir/calls.jsonl"
run_advance run-timeout --retry
no_writes
echo 'PASS advance: 実行全体の上限では、新しい依頼も反映待ちも run-timeout'
