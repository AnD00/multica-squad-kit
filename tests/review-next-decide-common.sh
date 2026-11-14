# squad-review-next-decide-*-test.sh が読み込む共通の準備（スタブ・見本・補助）。単独では実行しない。
# squad-review-wait・squad-pr-watch・squad-usage-wait を差し替え、multica と gh は見本で照合する偽の CLI にする。
# 実際のタスク・PR・エージェントには書き込まない。
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
mkdir -p tmp
test_dir=$(mktemp -d "$PWD/tmp/review-next-decide-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
export REVIEW_NEXT_TEST_DIR=$test_dir REVIEW_NEXT_TEST_ROOT=$root REVIEW_WAIT_TEST_DIR=$test_dir
source "$root/common/monitor/squad-cli-lib"
squad_cli_contracts >"$test_dir/contracts.json"
fixture() { python3 "$root/tests/review-wait-fixture.py" base "$@"; }

mkdir -p "$test_dir/monitor" "$test_dir/bin"
cp "$root/common/monitor/squad-review-next" "$root/common/monitor/squad-cli-lib" "$test_dir/monitor/"
export PATH="$test_dir/bin:$PATH"

# 返事の待ちの見張りの代わり。受けた引数を記録し、決めた終了コードを返す。
cat >"$test_dir/monitor/squad-review-wait" <<'EOF'
#!/usr/bin/env bash
dir=$REVIEW_NEXT_TEST_DIR
printf '%s\n' "$*" >>"$dir/watch-calls"
exit "$(<"$dir/watch-status")"
EOF

# PR の見張りの代わり。サブコマンドごとに、受けた引数を記録し、決めた出力と終了コードを返す。
# 出力は <名前>-out、終了コードは <名前>-status。同じサブコマンドの n 回目は <名前>-out.n があればそちらを使う。
cat >"$test_dir/monitor/squad-pr-watch" <<'EOF'
#!/usr/bin/env bash
dir=$REVIEW_NEXT_TEST_DIR
printf '%s\n' "$*" >>"$dir/pr-watch-calls"
cmd=${1:-}
count=$(grep -c "^$cmd " "$dir/pr-watch-calls" || true)
file_of() { if [[ -f $dir/$1.$count ]]; then echo "$dir/$1.$count"; else echo "$dir/$1"; fi; }
out_of() { local f; f=$(file_of "$1"); [[ ! -f $f ]] || cat "$f"; }
status_of() { local f; f=$(file_of "$1"); if [[ -f $f ]]; then cat "$f"; else echo 0; fi; }
case $cmd in
link-check) out_of link-out; exit "$(status_of link-status)" ;;
ci-held) out_of held-out; exit "$(status_of held-status)" ;;
ci) exit "$(status_of ci-status)" ;;
ci-now) out_of cinow-out; exit "$(status_of cinow-status)" ;;
conflicts-check) out_of conf-out; exit "$(status_of conf-status)" ;;
ci-wait) out_of ciwait-out; exit "$(status_of ciwait-status)" ;;
ci-wait-clear) exit "$(status_of clear-status)" ;;
conflicts) out_of conflicts-out; exit "$(status_of conflicts-status)" ;;
unlinked) out_of unlinked-out; exit "$(status_of unlinked-status)" ;;
*) echo "想定外のサブコマンド: $cmd" >&2; exit 1 ;;
esac
EOF

# 使用率の待ちの代わり。
cat >"$test_dir/monitor/squad-usage-wait" <<'EOF'
#!/usr/bin/env bash
dir=$REVIEW_NEXT_TEST_DIR
printf '%s\n' "$*" >>"$dir/pick-calls"
cat "$dir/pick-out"
exit "$(<"$dir/pick-status")"
EOF
chmod +x "$test_dir/monitor/squad-review-wait" "$test_dir/monitor/squad-pr-watch" "$test_dir/monitor/squad-usage-wait"

cat >"$test_dir/bin/multica" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
dir=$REVIEW_NEXT_TEST_DIR
stub_args=("$@")
stub() { python3 "$REVIEW_NEXT_TEST_ROOT/tests/cli-stub.py" review-wait "$dir" multica calls.jsonl "$@" -- ${stub_args[@]+"${stub_args[@]}"}; }
case "${1-} ${2-} ${3-}" in
'version  ') echo 'multica fixture-version' ;;
'issue get test-issue')
	# ci_wait_head は CLI の固定欄でなく、この機能が保存する値。見本の鍵は外した写しで検査し、本物の値はそのまま返す。
	jq 'del(.metadata.ci_wait_head)' "$dir/issue.json" >"$dir/issue-checked.json"
	stub emit issue-get "$dir/issue-checked.json" >/dev/null
	cat "$dir/issue.json" ;;
'issue label list') stub emit issue-labels "$dir/issue-labels.json" ;;
'label list --output') stub emit label-list "$dir/labels.json" ;;
'squad list --output') stub emit squad-list "$dir/squads.json" ;;
'squad member list') stub emit squad-member-list "$dir/members.json" ;;
'issue comment list')
	[[ ! -f $dir/comments-fail ]] || { echo 'CLI mock comment list failure' >&2; exit 1; }
	stub emit issue-comments "$dir/comments.json" ;;
'issue runs test-issue')
	[[ ! -f $dir/runs-fail ]] || { echo 'CLI mock runs failure' >&2; exit 1; }
	stub emit issue-runs "$dir/runs.json" ;;
'workspace member list') stub emit member-list "$dir/human-members.json" ;;
'issue status test-issue') printf '%s\n' "$*" >>"$dir/status-calls" ;;
"agent get $3")
	jq --arg id "$3" '.[] | select(.id == $id)' "$dir/agents.json" >"$dir/agent-response.json"
	stub emit agent-get "$dir/agent-response.json" ;;
'issue comment add')
	[[ ! -f $dir/post-fail ]] || { echo 'CLI mock comment add failure' >&2; exit 1; }
	args=$(jq -cn --args '$ARGS.positional' -- "$@")
	file=$(jq -er 'index("--content-file") as $i | .[$i+1]' <<<"$args")
	jq -Rs --argjson args "$args" '{args: $args, body: .}' <"$file" >>"$dir/posted.jsonl"
	stub posted issue-comment-add posted-comment ;;
*) echo "Unexpected mock call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$test_dir/bin/multica"

cat >"$test_dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
dir=$REVIEW_NEXT_TEST_DIR
stub_args=("$@")
stub() { python3 "$REVIEW_NEXT_TEST_ROOT/tests/cli-stub.py" gh "$dir" gh calls-gh.jsonl "$@" -- ${stub_args[@]+"${stub_args[@]}"}; }
if [[ ${1-} == api ]]; then
	case "${2-}" in
	--help)
		printf 'FLAGS\n      --paginate        Make additional HTTP requests to fetch all pages of results\n  -X, --method string   The HTTP method for the request\n' ;;
	'repos/demo/project/compare/'*)
		echo "${2#repos/demo/project/compare/}" >>"$dir/compare-calls"
		[[ ! -f $dir/compare-fail ]] || { echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }
		stub emit gh-compare "$dir/compare.json" ;;
	'repos/demo/project/pulls/7/files?per_page=100')
		[[ ${3-} == --paginate ]]
		[[ ! -f $dir/files-fail ]] || { echo 'gh: Bad Gateway (HTTP 502)' >&2; exit 1; }
		stub emit gh-pr-files "$dir/files.json" ;;
	'repos/demo/project/contents/.agents/review-paths?ref='*)
		echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
	*) echo "Unexpected mock call: $*" >&2; exit 1 ;;
	esac
elif [[ ${1-} == pr && ${2-} == view && ${3-} == 7 && ${4-} == --repo && ${5-} == demo/project && ${*: -1} == *baseRefName* ]]; then
	jq '.baseRefName = "release"' <(python3 "$REVIEW_NEXT_TEST_ROOT/tests/review-wait-fixture.py" base gh-dependabot-pr) >"$dir/pr.json"
	stub emit gh-dependabot-pr "$dir/pr.json"
elif [[ ${1-} == pr && ${2-} == view && ${3-} == 7 && ${4-} == --repo && ${5-} == demo/project && ${*: -1} == headRefOid ]]; then
	echo "$*" >>"$dir/head-calls"
	[[ ! -f $dir/head-fail ]] || { echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }
	stub emit gh-pr-head "$dir/head.json"
else
	echo "Unexpected mock call (書き込みは禁止): $*" >&2
	exit 1
fi
EOF
chmod +x "$test_dir/bin/gh"

fail() { printf '%s\n' "$*" >&2; exit 1; }
sha=0123456789abcdef0123456789abcdef01234567
old=fedcba9876543210fedcba9876543210fedcba98
pr_url=https://github.com/demo/project/pull/7

# --- 見本。エージェントの名前は <プロジェクトのキー>-<役>-<メンバーのキー> で、スクワッドの名前は DEMO-TEST。
jq '.[2] + {assignee_type: "squad", assignee_id: "squad-test"}
	| .metadata += {pr_url: "https://github.com/demo/project/pull/7", repository: "demo/project"}' \
	"$root/tests/fixtures/cli/issue-get.json" >"$test_dir/issue.base.json"
fixture squad-list | jq '[. + {id: "squad-test", name: "DEMO-TEST", leader_id: "orchestrator", creator_id: "human-1", archived_at: null}]' >"$test_dir/squads.json"
fixture member-list | jq '[. + {user_id: "human-1", name: "Owner"}]' >"$test_dir/human-members.json"
fixture label-list | jq '. as $base | [
	$base + {id: "label-imp", name: "重要", resource_type: "issue"},
	$base + {id: "label-dev", name: "開発", resource_type: "issue"}
]' >"$test_dir/labels.json"
agent_roles=(code-reviewer ux-reviewer security-reviewer performance-reviewer qa claude-implementer codex-implementer claude-fixer codex-fixer claude-principal codex-principal designer ci-monitor)
agent_values=$(jq -n --argjson roles "$(printf '%s\n' "${agent_roles[@]}" | jq -R . | jq -sc .)" '[$roles[] | {id: ., name: ("demo-" + . + "-test"), model: (if startswith("codex-") then "gpt-5.5" else "claude-sonnet-5-5" end), archived_at: null}
	] + [{id: "orchestrator", name: "demo-orchestrator-test", model: "claude-fable-5-2", archived_at: null}]')
fixture agent-get | jq --argjson values "$agent_values" '. as $base | [$values[] | $base + .]' >"$test_dir/agents.base.json"
set_roster() {
	fixture squad-member-list | jq --args '. as $base | [$ARGS.positional[] | $base + {member_id: ., member_type: "agent"}]' -- "$@" >"$test_dir/members.json"
}
set_designer_model() {
	jq --arg model "$1" 'map(if .id == "designer" then .model = $model else . end)' "$test_dir/agents.json" >"$test_dir/agents.new" && mv "$test_dir/agents.new" "$test_dir/agents.json"
}
set_issue_labels() { # ラベルの ID...
	fixture issue-labels | jq --args '. as $base | [$ARGS.positional[] | $base + {id: .}]' -- "$@" >"$test_dir/issue-labels.json"
}
set_metadata() { # 鍵 値
	jq --arg key "$1" --arg value "$2" '.metadata[$key] = $value' "$test_dir/issue.json" >"$test_dir/issue.new" && mv "$test_dir/issue.new" "$test_dir/issue.json"
}

# コメントの見本と、時刻を進めるカウンタ。
comment_base=$(fixture issue-comments agent)
n=0
add() { # ID 書いた役 本文 [返信先]
	n=$((n + 1))
	jq --argjson base "$comment_base" --arg id "$1" --arg author "$2" --arg content "$3" --arg parent "${4-round-0}" \
		--arg at "$(printf '2026-11-10T12:%02d:%02dZ' $((n / 60)) $((n % 60)))" \
		'. + [$base + {id: $id, author_id: $author, author_type: (if $author == "human-1" then "member" else "agent" end), content: $content, created_at: $at, parent_id: $parent}]' \
		"$test_dir/comments.json" >"$test_dir/comments.new"
	mv "$test_dir/comments.new" "$test_dir/comments.json"
}
mention() { printf '[@demo-%s-test](mention://agent/%s)' "$1" "$1"; }
mentions() { local out='' role; for role; do out+="${out:+ }$(mention "$role")"; done; printf '%s' "$out"; }
review_round() { # 回の ID コミット 役...
	local id=$1 commit=$2
	shift 2
	add "$id" orchestrator "確認するコミット: ${commit}"$'\n'"返事を待つ役: $(mentions "$@")"$'\n'"観点: $*（テスト）"$'\n'"対象の PR: ${pr_url}"
}
result() { # 回の ID 役 マーク コミット 設計への指摘 [本文]
	add "res-$2-$n" "$2" $'/note\n返事の回: '"$1"$'\n確認したコミット: '"$4"$'\n設計への指摘: '"$5"$'\n\n'"$3 demo-$2-test: ${6-結果}"
}
all_ok() { # 回の ID コミット 役...
	local round=$1 commit=$2 role
	shift 2
	for role; do result "$round" "$role" ✅ "$commit" なし; done
}
# 最終レビューの回は、レビューの回を指す。指す回がまだなければ、同じコミットのレビューの回をリーダーが書いたものとして足す。
final_round() { # 回の ID コミット 前の回 [範囲]
	jq -e --arg id "$3" 'any(.[]; .id == $id)' "$test_dir/comments.json" >/dev/null || review_round "$3" "$2" code-reviewer qa
	add "$1" orchestrator "見直しの種類: 最終レビュー"$'\n'"確認するコミット: $2"$'\n'"見る範囲: ${4-PR の差分全体}"$'\n'"返事を待つ役: $(mentions claude-principal)"$'\n'"$principal_line"$'\n'"前の回: $3"$'\n'"対象の PR: ${pr_url}"
}
posted_body() { jq -rs '.[0].body' "$test_dir/posted.jsonl"; }

principal_line='振り分け: Claude で足りる。工程: principal'
status=0
reset() {
	: >"$test_dir/calls.jsonl"
	: >"$test_dir/calls-gh.jsonl"
	: >"$test_dir/watch-calls"
	: >"$test_dir/posted.jsonl"
	: >"$test_dir/pr-watch-calls"
	: >"$test_dir/pick-calls"
	: >"$test_dir/status-calls"
	: >"$test_dir/compare-calls"
	: >"$test_dir/head-calls"
	rm -f "${test_dir:?}/post-fail" "${test_dir:?}/comments-fail" "${test_dir:?}/runs-fail" "${test_dir:?}/compare-fail" "${test_dir:?}/head-fail"
	: >"$test_dir/files-fail"
	rm -f "${test_dir:?}"/conflicts-out* "${test_dir:?}"/conflicts-status* "${test_dir:?}"/unlinked-out* "${test_dir:?}"/unlinked-status*
	rm -f "${test_dir:?}"/link-out* "${test_dir:?}"/link-status* "${test_dir:?}"/held-out* "${test_dir:?}"/held-status* "${test_dir:?}"/ci-status*
	rm -f "${test_dir:?}"/cinow-out* "${test_dir:?}"/cinow-status* "${test_dir:?}"/conf-out* "${test_dir:?}"/conf-status* "${test_dir:?}"/clear-status*
	rm -f "${test_dir:?}"/ciwait-out* "${test_dir:?}"/ciwait-status*
	echo 0 >"$test_dir/watch-status"
	printf '紐付け: 紐付いている pr: %s\n' "$pr_url" >"$test_dir/link-out"
	printf 'コンフリクト: MERGEABLE head: %s\n' "$sha" >"$test_dir/conf-out"
	printf 'CI %s: 成功\n' "$sha" >"$test_dir/ciwait-out"
	printf '{"headRefOid": "%s"}\n' "$sha" >"$test_dir/head.json"
	printf '{"id": "rule-1"}\n見張り: 1 時間おき、2026-11-17 まで\n' >"$test_dir/unlinked-out"
	printf '役: claude-fixer\n振り分け: Claude で足りる。工程: fix\n' >"$test_dir/pick-out"
	echo 0 >"$test_dir/pick-status"
	cp "$test_dir/agents.base.json" "$test_dir/agents.json"
	cp "$test_dir/issue.base.json" "$test_dir/issue.json"
	echo '[]' >"$test_dir/comments.json"
	echo '[]' >"$test_dir/runs.json"
	fixture gh-compare | jq '.status = "ahead"' >"$test_dir/compare.json"
	set_roster orchestrator "${agent_roles[@]}"
	set_issue_labels label-dev
	n=0
}
# 変えたファイルを決める。決めなければ、読めない扱いになり、観点はすべて選ばれる。
set_changed_files() { # ファイル名...
	rm -f "${test_dir:?}/files-fail"
	fixture gh-pr-files | jq --args '. as $base | [$ARGS.positional[] | $base + {filename: ., status: "modified"}]' -- "$@" >"$test_dir/files.json"
}
# マージの依頼まで進める構成。CI の見張り役がいない名簿にする（ある構成は set_ci_merge_roster）。
set_merge_roster() {
	set_roster orchestrator code-reviewer ux-reviewer security-reviewer performance-reviewer qa claude-implementer codex-implementer claude-fixer codex-fixer claude-principal codex-principal designer
}
# マージの依頼まで進める構成で、CI の見張り役がいる名簿にする。CI は squad-pr-watch ci-wait で待つ。
set_ci_merge_roster() {
	set_roster orchestrator code-reviewer ux-reviewer security-reviewer performance-reviewer qa claude-implementer codex-implementer claude-fixer codex-fixer claude-principal codex-principal designer ci-monitor
}
run() { # 回の ID
	status=0
	(cd "$test_dir" && bash monitor/squad-review-next decide test-issue "$@") >"$test_dir/out" 2>"$test_dir/err" || status=$?
}
expect_status() {
	[[ $status == "$1" ]] || { printf '終了コード %s を期待したが %s\n出力:\n%s\n標準エラー:\n%s\n' "$1" "$status" "$(<"$test_dir/out")" "$(<"$test_dir/err")" >&2; exit 1; }
}
expect_nothing_written() {
	[[ ! -s $test_dir/posted.jsonl ]] || fail "コメントを書いてはいけない: $(<"$test_dir/posted.jsonl")"
	[[ ! -s $test_dir/status-calls ]] || fail "状態を変えてはいけない: $(<"$test_dir/status-calls")"
	[[ ! -s $test_dir/watch-calls ]] || fail "見張りを入れてはいけない: $(<"$test_dir/watch-calls")"
}
# リーダーに任せる。何も書かず、状態も変えず、理由を出して 3 で終わる。
expect_leader() { # 理由に含まれる文字列
	expect_status 3
	[[ $(<"$test_dir/out") == '次の依頼を決められません: '*"$1"* ]] || fail "理由に「$1」がない: $(<"$test_dir/out")"
	[[ $(wc -l <"$test_dir/out") -eq 1 ]] || fail "出力が 1 行でない: $(<"$test_dir/out")"
	expect_nothing_written
}
# 書けずに失敗する。終了コード 1 で、標準エラーに理由を出す。
expect_failure() { # 標準エラーに含まれる文字列
	expect_status 1
	[[ $(<"$test_dir/err") == *'次の依頼を書けません: '*"$1"* ]] || fail "標準エラーに「$1」がない: $(<"$test_dir/err")"
	[[ ! -s $test_dir/posted.jsonl ]] || fail "コメントを書いてはいけない: $(<"$test_dir/posted.jsonl")"
}
expect_posted() { # 種類 本文 [返信先]
	expect_status 0
	[[ $(jq -s length "$test_dir/posted.jsonl") == 1 ]] || fail "コメントが 1 件でない: $(<"$test_dir/posted.jsonl")"
	jq -e --arg parent "${3-round-1}" '.args[0:3] == ["issue", "comment", "add"] and .args[3] == "test-issue" and (.args | index("--parent") as $i | .[$i + 1]) == $parent' "$test_dir/posted.jsonl" >/dev/null \
		|| fail "投稿の引数が違う: $(<"$test_dir/posted.jsonl")"
	local actual
	actual=$(posted_body)
	[[ $actual == "$2" ]] || { printf '期待したコメント:\n%s\n実際のコメント:\n%s\n標準エラー:\n%s\n' "$2" "$actual" "$(<"$test_dir/err")" >&2; exit 1; }
	[[ $(<"$test_dir/out") == $'次の依頼: '"$1"$'\n依頼: posted-comment' ]] || fail "標準出力が違う: $(<"$test_dir/out")"
}
expect_calls() { # ファイル 期待する内容
	[[ $(<"$test_dir/$1") == "$2" ]] || fail "$1 が違う。期待: $2 実際: $(<"$test_dir/$1")"
}
expect_no_calls() { # ファイル
	[[ ! -s $test_dir/$1 ]] || fail "$1 に記録があってはいけない: $(<"$test_dir/$1")"
}
expect_call_has() { # ファイル 行
	grep -qxF -- "$2" "$test_dir/$1" || fail "$1 に「$2」がない: $(<"$test_dir/$1")"
}
expect_call_lacks() { # ファイル 行の始まり
	if grep -q -- "^$2" "$test_dir/$1"; then fail "$1 に「$2」があってはいけない: $(<"$test_dir/$1")"; fi
}
# 返事の組を 1 つ作る。回 round-1 で、code-reviewer と qa に頼む。
base_round() {
	add pr-made orchestrator "PR を作りました ${pr_url}" ""
	review_round round-1 "$sha" code-reviewer qa
}
ok_round() { # 回 round-1 に、全員が ✅ で返る。最上位の役の選びは claude-principal にしておく
	base_round
	all_ok round-1 "$sha" code-reviewer qa
	set_principal_pick claude-principal
}
final_request_body() { # 範囲 [役]
	printf '見直しの種類: 最終レビュー\n確認するコミット: %s\n見る範囲: %s\n返事を待つ役: %s\n%s\n前の回: round-1\n対象の PR: %s' "$sha" "$1" "$(mention "${2-claude-principal}")" "$principal_line" "$pr_url"
}
# マージの依頼の本文の見本。行 3 以降（確認の行）は、引数で渡す。
merge_body() { # 前の回 head 行...
	local round=$1 head=$2
	shift 2
	printf '[@Owner](mention://member/human-1) レビューと確認が済みました。PR のマージを判断してください。\nマージの依頼: %s\n前の回: %s\n' "$head" "$round"
	printf '%s\n' "$@"
}
# マージの依頼を書き、タスクを in_review にした。
expect_merge_posted() { # 本文 [返信先]
	expect_status 0
	[[ $(jq -s length "$test_dir/posted.jsonl") == 1 ]] || fail "コメントが 1 件でない: $(<"$test_dir/posted.jsonl")"
	local actual
	actual=$(posted_body)
	[[ $actual == "$1" ]] || { printf '期待したコメント:\n%s\n実際のコメント:\n%s\n標準エラー:\n%s\n' "$1" "$actual" "$(<"$test_dir/err")" >&2; exit 1; }
	jq -e --arg parent "${2-round-1}" '.args | index("--parent") as $i | .[$i + 1] == $parent' "$test_dir/posted.jsonl" >/dev/null || fail "返信先が違う: $(<"$test_dir/posted.jsonl")"
	[[ $(<"$test_dir/out") == $'次の依頼: マージの依頼\n依頼: posted-comment' ]] || fail "標準出力が違う: $(<"$test_dir/out")"
	expect_calls status-calls 'issue status test-issue in_review'
}
set_principal_pick() { printf '役: %s\n%s\n' "$1" "$principal_line" >"$test_dir/pick-out"; }
