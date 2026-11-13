#!/usr/bin/env bash
# ZIP のルートで bash tests/squad-dependabot-merge-advance-request-test.sh。
# gh と multica を差し替え、実際の PR・タスクには書き込まない。advance のマージ・引数の検査と、ハッシュのない rebase を確認する。
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

