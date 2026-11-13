#!/usr/bin/env bash
# squad-dependabot-merge-*-test.sh が読み込む共通の準備。単独では実行しない。
# 呼び出し元が root を定めてから読み込む。
script="$root/common/monitor/squad-dependabot-merge"
mkdir -p tmp
test_dir=$(mktemp -d "$PWD/tmp/dependabot-merge-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
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
stub_args=("$@")
# 記録と見本の返却は、補助の 1 回の呼び出しで済ませる。見本を返さずに終わる呼び出しは、終了時に記録だけする。
stub() { recorded=1; python3 "$DEPENDABOT_MERGE_TEST_ROOT/tests/cli-stub.py" gh "$dir" gh calls.jsonl "$@" -- ${stub_args[@]+"${stub_args[@]}"}; }
if [[ ${1-} == --version ]]; then
	python3 "$DEPENDABOT_MERGE_TEST_ROOT/tests/cli-stub.py" gh "$dir" gh - record -- "$@"
	echo 'gh fixture-version'; exit 0
fi
recorded=
trap '[[ -n $recorded ]] || stub record' EXIT
emit() {
 local name=$1 file=$2
 if [[ -f $dir/gh-defect.$name.json ]]; then stub raw "$name" "$dir/gh-defect.$name.json"
 else stub emit "$name" "$file"; fi
}
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

digest_files() {
	local old new
	old=$(printf '%064d' 1)
	new=$(printf '%064d' 2)
	jq -n --arg old "$old" --arg new "$new" '[{
		filename: "Dockerfile.api", status: "modified", additions: 1, deletions: 1,
		patch: ("@@ -1 +1 @@\n-FROM debian:stable@sha256:" + $old + "\n+FROM debian:stable@sha256:" + $new)
	}]'
}
