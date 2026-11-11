#!/usr/bin/env bash
# ZIP のルートで bash tests/squad-dependabot-merge-test.sh。
# gh と multica を差し替え、実際の PR・タスクには書き込まない。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
if [[ ${SQUAD_CLI_TEST_COMPARING:-} != 1 ]]; then
	source "$root/tests/cli-mode-test-lib.sh"
	cli_test_compare_modes "$0" "$@"
	exit $?
fi

script="$root/common/monitor/squad-dependabot-merge"
mkdir -p tmp
test_dir=$(mktemp -d "$PWD/tmp/dependabot-merge-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
source "$root/tests/cli-mode-test-lib.sh"
cli_test_wrap_monitor "$script" "$test_dir"
export DEPENDABOT_MERGE_TEST_DIR="$test_dir"
export DEPENDABOT_MERGE_TEST_ROOT="$root"
source "$root/common/monitor/squad-cli-lib"
squad_cli_contracts >"$test_dir/contracts.json"
cli_fixture() { python3 "$root/tests/multica-fixture.py" "$test_dir" base "$@"; }
gh_fixture() { python3 "$root/tests/gh-fixture.py" "$test_dir" base "$@"; }
mkdir -p "$test_dir/bin"
export PATH="$test_dir/bin:$PATH"
cat >"$test_dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
dir=$DEPENDABOT_MERGE_TEST_DIR
python3 "$DEPENDABOT_MERGE_TEST_ROOT/tests/cli-test-trace.py" "$dir" gh "$@"
if [[ ${1-} == --version ]]; then echo 'gh fixture-version'; exit 0; fi
emit() {
 local name=$1 file=$2
 if [[ -f $dir/gh-defect.$name.json ]]; then
  python3 "$DEPENDABOT_MERGE_TEST_ROOT/tests/gh-fixture.py" "$dir" raw "$name" "$dir/gh-defect.$name.json"
 else python3 "$DEPENDABOT_MERGE_TEST_ROOT/tests/gh-fixture.py" "$dir" emit "$name" "$file"; fi
}
jq -cn --args '$ARGS.positional' -- "$@" >>"$dir/calls.jsonl"
if [[ -f $dir/fail && $* == *"$(<"$dir/fail")"* ]]; then
	echo 'CLI mock failure' >&2
	exit 1
fi
if [[ -f $dir/tick-on && $* == *"$(<"$dir/tick-on")"* ]]; then
	echo "$(($(<"$dir/now") + 20))" >"$dir/now"
fi
if [[ $1 == api ]]; then
	endpoint=$2
	case $endpoint in
	user) emit gh-viewer "$dir/viewer.json" ;;
	*'/comments?per_page=100') [[ ${3:-} == --paginate ]]; emit gh-pr-comments "$dir/comments.json" ;;
	*'pulls?state=open&per_page=100') [[ ${3:-} == --paginate ]]; emit gh-dependabot-pulls "$dir/pulls.json" ;;
	*/rules/branches/main) [[ ${3:-} == --paginate ]]; emit gh-branch-rules "$dir/rules.json" ;;
	*'/check-runs?filter=latest&per_page=100') [[ ${3:-} == --paginate ]]; emit gh-check-runs "$dir/checks.json" ;;
	*'/statuses?per_page=100') [[ ${3:-} == --paginate ]]; emit gh-statuses "$dir/statuses.json" ;;
	*'/files?per_page=100') [[ ${3:-} == --paginate ]]; emit gh-pr-files "$dir/files.json" ;;
	*/pulls/[0-9]*) [[ $3 == -H && $4 == 'Accept: application/vnd.github.diff' ]]; cat "$dir/pr.diff" ;;
	*/commits/*) emit gh-commit "$dir/${endpoint##*/}.json" ;;
	*) echo "Unexpected endpoint: $*" >&2; exit 1 ;;
	esac
elif [[ $1 == pr && $2 == comment ]]; then
	[[ $4 == --repo && $5 == example/template && $6 == --body-file ]]
	body=$(cat "$7")
	jq --arg body "$body" --argjson now "$(<"$dir/now")" '. + [{id: (length+1),
		user:{login:"test-user"}, body:$body, created_at: ($now | todateiso8601)}]' "$dir/comments.json" >"$dir/new-comments.json"
	mv "$dir/new-comments.json" "$dir/comments.json"
	printf '%s\n' "$7" >>"$dir/body-files"
	if [[ -f $dir/comments-page2.json ]]; then cat "$dir/comments-page2.json" >>"$dir/comments.json"; fi
elif [[ $1 == pr && $2 == merge ]]; then
	if [[ -f $dir/merge-fail ]]; then printf 'mock merge rejected\nhead mismatch\n' >&2; exit 1; fi
	echo 'mock merged'
elif [[ $1 == pr && $2 == view ]]; then
	if [[ ${*: -1} == headRefOid ]]; then
		if [[ -f $dir/changed-head ]]; then echo '{"headRefOid":"changed"}' >"$dir/head.json"; else jq '{headRefOid}' "$dir/pr-$3.json" >"$dir/head.json"; fi
		emit gh-pr-head "$dir/head.json"
	else
		emit gh-dependabot-pr "$dir/pr-$3.json"
	fi
else
	echo "Unexpected mock call (書き込みは禁止): $*" >&2
	exit 1
fi
EOF
chmod +x "$test_dir/bin/gh"

reset_fixture() {
	rm -f "$test_dir"/gh-defect.*.json
	gh_fixture gh-viewer | jq '.login="test-user"' >"$test_dir/viewer.json"
	printf '[]\n' >"$test_dir/pulls.json"
	printf '[]\n' >"$test_dir/files.json"
	printf '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"lint","integration_id":15368},{"context":"external","integration_id":null}]}}]\n' >"$test_dir/rules.json"
	printf '{"check_runs":[{"id":1,"name":"lint","app":{"id":15368},"status":"completed","conclusion":"success"}]}\n' >"$test_dir/checks.json"
	printf '[{"id":1,"context":"external","state":"success"}]\n' >"$test_dir/statuses.json"
	: >"$test_dir/calls.jsonl"
}

metadata() {
	printf 'Bump dependency\n\n---\nupdated-dependencies:\n- dependency-name: example\n  dependency-version: 1.2.3\n  dependency-type: direct:production\n'
	if [[ -n $1 ]]; then printf '  update-type: version-update:semver-%s\n' "$1"; fi
	printf '...\n\nSigned-off-by: dependabot[bot]\n'
}

add_pr() {
	local number=$1 branch=$2 message=$3 head
	head=$(printf '%040d' "$number")
	jq --argjson n "$number" '. + [{number: $n, state: "open", user: {type: "Bot", login: "dependabot[bot]"}}]' \
		"$test_dir/pulls.json" >"$test_dir/new.json"
	mv "$test_dir/new.json" "$test_dir/pulls.json"
	jq -n --argjson n "$number" --arg head "$head" --arg branch "$branch" '{
		number: $n, title: ("Bump #" + ($n | tostring)), headRefOid: $head, headRefName: $branch,
		state: "OPEN", isDraft: false, baseRefName: "main", mergeStateStatus: "CLEAN",
		author: {is_bot: true, login: "app/dependabot"}, mergeable: "MERGEABLE"
	}' >"$test_dir/pr-$number.json"
	jq -n --arg message "$message" '{commit: {message: $message, committer: {date:"1970-01-03T07:33:20Z"}}}' >"$test_dir/$head.json"
}

run_list() {
	if bash "$script" example/template project-a list >"$test_dir/output" 2>"$test_dir/error"; then
		:
	else
		cat "$test_dir/error" >&2
		return 1
	fi
	[[ ! -s $test_dir/error ]]
}

assert_output() { jq -e "$1" "$test_dir/output" >/dev/null; }

reset_fixture
run_list
assert_output '. == []'
jq -se 'length == 1' "$test_dir/calls.jsonl" >/dev/null
echo 'PASS list: PR なしは空配列、ルールとチェックは取得しない'

# 分類する PR は後のページにも置く。人間・別 bot・閉じた PR は除外。
add_pr 3 dependabot/go_modules/api/example "$(metadata patch)"
add_pr 1 dependabot/npm_and_yarn/e2e/example "$(metadata major)"
add_pr 2 dependabot/github_actions/example "$(metadata minor)"
printf '[{"number":100,"state":"open","user":{"type":"User","login":"dependabot[bot]"}},{"number":101,"state":"open","user":{"type":"Bot","login":"other[bot]"}},{"number":102,"state":"closed","user":{"type":"Bot","login":"dependabot[bot]"}}]\n' >>"$test_dir/pulls.json"
# チェックと status の 2 ページ目を読む（後の成功で失敗を隠さない）。
printf '{"check_runs":[{"id":2,"name":"optional","app":{"id":15368},"status":"completed","conclusion":"failure"}]}\n' >>"$test_dir/checks.json"
printf '[{"id":2,"context":"optional","state":"failure"}]\n' >>"$test_dir/statuses.json"
run_list
assert_output '[.[].number] == [1,2,3] and [.[].update_type] == ["major","minor","patch"]
	and [.[].ecosystem] == ["npm","github-actions","gomod"]
	and all(.[]; .ci == "success" and .mergeable == "MERGEABLE" and (.head_sha | length) == 40 and (.title | startswith("Bump #")))'
jq -se '[.[] | select(.[0:2] == ["pr","view"]) | .[2]] == ["1","2","3"]' "$test_dir/calls.jsonl" >/dev/null
echo 'PASS list: 全ページ・作者・状態の絞り込み、番号順、3 種類の更新、必須以外の失敗を無視'

for kind in minor major; do
	reset_fixture
	group=$(metadata patch)
	group=${group%%...*}
	group+=$(printf '\n- dependency-name: second\n  update-type: version-update:semver-%s\n...\n' "$kind")
	add_pr 1 dependabot/go_modules/api/group "$group"
	run_list
	assert_output ".[0].update_type == \"$kind\""
done
echo 'PASS list: グループは最大の更新の種類にする'

for message in "$(metadata '')" 'No metadata' "$(metadata invalid)" \
	"$(metadata patch | sed '/^\.\.\./i\
- dependency-name: missing-type\
  dependency-version: 2.0.0
')"; do
	reset_fixture
	add_pr 1 dependabot/go_modules/api/group "$message"
	run_list
	assert_output '.[0].update_type == "major"'
done
echo 'PASS list: メタデータなし・未知の種類・一部の種類が不明なら major'

digest_files() {
	local old new
	old=$(printf '%064d' 1)
	new=$(printf '%064d' 2)
	jq -n --arg old "$old" --arg new "$new" '[{
		filename: "Dockerfile.api", status: "modified", additions: 1, deletions: 1,
		patch: ("@@ -1 +1 @@\n-FROM debian:stable@sha256:" + $old + "\n+FROM debian:stable@sha256:" + $new)
	}]'
}

reset_fixture
add_pr 1 dependabot/docker/debian "$(metadata '')"
digest_files >"$test_dir/files.json"
run_list
assert_output '.[0].update_type == "patch" and .[0].ecosystem == "docker"'
echo 'PASS list: Docker のタグ不変の digest 更新を patch にする'

for change in tag extra missing truncated; do
	case $change in
	tag) digest_files | jq '.[0].patch |= sub("\\+FROM debian:stable"; "+FROM debian:new")' ;;
	extra) digest_files | jq '. + [{filename:"other", status:"modified", additions:1, deletions:1, patch:"@@ -1 +1 @@\n-old\n+new"}]' ;;
	missing) digest_files | jq '.[0].patch = null' ;;
	truncated) digest_files | jq '.[0].additions = 2' ;;
	esac >"$test_dir/files.json"
	run_list
	assert_output '.[0].update_type == "major"'
done
echo 'PASS list: Docker のタグ変更・他の変更・差分不足は major'

digest_files | jq '.[0].filename = "compose.yaml" | .[0].patch |= gsub("FROM "; "  image: ")' >"$test_dir/files.json"
jq '.headRefName = "dependabot/docker_compose/example"' "$test_dir/pr-1.json" >"$test_dir/new.json"
mv "$test_dir/new.json" "$test_dir/pr-1.json"
run_list
assert_output '.[0].ecosystem == "docker-compose" and .[0].update_type == "patch"'
echo 'PASS list: Compose の digest 更新も確認する'

reset_fixture
add_pr 1 dependabot/go_modules/api/example "$(metadata patch)"
for state in queued in_progress; do
	jq -n --arg state "$state" '{check_runs:[{id:1,name:"lint",app:{id:15368},status:$state,conclusion:null}]}' >"$test_dir/checks.json"
	run_list
	assert_output '.[0].ci == "pending"'
done
printf '{"check_runs":[]}\n' >"$test_dir/checks.json"
run_list
assert_output '.[0].ci == "pending"'
echo 'PASS CI: 実行中・未登録の必須チェックは pending'

for conclusion in failure cancelled timed_out action_required stale neutral skipped; do
	jq -n --arg c "$conclusion" '{check_runs:[{id:1,name:"lint",app:{id:15368},status:"completed",conclusion:$c}]}' >"$test_dir/checks.json"
	printf '[{"id":1,"context":"external","state":"pending"}]\n' >"$test_dir/statuses.json"
	run_list
	assert_output '.[0].ci == "failure"'
done
echo 'PASS CI: 成功以外の終了は failure、pending より失敗を優先'

printf '{"check_runs":[{"id":1,"name":"lint","app":{"id":999},"status":"completed","conclusion":"success"}]}\n' >"$test_dir/checks.json"
printf '[{"id":1,"context":"lint","state":"success"},{"id":2,"context":"external","state":"success"}]\n' >"$test_dir/statuses.json"
run_list
assert_output '.[0].ci == "pending"'
echo 'PASS CI: 同名の別 App・commit status は指定 App の代わりにしない'

for conclusion in success failure; do
	jq -n --arg c "$conclusion" '{check_runs:[
		{id:1,name:"lint",app:{id:15368},status:"completed",conclusion:"failure"},
		{id:2,name:"lint",app:{id:15368},status:"completed",conclusion:$c}]}' >"$test_dir/checks.json"
	run_list
	assert_output ".[0].ci == \"$conclusion\""
done
printf '[{"id":1,"context":"external","state":"failure"},{"id":2,"context":"external","state":"success"}]\n' >"$test_dir/statuses.json"
jq '.check_runs[-1].conclusion = "success"' "$test_dir/checks.json" >"$test_dir/new.json"
mv "$test_dir/new.json" "$test_dir/checks.json"
run_list
assert_output '.[0].ci == "success"'
printf '[{"id":3,"context":"external","state":"error"}]\n' >>"$test_dir/statuses.json"
run_list
assert_output '.[0].ci == "failure"'
echo 'PASS CI: 再実行と commit status は最新の結果を照合し、ページをまたいだ失敗も拾う'

printf '[]\n' >"$test_dir/rules.json"
run_list
assert_output '.[0].ci == "success"'
echo 'PASS CI: 必須チェックがないルールでは必須以外を判定に使わない'

for endpoint in 'pulls?state' rules/branches commits/ /check-runs /statuses; do
	printf '%s\n' "$endpoint" >"$test_dir/fail"
	if bash "$script" example/template project-a list >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
	[[ ! -s $test_dir/output ]]
	grep -q 'CLI mock failure' "$test_dir/error"
done
rm "$test_dir/fail"
echo 'PASS list: API 失敗は空配列・部分的な成功を出さずエラーを返す'

reset_fixture
add_pr 1 dependabot/go_modules/api/example "$(metadata patch)"
add_pr 2 dependabot/go_modules/api/second "$(metadata minor)"
printf 'commits/%040d\n' 2 >"$test_dir/fail"
if bash "$script" example/template project-a list >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
[[ ! -s $test_dir/output ]]
grep -q 'CLI mock failure' "$test_dir/error"
rm "$test_dir/fail"
printf 'invalid json\n' >"$test_dir/pr-1.json"
if bash "$script" example/template project-a list >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
[[ ! -s $test_dir/output && -s $test_dir/error ]]
echo 'PASS list: 後続 PR の取得失敗・不正な JSON でも成功した一覧を返さない'

reset_fixture
add_pr 1 dependabot/docker/debian "$(metadata '')"
digest_files >"$test_dir/files.json"
touch "$test_dir/changed-head"
if bash "$script" example/template project-a list >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
[[ ! -s $test_dir/output ]]
grep -q 'head が変わりました' "$test_dir/error"
echo 'PASS list: Docker の差分取得中に head が変わればエラー'

# advance の待ちは、実時間を進めず、時計と次の CI / PR の状態だけを進める。
cat >"$test_dir/bin/date" <<'EOF'
#!/usr/bin/env bash
[[ $* == +%s ]] || exit 1
cat "$DEPENDABOT_MERGE_TEST_DIR/now"
EOF
cat >"$test_dir/bin/sleep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
dir=$DEPENDABOT_MERGE_TEST_DIR
echo "$1" >>"$dir/sleeps"
echo "$(($(<"$dir/now") + $1))" >"$dir/now"
for kind in checks pr; do
	if [[ -f $dir/next-$kind.json ]]; then
		if [[ $kind == pr ]]; then target=pr-1; else target=checks; fi
		mv "$dir/next-$kind.json" "$dir/$target.json"
	fi
done
EOF
chmod +x "$test_dir/bin/date" "$test_dir/bin/sleep"

advance_fixture() {
	reset_fixture
	rm -f "$test_dir/changed-head" "$test_dir/merge-fail" "$test_dir/next-checks.json" "$test_dir/next-pr.json" "$test_dir/fail" "$test_dir/tick-on" "$test_dir/comments-page2.json"
	printf '200000\n' >"$test_dir/now"
	printf '[]\n' >"$test_dir/comments.json"
	cat >"$test_dir/pr.diff" <<'EOF'
diff --git a/api/go.mod b/api/go.mod
index 1111111..2222222 100644
--- a/api/go.mod
+++ b/api/go.mod
@@ -1,3 +1,3 @@ require (
 // dependencies
-example v1.2.2
+example v1.2.3
 )
EOF
	: >"$test_dir/sleeps"
	: >"$test_dir/body-files"
	add_pr 1 dependabot/go_modules/api/example "$(metadata patch)"
	reviewed=$(printf '%040d' 1)
	run_deadline=214400
}

run_advance() {
	local expected=$1
	shift
	if bash "$script" example/template project-a advance 1 --reviewed-head "$reviewed" --run-deadline "$run_deadline" "$@" >"$test_dir/output" 2>"$test_dir/error"; then :
	else cat "$test_dir/error" >&2; return 1; fi
	if [[ -s $test_dir/error || $(sed -n '1p' "$test_dir/output") != "$expected" || $(wc -l <"$test_dir/output") -ne 2 ]]; then
		printf '期待した結果: %s\n実際の結果:\n' "$expected" >&2
		cat "$test_dir/output" "$test_dir/error" >&2
		return 1
	fi
}

no_writes() {
	jq -se 'all(.[]; .[0:2] != ["pr","merge"] and .[0:2] != ["pr","comment"])' "$test_dir/calls.jsonl" >/dev/null
}

edit_pr() {
	jq "$1" "$test_dir/pr-1.json" >"$test_dir/edit.json"
	mv "$test_dir/edit.json" "$test_dir/pr-1.json"
}

commit_time() {
	jq --argjson time "$2" '.commit.committer.date = ($time | todateiso8601)' "$test_dir/$1.json" >"$test_dir/edit.json"
	mv "$test_dir/edit.json" "$test_dir/$1.json"
}

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

# 依頼で実際に保存したハッシュを、新しい head の差分と比較する。
rebase_fixture() {
	advance_fixture
	edit_pr '.mergeStateStatus = "BEHIND"'
	run_advance waiting
	jq -e --arg head "$reviewed" '.[0].body | contains("head: " + $head + " diff: ")
		and test("diff: [a-f0-9]{64} -->")' "$test_dir/comments.json" >/dev/null
	add_pr 2 dependabot/go_modules/api/example "$(metadata patch)"
	head2=$(printf '%040d' 2)
	edit_pr ".headRefOid = \"$head2\" | .mergeStateStatus = \"CLEAN\""
	: >"$test_dir/calls.jsonl"
}

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

# 依頼前の差分が比べられなくても、head が安定していれば、ハッシュなしで依頼して先に進む。
for failure in api empty malformed binary; do
	advance_fixture
	edit_pr '.mergeStateStatus = "BEHIND"'
	case $failure in
	api) printf 'repos/example/template/pulls/1 -H\n' >"$test_dir/fail" ;;
	empty) : >"$test_dir/pr.diff" ;;
	malformed) printf '{"message":"Unavailable"}\n' >"$test_dir/pr.diff" ;;
	binary) printf 'diff --git a/logo.png b/logo.png\nindex 1111111..2222222 100644\nBinary files a/logo.png and b/logo.png differ\n' >"$test_dir/pr.diff" ;;
	esac
	run_advance waiting
	# 再確認後の呼び直しも、同じ head のまま、依頼を重ねずに反映を待つ。
	run_advance waiting
	[[ $(jq length "$test_dir/comments.json") == 1 ]]
	jq -e --arg head "$reviewed" '.[0].body | startswith("@dependabot rebase\n") and contains("<!-- squad-dependabot-merger head: " + $head + " -->")
		and (contains("diff:") | not)' "$test_dir/comments.json" >/dev/null
	# 反映後は、ハッシュがないので必ず確認し直し、確認済みの head を替えれば進める。
	add_pr 2 dependabot/go_modules/api/example "$(metadata patch)"
	head2=$(printf '%040d' 2)
	edit_pr ".headRefOid = \"$head2\" | .mergeStateStatus = \"CLEAN\""
	rm -f "$test_dir/fail"
	run_advance changed
	reviewed=$head2
	run_advance merged
done
echo 'PASS advance: head が安定したまま依頼前の差分を比べられなくても、ハッシュなしで依頼し、反映後は changed を経て進む'

advance_fixture
edit_pr '.mergeStateStatus = "BEHIND"'
touch "$test_dir/changed-head"
run_advance changed
no_writes
echo 'PASS advance: 依頼前の差分取得中に head が変わったら changed、書き込みなし'

# バイナリの内容は差分に出ず、blob の ID も除くので、ハッシュが同じでも内容が同じとは限らない。
rebase_fixture
printf 'diff --git a/api/go.mod b/api/go.mod\nindex 1111111..3333333 100644\nBinary files a/api/go.mod and b/api/go.mod differ\n' >"$test_dir/pr.diff"
run_advance changed
no_writes
rebase_fixture
printf 'GIT binary patch\n' >>"$test_dir/pr.diff"
run_advance changed
no_writes
echo 'PASS advance: rebase 後の差分がバイナリを含めば、ハッシュに頼らず changed、書き込みなし'

# 短いバイナリ差分の後ろに大きなテキスト差分が続いても、検出を取りこぼさない。
large_text_diff() {
	printf 'diff --git a/logo.png b/logo.png\nindex 1111111..2222222 100644\nBinary files a/logo.png and b/logo.png differ\n'
	printf 'diff --git a/api/go.mod b/api/go.mod\nindex 1111111..2222222 100644\n--- a/api/go.mod\n+++ b/api/go.mod\n@@ -1,3 +1,20000 @@\n'
	awk 'BEGIN { for (i = 0; i < 20000; i++) printf "+example v1.2.%d // dependencies dependencies dependencies\n", i }'
}
rebase_fixture
large_text_diff >"$test_dir/pr.diff"
run_advance changed
no_writes
advance_fixture
edit_pr '.mergeStateStatus = "BEHIND"'
large_text_diff >"$test_dir/pr.diff"
run_advance waiting
jq -e '.[0].body | contains("diff:") | not' "$test_dir/comments.json" >/dev/null
echo 'PASS advance: 大きなテキスト差分の前のバイナリ差分も検出し、changed・ハッシュなしの依頼にする'

for state in CLEAN BEHIND; do
	advance_fixture
	edit_pr ".mergeStateStatus = \"$state\""
	printf '214400\n' >"$test_dir/now"
	printf '{"check_runs":[{"id":1,"name":"lint","app":{"id":15368},"status":"completed","conclusion":"failure"}]}\n' >"$test_dir/checks.json"
	run_advance ci-failed
	no_writes
done
echo 'PASS advance: 必須 CI の失敗は締め切り・rebase の依頼より先に ci-failed'

advance_fixture
printf '{"check_runs":[]}\n' >"$test_dir/checks.json"
printf '201785\n' >"$test_dir/now"
run_advance ci-timeout
[[ $(<"$test_dir/now") == 201800 ]]
no_writes
advance_fixture
edit_pr '.mergeable = "UNKNOWN" | .mergeStateStatus = "UNKNOWN"'
run_advance waiting
[[ $(<"$test_dir/now") == 200300 ]]
no_writes
echo 'PASS advance: 必須 CI の未登録は締め切りまで、可否が不明なら最大 5 分で waiting'

for committed_at in 190000 200900; do
	advance_fixture
	commit_time "$reviewed" "$committed_at"
	printf '{"check_runs":[]}\n' >"$test_dir/checks.json"
	ci_origin=$committed_at
	((ci_origin >= 200000)) || ci_origin=200000
	printf '%s\n' "$((ci_origin + 1799))" >"$test_dir/now"
	run_advance ci-timeout
	[[ $(<"$test_dir/now") == "$((ci_origin + 1800))" ]]
	no_writes
done
rebase_fixture
commit_time "$head2" 201000
printf '201500\n' >"$test_dir/now"
printf '{"check_runs":[]}\n' >"$test_dir/checks.json"
run_advance waiting
[[ $(<"$test_dir/now") == 201800 ]]
printf '202799\n' >"$test_dir/now"
run_advance ci-timeout
[[ $(<"$test_dir/now") == 202800 ]]
no_writes
echo 'PASS advance: CI は GitHub のコミット時刻と実行開始の遅いほうから 30 分、rebase 後は新しい head が起点'

advance_fixture
edit_pr '.mergeable = "UNKNOWN" | .mergeStateStatus = "UNKNOWN"'
printf '202000\n' >"$test_dir/now"
run_advance waiting
[[ $(<"$test_dir/now") == 202300 ]]
printf '214399\n' >"$test_dir/now"
run_advance run-timeout
[[ $(<"$test_dir/now") == 214400 ]]
no_writes
echo 'PASS advance: CI 成功後のマージ可否待ちは CI の上限にせず、5 分の呼び出し・実行全体の上限で返す'

advance_fixture
jq '.commit.committer.date = "invalid"' "$test_dir/$reviewed.json" >"$test_dir/edit.json"
mv "$test_dir/edit.json" "$test_dir/$reviewed.json"
if bash "$script" example/template project-a advance 1 --reviewed-head "$reviewed" --run-deadline "$run_deadline" >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
[[ ! -s $test_dir/output && -s $test_dir/error ]]
no_writes
echo 'PASS advance: GitHub のコミット時刻が不正な場合は操作せずエラー'

advance_fixture
cp "$test_dir/checks.json" "$test_dir/next-checks.json"
printf '{"check_runs":[]}\n' >"$test_dir/checks.json"
run_advance merged
[[ $(<"$test_dir/now") == 200010 ]]
advance_fixture
printf '{"check_runs":[{"id":1,"name":"lint","app":{"id":15368},"status":"completed","conclusion":"failure"}]}\n' >"$test_dir/checks.json"
run_advance ci-failed
no_writes
echo 'PASS advance: 待つ間の CI 成功でマージ、CI の失敗では ci-failed'

advance_fixture
add_pr 2 dependabot/go_modules/api/example "$(metadata minor | sed 's/1.2.3/1.3.0/')"
edit_pr ".headRefOid = \"$head2\""
cp "$test_dir/pr-1.json" "$test_dir/next-pr.json"
edit_pr ".headRefOid = \"$reviewed\""
printf '{"check_runs":[]}\n' >"$test_dir/checks.json"
run_advance changed
no_writes
echo 'PASS advance: CI 待ちの間にバージョンが変わった場合も changed'

for branch in dependabot/go_modules/api/example dependabot/npm_and_yarn/e2e/example \
	dependabot/github_actions/example dependabot/docker/debian dependabot/docker_compose/debian; do
	for timing in before waiting; do
		advance_fixture
		edit_pr ".headRefName = \"$branch\""
		add_pr 2 "$branch" "$(metadata patch)"
		# 名前とバージョンは同じでも、未確認の依存差分と通常コードを加えた head。
		jq '. + {files:[{filename:"api/go.sum",patch:"+unreviewed checksum"},
			{filename:"viewer/auth.go",patch:"-validateToken()"}]}' "$test_dir/$head2.json" >"$test_dir/edit.json"
		mv "$test_dir/edit.json" "$test_dir/$head2.json"
		edit_pr ".headRefOid = \"$head2\""
		if [[ $timing == waiting ]]; then
			cp "$test_dir/pr-1.json" "$test_dir/next-pr.json"
			edit_pr ".headRefOid = \"$reviewed\""
			printf '{"check_runs":[]}\n' >"$test_dir/checks.json"
		fi
		run_advance changed
		no_writes
		if [[ $timing == waiting ]]; then [[ $(<"$test_dir/now") == 200010 ]]; fi
	done
done
echo 'PASS advance: 全 ecosystem で同じ名前・バージョンの未確認差分も、開始時・CI 待ち中に changed'

for initial_kind in patch minor; do
	for timing in before waiting; do
		advance_fixture
		jq --arg message "$(metadata "$initial_kind")" '.commit.message = $message' "$test_dir/$reviewed.json" >"$test_dir/edit.json"
		mv "$test_dir/edit.json" "$test_dir/$reviewed.json"
		add_pr 2 dependabot/go_modules/api/example "$(metadata major | sed 's/1.2.3/2.0.0/')"
		head2=$(printf '%040d' 2)
		edit_pr ".headRefOid = \"$head2\""
		if [[ $timing == waiting ]]; then
			cp "$test_dir/pr-1.json" "$test_dir/next-pr.json"
			edit_pr ".headRefOid = \"$reviewed\""
			printf '{"check_runs":[]}\n' >"$test_dir/checks.json"
		fi
		run_advance changed
		if [[ $timing == waiting ]]; then [[ $(<"$test_dir/now") == 200010 ]]; fi
		# changed を受けた呼び出し側が再取得し、メジャーとして人間に回せる。
		run_list
		assert_output '[.[] | select(.number == 1)] | length == 1 and .[0].update_type == "major"'
		no_writes
	done
done
echo 'PASS advance: 確認済みの patch・minor が開始時・CI 待ち中に major へ変われば changed、再取得で major'

for endpoint in /check-runs /comments; do
	advance_fixture
	printf '214385\n' >"$test_dir/now"
	[[ $endpoint != /comments ]] || edit_pr '.mergeStateStatus = "BEHIND"'
	printf '%s\n' "$endpoint" >"$test_dir/tick-on"
	if [[ $endpoint == /check-runs ]]; then run_advance merged
	else run_advance run-timeout; no_writes; fi
done
echo 'PASS advance: API 取得中に締め切りを超えてもマージ可能なら merged、追従の依頼はしない'

advance_fixture
touch "$test_dir/merge-fail"
run_advance merge-failed
grep -q 'mock merge rejected head mismatch' "$test_dir/output"
echo 'PASS advance: GitHub の拒否を merge-failed と 1 行の理由で返す'

for failure in rules/branches /check-runs /statuses 'pr comment' /comments; do
	advance_fixture
	if [[ $failure == 'pr comment' || $failure == /comments ]]; then edit_pr '.mergeStateStatus = "BEHIND"'; fi
	printf '%s\n' "$failure" >"$test_dir/fail"
	if bash "$script" example/template project-a advance 1 --reviewed-head "$reviewed" --run-deadline "$run_deadline" >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
	[[ ! -s $test_dir/output && -s $test_dir/error ]]
	if [[ $failure != 'pr comment' ]]; then no_writes; fi
	while IFS= read -r file; do [[ ! -e $file ]]; done <"$test_dir/body-files"
done
echo 'PASS advance: API・コメントの失敗で操作を続けず、成功した結果も出さない'

# escalate の Multica も差し替え、作成した状態を次の呼び出しに引き継ぐ。
cat >"$test_dir/bin/multica" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
dir=$DEPENDABOT_MERGE_TEST_DIR
python3 "$DEPENDABOT_MERGE_TEST_ROOT/tests/cli-test-trace.py" "$dir" multica "$@"
if [[ ${1-} == version ]]; then echo 'multica fixture-version'; exit 0; fi
emit() { python3 "$DEPENDABOT_MERGE_TEST_ROOT/tests/multica-fixture.py" "$dir" emit "$@"; }
jq -cn --args '$ARGS.positional' -- "$@" >>"$dir/multica-calls.jsonl"
args=("$@")
value() {
	local i
	for ((i=0; i<${#args[@]}; i++)); do
		if [[ ${args[i]} == "$1" ]]; then printf '%s\n' "${args[i+1]}"; return; fi
	done
	return 1
}
if [[ "$1 $2" == 'issue create' ]]; then
	printf '%s\n' "$(value --description-file)" >>"$dir/description-files"
fi
if [[ -f $dir/multica-fail && $* == *"$(<"$dir/multica-fail")"* ]]; then
	echo 'Multica mock failure' >&2
	exit 1
fi
case "$1 $2" in
'issue search')
	[[ $4 == --include-closed && $(value --limit) == 1000 && $(value --output) == json ]]
	emit issue-search "$dir/search.json"
	;;
'label list') emit label-list "$dir/labels.json" ;;
'workspace member') [[ $3 == list ]]; emit member-list "$dir/members.json" ;;
'issue create')
	cat "$(value --description-file)" >"$dir/created-body.md"
	jq --slurpfile base "$dir/create-prototype.json" -n --arg title "$(value --title)" --arg project "$(value --project)" \
		--arg assignee "$(value --assignee-id)" --arg status "$(value --status)" '$base[0] + {
		id:"issue-a", identifier:"TEST-9000", title:$title,
		project_id:$project, assignee_id:$assignee, assignee_type:"member", status:$status
	}' >"$dir/created.json"
	jq --slurpfile base "$dir/search-prototype.json" --argjson issue "$(<"$dir/created.json")" -n '$base[0].issues[0] as $item | $base[0] + {issues:[$item + {id:$issue.id,identifier:$issue.identifier,title:$issue.title,project_id:$issue.project_id,assignee_id:$issue.assignee_id,assignee_type:$issue.assignee_type,status:$issue.status}]}'  >"$dir/search.json"
	python3 "$DEPENDABOT_MERGE_TEST_ROOT/tests/multica-fixture.py" "$dir" base issue-metadata | jq 'del(.repository,.pr_url)' >"$dir/metadata.json"
	if [[ -f $dir/create-response.json ]]; then emit issue-create "$dir/create-response.json"; else emit issue-create "$dir/created.json"; fi
	;;
'issue metadata')
	case $3 in
	list) [[ $(value --output) == json ]]; emit issue-metadata "$dir/metadata.json" ;;
	set)
		[[ $(value --type) == string ]]
		jq --arg key "$(value --key)" --arg value "$(value --value)" '.[$key] = $value' "$dir/metadata.json" >"$dir/metadata.next"
		mv "$dir/metadata.next" "$dir/metadata.json"
		;;
	*) exit 1 ;;
	esac
	;;
'issue label')
	case $3 in
	list) emit issue-labels "$dir/issue-labels.json" ;;
	add) jq --slurpfile base "$dir/label-prototype.json" -n --arg id "$5" '[$base[0] + {id:$id, name:"運用"}]' >"$dir/issue-labels.json"; echo '{}' ;;
	*) exit 1 ;;
	esac
	;;
*) echo "Unexpected Multica call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$test_dir/bin/multica"

# PR の紐付けの API も差し替え、引数と標準入力の設定を残す。
cat >"$test_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
dir=$DEPENDABOT_MERGE_TEST_DIR
python3 "$DEPENDABOT_MERGE_TEST_ROOT/tests/cli-test-trace.py" "$dir" curl "$@"
jq -cn --args '$ARGS.positional' -- "$@" >>"$dir/curl-calls.jsonl"
cat >"$dir/curl-config"
printf '%s' "$(<"$dir/curl-status")"
EOF
chmod +x "$test_dir/bin/curl"
export MULTICA_TOKEN=mat_test-token MULTICA_SERVER_URL=https://multica.example.test/ MULTICA_WORKSPACE_ID=workspace-a

cat >"$test_dir/escalation.md" <<'EOF'
理由: 必須 CI の失敗

確認の結果:
- リリースノートを確認した。
- 文字列の \n と `code` はそのまま残す。
EOF

escalate_fixture() {
	advance_fixture
	rm -f "$test_dir/multica-fail" "$test_dir/created.json" "$test_dir/created-body.md"
	: >"$test_dir/multica-calls.jsonl"
	: >"$test_dir/description-files"
	rm -f "$test_dir/allow-missing-fields" "$test_dir/create-response.json"
	cli_fixture issue-create >"$test_dir/create-prototype.json"
	cli_fixture issue-search >"$test_dir/search-prototype.json"
	cli_fixture label-list >"$test_dir/label-prototype.json"
	cli_fixture issue-search | jq '.issues=[]' >"$test_dir/search.json"
	cli_fixture label-list | jq '[. + {id:"label-a",name:"運用",resource_type:"issue"}]' >"$test_dir/labels.json"
	printf '[]\n' >"$test_dir/issue-labels.json"
	cli_fixture member-list | jq '[. + {name:"Owner Name",email:"owner@example.test",user_id:"member-a",id:"membership-a"}]' >"$test_dir/members.json"
	cli_fixture issue-metadata | jq 'del(.repository,.pr_url)' >"$test_dir/metadata.json"
	printf '200' >"$test_dir/curl-status"
	: >"$test_dir/curl-calls.jsonl"
	rm -f "$test_dir/curl-config"
}

run_escalate() {
	local expected=$1
	if bash "$script" example/template project-a escalate 1 "$test_dir/escalation.md" --assignee 'Owner Name' >"$test_dir/output" 2>"$test_dir/error"; then :
	else cat "$test_dir/error" >&2; return 1; fi
	[[ $(<"$test_dir/output") == "$expected" && ! -s $test_dir/error ]]
}

no_issue_writes() {
	jq -se 'all(.[]; .[0:2] != ["issue","create"] and .[0:3] != ["issue","label","add"]
		and .[0:2] != ["issue","status"] and .[0:2] != ["issue","update"])' "$test_dir/multica-calls.jsonl" >/dev/null
}

escalate_fixture
run_escalate 'TEST-9000 created'
jq -e '.title == "Dependabot の PR を確認する: Bump #1（example/template#1）"
	and .project_id == "project-a"
	and .assignee_id == "member-a" and .status == "in_review"' "$test_dir/created.json" >/dev/null
jq -e '.[0].id == "label-a"' "$test_dir/issue-labels.json" >/dev/null
jq -Rse 'startswith("[@Owner Name](mention://member/member-a)\n\nPR: https://github.com/example/template/pull/1\n\n")
	and contains("理由: 必須 CI の失敗\n\n確認の結果:") and contains("文字列の \\n と `code`")' "$test_dir/created-body.md" >/dev/null
while IFS= read -r file; do [[ ! -e $file ]]; done <"$test_dir/description-files"
echo 'PASS escalate: プロジェクト・メンバーの user_id・in_review・運用ラベル、メンションと本文を設定'

jq -se 'length == 1 and (.[0] | index("https://multica.example.test/api/issues/issue-a/pull-requests") != null
	and index("{\"url\":\"https://github.com/example/template/pull/1\"}") != null
	and index("X-Workspace-ID: workspace-a") != null and all(.[]; contains("mat_test-token") | not))' "$test_dir/curl-calls.jsonl" >/dev/null
[[ $(<"$test_dir/curl-config") == 'header = "Authorization: Bearer mat_test-token"' ]]
jq -e '.pr_url == "https://github.com/example/template/pull/1"' "$test_dir/metadata.json" >/dev/null
echo 'PASS escalate: 作ったタスクに PR を API で紐付け、トークンは引数に出さず、metadata の pr_url に残す'

: >"$test_dir/multica-calls.jsonl"
run_escalate 'TEST-9000 exists'
no_issue_writes
# 人間が閉じた タスクも返し、担当・状態・タイトルは変更しない。
jq '.issues[0].status = "done" | .issues[0].title = "以前のバージョン（example/template#1）"' "$test_dir/search.json" >"$test_dir/edit.json"
mv "$test_dir/edit.json" "$test_dir/search.json"
run_escalate 'TEST-9000 exists'
no_issue_writes
[[ $(wc -l <"$test_dir/curl-calls.jsonl") -eq 1 ]]
echo 'PASS escalate: 再実行・閉じたタスク・タイトルが変わった タスクも重複作成しない'
echo 'PASS escalate: 紐付け済みのタスクは、人間が外した紐付けも戻さない'

for failure in status env metadata; do
	escalate_fixture
	case $failure in
	status) printf '404' >"$test_dir/curl-status" ;;
	env) unset MULTICA_TOKEN ;;
	metadata) printf 'issue metadata list\n' >"$test_dir/multica-fail" ;;
	esac
	bash "$script" example/template project-a escalate 1 "$test_dir/escalation.md" --assignee 'Owner Name' >"$test_dir/output" 2>"$test_dir/error"
	[[ $(<"$test_dir/output") == 'TEST-9000 created' ]]
	grep -q 'TEST-9000 に PR を紐付けられませんでした' "$test_dir/error"
	jq -e 'has("pr_url") | not' "$test_dir/metadata.json" >/dev/null
	export MULTICA_TOKEN=mat_test-token
	rm -f "$test_dir/multica-fail"
	printf '200' >"$test_dir/curl-status"
	: >"$test_dir/curl-calls.jsonl"
	run_escalate 'TEST-9000 exists'
	[[ $(wc -l <"$test_dir/curl-calls.jsonl") -eq 1 ]]
	jq -e '.pr_url == "https://github.com/example/template/pull/1"' "$test_dir/metadata.json" >/dev/null
done
echo 'PASS escalate: 紐付けに失敗してもタスクを返して警告し、次の回に同じタスクへ補う'

escalate_fixture
cli_fixture issue-search | jq '.issues[0] as $base | .issues = [range(1;26) | $base + {id:(tostring), identifier:("TEST-"+tostring),
	 title:"別の PR（example/template#10）", description:"example/template#1 に言及"}]' >"$test_dir/search.json"
run_escalate 'TEST-9000 created'
echo 'PASS escalate: 本文だけの言及や似た PR 番号は同じタスクと取り違えない（既定の 20 件以上も検索）'

for invalid in unknown duplicate missing-id; do
	escalate_fixture
	case $invalid in
	unknown) printf '[]' >"$test_dir/members.json" ;;
	duplicate) jq '.[0] as $base | . + [$base + {user_id:"member-b"}]' "$test_dir/members.json" >"$test_dir/edit.json"; mv "$test_dir/edit.json" "$test_dir/members.json" ;;
	missing-id) touch "$test_dir/allow-missing-fields"; jq 'map(del(.user_id))' "$test_dir/members.json" >"$test_dir/edit.json"; mv "$test_dir/edit.json" "$test_dir/members.json" ;;
	esac
	if bash "$script" example/template project-a escalate 1 "$test_dir/escalation.md" --assignee 'Owner Name' >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
	[[ ! -s $test_dir/output ]]
	no_issue_writes
done
echo 'PASS escalate: メンバー不明・同名・user_id なしは作成せず拒否'

for target in labels search pr; do
	escalate_fixture
	case $target in
	labels) printf '[]\n' >"$test_dir/labels.json" ;;
	search) touch "$test_dir/allow-missing-fields"; printf '{}'  >"$test_dir/search.json" ;;
	pr) edit_pr '.author.login = "human"' ;;
	esac
	if bash "$script" example/template project-a escalate 1 "$test_dir/escalation.md" --assignee 'Owner Name' >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
	[[ ! -s $test_dir/output ]]
	no_issue_writes
done
escalate_fixture
cli_fixture issue-search | jq '.issues[0] as $base | .issues = [range(0;1000) | $base + {title:"別のタスク"}]' >"$test_dir/search.json"
if bash "$script" example/template project-a escalate 1 "$test_dir/escalation.md" --assignee 'Owner Name' >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
grep -q '検索結果が上限' "$test_dir/error"
no_issue_writes
echo 'PASS escalate: ラベル不明・検索結果の異常や上限・対象外の PR は作成しない'

for failure in 'issue search' 'label list' 'workspace member' 'issue create'; do
	escalate_fixture
	printf '%s\n' "$failure" >"$test_dir/multica-fail"
	if bash "$script" example/template project-a escalate 1 "$test_dir/escalation.md" --assignee 'Owner Name' >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
	[[ ! -s $test_dir/output ]]
	grep -q 'Multica mock failure' "$test_dir/error"
	[[ ! -e $test_dir/created.json ]]
	while IFS= read -r file; do [[ ! -e $file ]]; done <"$test_dir/description-files"
done
echo 'PASS escalate: CLI の取得・作成失敗を伝え、一時本文を片付ける'

escalate_fixture
printf 'issue label add\n' >"$test_dir/multica-fail"
if bash "$script" example/template project-a escalate 1 "$test_dir/escalation.md" --assignee 'Owner Name' >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
[[ ! -s $test_dir/output && -f $test_dir/created.json ]]
grep -q '同じタスクに補います' "$test_dir/error"
while IFS= read -r file; do [[ ! -e $file ]]; done <"$test_dir/description-files"
rm "$test_dir/multica-fail"
run_escalate 'TEST-9000 exists'
jq -se '[.[] | select(.[0:2] == ["issue","create"])] | length == 1' "$test_dir/multica-calls.jsonl" >/dev/null
jq -e '.[0].name == "運用"' "$test_dir/issue-labels.json" >/dev/null
echo 'PASS escalate: ラベル付与の失敗後も新規作成せず、同じタスクにラベルを補う'

# 同じリポジトリと PR でも、別プロジェクトのタスクでは抑止しない。
escalate_fixture
run_escalate 'TEST-9000 created'
: >"$test_dir/multica-calls.jsonl"
bash "$script" example/template project-b escalate 1 "$test_dir/escalation.md" --assignee 'Owner Name' >"$test_dir/output" 2>"$test_dir/error"
[[ $(<"$test_dir/output") == 'TEST-9000 created' && ! -s $test_dir/error ]]
jq -e '.project_id == "project-b"' "$test_dir/created.json" >/dev/null
jq -se '[.[] | select(.[0:2] == ["issue","create"])] | length == 1' "$test_dir/multica-calls.jsonl" >/dev/null
echo 'PASS 引数のプロジェクト: 指定したプロジェクトへ作り、別プロジェクトの同じ PR のタスクは再利用しない'

reset_fixture
bash "$script" another/service project-b list >"$test_dir/output" 2>"$test_dir/error"
jq -se '. == [["api","repos/another/service/pulls?state=open&per_page=100","--paginate"]]' "$test_dir/calls.jsonl" >/dev/null
[[ ! -s $test_dir/error ]]
echo 'PASS 引数のリポジトリ: 固定値ではなく、受け取った対象へ問い合わせる'

reject_target() {
	: >"$test_dir/calls.jsonl"
	: >"$test_dir/multica-calls.jsonl"
	local code=0
	bash "$script" "$@" >"$test_dir/output" 2>"$test_dir/error" || code=$?
	[[ $code == 2 && ! -s $test_dir/output && -s $test_dir/error ]]
	[[ ! -s $test_dir/calls.jsonl && ! -s $test_dir/multica-calls.jsonl ]]
}
reject_target
reject_target example/template
reject_target example/template '' list
reject_target invalid-repo project-a list
reject_target example/template project-a unknown
echo 'PASS 引数の検査: 対象やコマンドが欠けているときは、CLI を呼ばず使い方を返す'

existing_escalation() {
 cli_fixture issue-search | jq '.issues[0] as $base | .issues=[$base + {
  id:"issue-a",identifier:"TEST-9000",project_id:"project-a",title:"確認（example/template#1）"}]' >"$test_dir/search.json"
 cli_fixture issue-labels | jq '[. + {id:"label-a"}]' >"$test_dir/issue-labels.json"
}
for repository in absent same other; do
 for linked in absent value null empty; do
  escalate_fixture
  existing_escalation
  jq --arg repository "$repository" --arg linked "$linked" '
   (if $repository == "same" then .repository="example/template"
    elif $repository == "other" then .repository="other/service" else del(.repository) end)
   | if $linked == "value" then .pr_url="https://github.com/example/template/pull/1"
     elif $linked == "null" then .pr_url=null
     elif $linked == "empty" then .pr_url="" else del(.pr_url) end' \
   "$test_dir/metadata.json" >"$test_dir/next.json"
  mv "$test_dir/next.json" "$test_dir/metadata.json"
  bash "$script" example/template project-a escalate 1 "$test_dir/escalation.md" --assignee 'Owner Name' >"$test_dir/output" 2>"$test_dir/error"
  [[ $(<"$test_dir/output") == 'TEST-9000 exists' ]]
  if [[ $repository != other && $linked == absent ]]; then
   [[ $(jq -s length "$test_dir/curl-calls.jsonl") == 1 && ! -s $test_dir/error ]]
   jq -e '.pr_url=="https://github.com/example/template/pull/1"' "$test_dir/metadata.json" >/dev/null
  else
   [[ ! -s $test_dir/curl-calls.jsonl ]]
   jq -se 'all(.[]; .[0:3] != ["issue","metadata","set"])' "$test_dir/multica-calls.jsonl" >/dev/null
   if [[ $repository == other ]]; then grep -F '紐付けられませんでした' "$test_dir/error" >/dev/null; else [[ ! -s $test_dir/error ]]; fi
  fi
 done
done
echo 'PASS presence: Dependabot も metadata の鍵を保ち、初回だけ紐付け、別リポジトリは拒否する'

escalate_fixture
existing_escalation
jq '.issues[0].project_id=null' "$test_dir/search.json" >"$test_dir/edit.json"
mv "$test_dir/edit.json" "$test_dir/search.json"
run_escalate 'TEST-9000 created'
echo 'PASS project_id: プロジェクトのない検索結果を受け入れ、対象プロジェクトのタスクと取り違えない'

for defect in resource-type search-project member-email issue-label-id create-id create-identifier; do
 escalate_fixture
 touch "$test_dir/allow-missing-fields"
 case $defect in
 resource-type) reading=label-list; field=resource_type; source=labels; filter='map(del(.resource_type))' ;;
 search-project) existing_escalation; reading=issue-search; field=project_id; source=search; filter='del(.issues[0].project_id)' ;;
 member-email) reading=member-list; field=email; source=members; filter='map(del(.email))' ;;
 issue-label-id) existing_escalation; reading=issue-labels; field=id; source=issue-labels; filter='map(del(.id))' ;;
 create-id|create-identifier)
  reading=issue-create; field=id; [[ $defect != create-identifier ]] || field=identifier
  source=create-response; cp "$test_dir/create-prototype.json" "$test_dir/create-response.json"; filter="del(.$field)" ;;
 esac
 jq "$filter" "$test_dir/$source.json" >"$test_dir/edit.json"
 mv "$test_dir/edit.json" "$test_dir/$source.json"
 status=0
 bash "$script" example/template project-a escalate 1 "$test_dir/escalation.md" --assignee 'Owner Name' >"$test_dir/output" 2>"$test_dir/error" || status=$?
 [[ $status == 1 && ! -s $test_dir/output && ! -s $test_dir/curl-calls.jsonl ]]
 expected_field=$field
 [[ $reading != issue-search ]] || expected_field="issues[].$field"
 grep -F "$reading の $expected_field" "$test_dir/error" >/dev/null
 if [[ $reading == issue-create ]]; then
  jq -se '[.[] | select(.[0:2]==["issue","create"])] | length==1' "$test_dir/multica-calls.jsonl" >/dev/null
  jq -se 'all(.[]; .[0:3] != ["issue","label","add"])' "$test_dir/multica-calls.jsonl" >/dev/null
 else no_issue_writes; fi
 echo "PASS contract: $reading の $field の欠落を欄名で返し、後続を書かない"
done

# 任意の integration_id を補うと、別 App の成功で通ってしまうので、存在を両方確かめる。
for app in absent specified; do
 reset_fixture
 add_pr 1 dependabot/go_modules/api/example "$(metadata patch)"
 gh_fixture gh-branch-rules | jq --arg app "$app" '.parameters.required_status_checks[0] as $check |
  .parameters.required_status_checks=[$check + {context:"lint",integration_id:15368}] |
  if $app=="absent" then del(.parameters.required_status_checks[0].integration_id) else . end | [.]' >"$test_dir/gh-defect.gh-branch-rules.json"
 printf '{"check_runs":[{"id":1,"name":"lint","app":{"id":999},"status":"completed","conclusion":"success"}]}' >"$test_dir/checks.json"
 run_list
 if [[ $app == absent ]]; then assert_output '.[0].ci=="success"'; else assert_output '.[0].ci=="pending"'; fi
done
echo 'PASS GH optional: integration_id の省略は任意の App、指定ありはその App だけを通す'

reset_fixture
add_pr 1 dependabot/docker/example "$(metadata '')"
gh_fixture gh-pr-files | jq '[del(.patch) + {status:"modified",additions:1,deletions:1}]' >"$test_dir/gh-defect.gh-pr-files.json"
run_list
assert_output '.[0].update_type=="major"'
echo 'PASS GH optional: patch がなければ digest の更新と決めつけない'

for defect in pulls-number rule-context pr-author commit-message check-app status-context file-additions head comments-body viewer-login; do
 advance_fixture
 action=list
 args=()
 case $defect in
 pulls-number) reading=gh-dependabot-pulls; field=number; filter='[del(.number)]' ;;
 rule-context) reading=gh-branch-rules; field=context; filter='[del(.parameters.required_status_checks[0].context)]' ;;
 pr-author) reading=gh-dependabot-pr; field=author.login; filter='del(.author.login)' ;;
 commit-message) reading=gh-commit; field=commit.message; filter='del(.commit.message)' ;;
 check-app) reading=gh-check-runs; field=app.id; filter='del(.check_runs[0].app.id)' ;;
 status-context) reading=gh-statuses; field=context; filter='[del(.context)]' ;;
 file-additions|head)
  edit_pr '.headRefName="dependabot/docker/example"'
  digest_files >"$test_dir/files.json"
  if [[ $defect == head ]]; then reading=gh-pr-head; field=headRefOid; filter='del(.headRefOid)'
  else reading=gh-pr-files; field=additions; filter='[del(.additions)]'; fi ;;
 comments-body|viewer-login)
  action=advance
  args=(1 --reviewed-head "$reviewed" --run-deadline "$run_deadline")
  edit_pr '.mergeStateStatus="BEHIND"'
  if [[ $defect == comments-body ]]; then reading=gh-pr-comments; field=body; filter='[del(.body)]'
  else reading=gh-viewer; field=login; filter='del(.login)'; fi ;;
 esac
 gh_fixture "$reading" | jq "$filter" >"$test_dir/gh-defect.$reading.json"
 status=0
 bash "$script" example/template project-a "$action" "${args[@]}" >"$test_dir/output" 2>"$test_dir/error" || status=$?
 [[ $status != 0 && ! -s $test_dir/output ]]
 grep -F "$reading の " "$test_dir/error" >/dev/null
 grep -F "$field" "$test_dir/error" >/dev/null
 no_writes
 echo "PASS GH contract: $reading の $field の欠落を欄名で返す"
done

# 差分の取得を呼び出す分岐でも、JSON の欠落を changed の成功応答に変えない。
advance_fixture
edit_pr '.mergeStateStatus="BEHIND"'
gh_fixture gh-pr-head | jq 'del(.headRefOid)' >"$test_dir/gh-defect.gh-pr-head.json"
if bash "$script" example/template project-a advance 1 --reviewed-head "$reviewed" --run-deadline "$run_deadline" >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
[[ ! -s $test_dir/output ]]
grep -F 'gh-pr-head の headRefOid' "$test_dir/error" >/dev/null
no_writes
echo 'PASS GH contract: 差分の確認中の head の欠落も、操作せず失敗する'

# 公開元では見本がない nullable な親も、公式スキーマどおり受け入れる。
reset_fixture
add_pr 1 dependabot/go_modules/api/example "$(metadata patch)"
gh_fixture gh-dependabot-pulls | jq '[.user=null]' >"$test_dir/gh-defect.gh-dependabot-pulls.json"
run_list
assert_output '.==[]'
reset_fixture
add_pr 1 dependabot/go_modules/api/example "$(metadata patch)"
edit_pr '.author=null'
run_list
assert_output '.==[]'
echo 'PASS GH nullable: 作者が null の PR は分類の対象にしない'

for app in any specified; do
 reset_fixture
 add_pr 1 dependabot/go_modules/api/example "$(metadata patch)"
 jq --arg app "$app" '.[0].parameters.required_status_checks[0].integration_id=(if $app=="any" then null else 15368 end)' \
  "$test_dir/rules.json" >"$test_dir/edit.json"
 mv "$test_dir/edit.json" "$test_dir/rules.json"
 jq '.check_runs[0].app=null' "$test_dir/checks.json" >"$test_dir/edit.json"
 mv "$test_dir/edit.json" "$test_dir/checks.json"
 run_list
 if [[ $app == any ]]; then assert_output '.[0].ci=="success"'; else assert_output '.[0].ci=="pending"'; fi
done
echo 'PASS GH nullable: app が null のチェックでも App の指定の有無を区別する'

advance_fixture
edit_pr '.mergeStateStatus="BEHIND"'
gh_fixture gh-pr-comments | jq '[.user=null]' >"$test_dir/gh-defect.gh-pr-comments.json"
run_advance waiting
jq -se '[.[] | select(.[0:2]==["pr","comment"])] | length==1' "$test_dir/calls.jsonl" >/dev/null
echo 'PASS GH nullable: 作者が null のコメントを今回の依頼と取り違えない'
