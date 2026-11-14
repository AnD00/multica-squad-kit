#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-next-test.sh で実行する。
# squad-review-wait を差し替え、multica と gh は見本で照合する偽の CLI にする。
# 実際のタスク・PR・エージェントには書き込まない。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
mkdir -p tmp
test_dir=$(mktemp -d "$PWD/tmp/review-next-test.XXXXXX")
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
chmod +x "$test_dir/monitor/squad-review-wait"

cat >"$test_dir/bin/multica" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
dir=$REVIEW_NEXT_TEST_DIR
stub_args=("$@")
stub() { python3 "$REVIEW_NEXT_TEST_ROOT/tests/cli-stub.py" review-wait "$dir" multica calls.jsonl "$@" -- ${stub_args[@]+"${stub_args[@]}"}; }
case "${1-} ${2-} ${3-}" in
'version  ') echo 'multica fixture-version' ;;
'issue get test-issue') stub emit issue-get "$dir/issue.json" ;;
'issue label list') [[ ! -f $dir/labels-fail ]] || { echo 'CLI mock label failure' >&2; exit 1; }
	stub emit issue-labels "$dir/issue-labels.json" ;;
'label list --output') stub emit label-list "$dir/labels.json" ;;
'squad list --output') stub emit squad-list "$dir/squads.json" ;;
'squad member list') stub emit squad-member-list "$dir/members.json" ;;
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
if [[ ${1-} == pr && ${2-} == view ]]; then
	[[ ${3-} == 7 && ${4-} == --repo && ${5-} == demo/project ]] || { echo "Unexpected mock call: $*" >&2; exit 1; }
	[[ ! -f $dir/pr-fail ]] || { echo 'gh mock pr failure' >&2; exit 1; }
	stub emit gh-dependabot-pr "$dir/pr.json"
elif [[ ${1-} == api ]]; then
	case "${2-}" in
	# ホストの gh の関所が入っている環境では、関所が本物の gh の help でフラグを読む。
	--help)
		printf 'FLAGS\n      --paginate        Make additional HTTP requests to fetch all pages of results\n  -X, --method string   The HTTP method for the request\n' ;;
	'repos/demo/project/pulls/7/files?per_page=100')
		[[ ${3-} == --paginate ]]
		[[ ! -f $dir/files-fail ]] || { echo 'gh: Bad Gateway (HTTP 502)' >&2; exit 1; }
		stub emit gh-pr-files "$dir/files.json" ;;
	'repos/demo/project/contents/.agents/review-paths?ref='*)
		echo "${2#*ref=}" >>"$dir/paths-refs"
		case $(<"$dir/paths-mode") in
		absent) echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
		error) echo 'gh: Internal Server Error (HTTP 500)' >&2; exit 1 ;;
		*) stub emit gh-file "$dir/paths-file.json" ;;
		esac ;;
	*) echo "Unexpected mock call: $*" >&2; exit 1 ;;
	esac
else
	echo "Unexpected mock call (書き込みは禁止): $*" >&2
	exit 1
fi
EOF
chmod +x "$test_dir/bin/gh"

fail() { printf '%s\n' "$*" >&2; exit 1; }
sha=0123456789abcdef0123456789abcdef01234567

# --- 見本。エージェントの名前は <プロジェクトのキー>-<役>-<メンバーのキー> で、スクワッドの名前は DEMO-TEST。
jq '.[2] + {assignee_type: "squad", assignee_id: "squad-test"}
	| .metadata += {pr_url: "https://github.com/demo/project/pull/7", repository: "demo/project"}' \
	"$root/tests/fixtures/cli/issue-get.json" >"$test_dir/issue.base.json"
fixture squad-list | jq '[. + {id: "squad-test", name: "DEMO-TEST", leader_id: "orchestrator", archived_at: null}]' >"$test_dir/squads.json"
fixture agent-get | jq '. as $base | [
	"code-reviewer", "ux-reviewer", "security-reviewer", "performance-reviewer", "qa", "claude-implementer"
	| . as $role | $base + {id: $role, name: ("demo-" + $role + "-test"), model: "claude-sonnet-5-5", archived_at: null}
] + [
	$base + {id: "orchestrator", name: "demo-orchestrator-test", model: "claude-fable-5-2", archived_at: null},
	$base + {id: "archived-qa", name: "demo-qa-test", model: "claude-sonnet-5-5", archived_at: "2026-01-01T00:00:00Z"},
	$base + {id: "other-ux-reviewer", name: "other-ux-reviewer-test", model: "claude-sonnet-5-5", archived_at: null}
]' >"$test_dir/agents.json"
set_roster() {
	fixture squad-member-list | jq --args '. as $base | [$ARGS.positional[] | $base + {member_id: ., member_type: "agent"}]' -- "$@" >"$test_dir/members.json"
}
fixture label-list | jq '. as $base | [
	$base + {id: "label-imp", name: "重要", resource_type: "issue"},
	$base + {id: "label-dev", name: "開発", resource_type: "issue"},
	$base + {id: "label-imp-project", name: "重要", resource_type: "project"}
]' >"$test_dir/labels.json"
set_issue_labels() { # ラベルの ID...
	fixture issue-labels | jq --args '. as $base | [$ARGS.positional[] | $base + {id: .}]' -- "$@" >"$test_dir/issue-labels.json"
}
set_files() { # ファイル名[:前の名前]...
	fixture gh-pr-files | jq --args '. as $base | [$ARGS.positional[] | split(":") as $p
		| $base + {filename: $p[0], status: (if $p[1] then "renamed" else "modified" end)}
		| if $p[1] then del(.patch) + {previous_filename: $p[1]} else . end]' -- "$@" >"$test_dir/files.json"
}
set_paths() { # 対応ファイルの内容（標準入力）
	local content
	content=$(base64 | tr -d '\n')
	fixture gh-file | jq --arg content "$content" '. + {content: $content, encoding: "base64", type: "file"}' >"$test_dir/paths-file.json"
	echo present >"$test_dir/paths-mode"
}
all_roles=(code-reviewer ux-reviewer security-reviewer performance-reviewer qa)

status=0
reset() {
	: >"$test_dir/calls.jsonl"
	: >"$test_dir/calls-gh.jsonl"
	: >"$test_dir/watch-calls"
	: >"$test_dir/posted.jsonl"
	: >"$test_dir/paths-refs"
	rm -f "$test_dir/labels-fail" "$test_dir/post-fail" "$test_dir/pr-fail" "$test_dir/files-fail"
	echo 0 >"$test_dir/watch-status"
	echo absent >"$test_dir/paths-mode"
	cp "$test_dir/issue.base.json" "$test_dir/issue.json"
	jq '.baseRefName = "release"' <(fixture gh-dependabot-pr) >"$test_dir/pr.json"
	set_roster claude-implementer orchestrator "${all_roles[@]}" archived-qa other-ux-reviewer
	set_issue_labels label-dev
	set_files README.md
}
run() {
	status=0
	(cd "$test_dir" && bash monitor/squad-review-next request test-issue trigger-1 "$sha" "$@") >"$test_dir/out" 2>"$test_dir/err" || status=$?
}
expect_status() {
	[[ $status == "$1" ]] || { printf '終了コード %s を期待したが %s\n出力:\n%s\n標準エラー:\n%s\n' "$1" "$status" "$(<"$test_dir/out")" "$(<"$test_dir/err")" >&2; exit 1; }
}
# 書いた依頼のコメントを、行ごとに確認する。引数は、観点の役（読点で区切った順）と、理由。
expect_request() {
	local roles=$1 reason=$2 mentions='' role id
	for role in ${roles//、/ }; do
		mentions+="${mentions:+ }[@demo-${role}-test](mention://agent/${role})"
	done
	expect_status 0
	[[ $(jq -s length "$test_dir/posted.jsonl") == 1 ]] || fail "コメントが 1 件でない: $(<"$test_dir/posted.jsonl")"
	jq -e '.args[0:3] == ["issue", "comment", "add"] and .args[3] == "test-issue" and (.args | index("--parent") as $i | .[$i + 1]) == "trigger-1"' "$test_dir/posted.jsonl" >/dev/null \
		|| fail "投稿の引数が違う: $(<"$test_dir/posted.jsonl")"
	local expected actual
	expected=$(printf '確認するコミット: %s\n返事を待つ役: %s\n観点: %s（%s）\n対象の PR: https://github.com/demo/project/pull/7\n' "$sha" "$mentions" "$roles" "$reason")
	actual=$(jq -rs '.[0].body' "$test_dir/posted.jsonl")
	[[ $actual == "$expected" ]] || { printf '期待したコメント:\n%s\n実際のコメント:\n%s\n標準エラー:\n%s\n' "$expected" "$actual" "$(<"$test_dir/err")" >&2; exit 1; }
	# 見張りは、同じ役の ID を同じ順で、きっかけのコメントとともに 1 回だけ入れる。
	local watch=${roles//、/ }
	[[ $(<"$test_dir/watch-calls") == "watch test-issue trigger-1 $watch" ]] || fail "見張りの引数が違う: $(<"$test_dir/watch-calls")"
	[[ $(<"$test_dir/out") == $'観点: '"${roles}（${reason}）"$'\n依頼: posted-comment' ]] || fail "標準出力が違う: $(<"$test_dir/out")"
}
expect_no_comment() {
	[[ ! -s $test_dir/posted.jsonl ]] || fail "コメントを書いてはいけない: $(<"$test_dir/posted.jsonl")"
}
all='code-reviewer、ux-reviewer、security-reviewer、performance-reviewer、qa'
all_reason() { printf '対応を読めないため、有効な観点をすべて頼む: %s' "$1"; }

reset

# ---- 印「重要」があるときは、有効な観点をすべて頼む。ファイルの一覧は読まない。
set_issue_labels label-imp
run
expect_request "$all" '印「重要」があるため、有効な観点をすべて頼む'
[[ ! -s $test_dir/calls-gh.jsonl ]] || fail '印があるのに GitHub を読んでいる'
# 別の種類（プロジェクト）の「重要」は印にならない。
reset
set_issue_labels label-imp-project
run
expect_request code-reviewer '変えたファイル 1 件が対応に当たった（プロジェクト 0 件・既定 1 件）'
echo 'PASS review-next: 印「重要」があれば有効な観点をすべて頼み、課題のラベルでない「重要」は印にしない'

# ---- 既定の対応だけで選ぶ。対応が base のブランチ（release）の内容として 404 になる。
reset
set_files README.md docs/design.md src/run.sh
run
expect_request code-reviewer '変えたファイル 3 件が対応に当たった（プロジェクト 0 件・既定 3 件）'
[[ $(<"$test_dir/paths-refs") == release ]] || fail "対応を base のブランチで読んでいない: $(<"$test_dir/paths-refs")"
reset
set_files web/App.tsx
run
expect_request 'code-reviewer、ux-reviewer、qa' '変えたファイル 1 件が対応に当たった（プロジェクト 0 件・既定 1 件）'
reset
set_files src/auth/login.py db/migrations/0001_init.sql .github/workflows/ci.yml Dockerfile
run
expect_request 'code-reviewer、security-reviewer、performance-reviewer' '変えたファイル 4 件が対応に当たった（プロジェクト 0 件・既定 4 件）'
reset
set_files lib/user-permissions.rb tests/foo-test.sh app/models/user.spec.ts
run
expect_request 'code-reviewer、security-reviewer' '変えたファイル 3 件が対応に当たった（プロジェクト 0 件・既定 3 件）'
echo 'PASS review-next: 既定の対応で、文書・画面・認証・配布・データベース・テスト・ソースの場所から観点を選び、有効な観点の順に並べる'

# ---- プロジェクトの上書きと追加。
reset
set_files docs/design.md src/run.sh
set_paths <<'EOF'
# 文書は QA も見る
docs/ code-reviewer,qa
EOF
run
expect_request 'code-reviewer、qa' '変えたファイル 2 件が対応に当たった（プロジェクト 1 件・既定 1 件）'
reset
set_files docs/design.md
set_paths <<'EOF'
docs/ qa

*.md security-reviewer  # 同じ側の複数の行は合わせる
EOF
run
expect_request 'security-reviewer、qa' '変えたファイル 1 件が対応に当たった（プロジェクト 1 件・既定 0 件）'
reset
set_files api/service.proto src/run.sh
set_paths <<'EOF'
*.proto security-reviewer
EOF
run
expect_request 'code-reviewer、security-reviewer' '変えたファイル 2 件が対応に当たった（プロジェクト 1 件・既定 1 件）'
[[ $(<"$test_dir/paths-refs") == release ]]
echo 'PASS review-next: プロジェクトの対応は既定を上書きし、既定にない場所を足し、同じ側の行は合わせる'

# ---- 当たらないファイルが 1 つでもあれば、有効な観点をすべて頼む。
reset
set_files src/run.sh data/blob.bin assets/logo.dat
run
expect_request "$all" '対応に当たらないファイルが 2 件あるため、有効な観点をすべて頼む'
# 型に / を含まなければどの深さにも当たり、含めば根から当たる。
reset
set_files a/b/c/run.sh
run
expect_request code-reviewer '変えたファイル 1 件が対応に当たった（プロジェクト 0 件・既定 1 件）'
reset
set_files vendor/docs/guide.txt
set_paths <<'EOF'
docs/ qa
EOF
run
expect_request "$all" '対応に当たらないファイルが 1 件あるため、有効な観点をすべて頼む'
echo 'PASS review-next: 対応に当たらないファイルがあれば有効な観点をすべて頼み、/ を含む型は根から当てる'

# ---- 読めない対応は、有効な観点をすべて頼む。
for bad in 'docs/ code-reviewer extra' 'docs/' '*.md reviewer' 'bad|name qa' '/abs/path qa' '*.md code-reviewer,,qa'; do
	reset
	set_files src/run.sh
	printf '%s\n' "$bad" | set_paths
	run
	expect_status 0
	grep -qF "観点: ${all}（$(all_reason '')" "$test_dir/out" || fail "読めない対応で全部を頼んでいない: ${bad}: $(<"$test_dir/out")"
	grep -qE '1 行目' "$test_dir/out" || fail "読めない理由に行がない: ${bad}: $(<"$test_dir/out")"
	[[ $(<"$test_dir/watch-calls") == "watch test-issue trigger-1 ${all//、/ }" ]]
done
# 1 行でも誤りがあれば、ほかの行で選ばない。
reset
set_files docs/design.md
printf 'docs/ qa\n*.md nobody\n' | set_paths
run
grep -qF "観点: ${all}（$(all_reason 'プロジェクトの対応の2 行目に知らない役の名前がある')）" "$test_dir/out" || fail "誤りの行を書いていない: $(<"$test_dir/out")"
# 404 以外の失敗も、読めないとする。
reset
echo error >"$test_dir/paths-mode"
run
expect_request "$all" "$(all_reason 'プロジェクトの対応を読み取れない')"
# base のブランチが読めなければ、読めないとする。
reset
touch "$test_dir/pr-fail"
run
expect_request "$all" "$(all_reason 'PR の base のブランチを読めない')"
echo 'PASS review-next: 形の誤りが 1 行でもあるか、base の対応を 404 以外で読めなければ、有効な観点をすべて頼む。ないときは既定だけで選ぶ'

# ---- 名前を変えたファイルは、前の名前と新しい名前の両方を当てる。消したファイルも当てる。
reset
set_files src/run.sh:docs/run.md
run
expect_request code-reviewer '変えたファイル 1 件が対応に当たった（プロジェクト 0 件・既定 1 件）'
reset
set_files src/run.sh:web/run.tsx
run
expect_request 'code-reviewer、ux-reviewer、qa' '変えたファイル 1 件が対応に当たった（プロジェクト 0 件・既定 1 件）'
reset
set_files src/run.sh:data/old.bin
run
expect_request "$all" '対応に当たらないファイルが 1 件あるため、有効な観点をすべて頼む'
reset
set_files data/new.bin:src/old.sh
run
expect_request "$all" '対応に当たらないファイルが 1 件あるため、有効な観点をすべて頼む'
reset
fixture gh-pr-files | jq '[. + {filename: "web/Old.tsx", status: "removed"}]' >"$test_dir/files.json"
run
expect_request 'code-reviewer、ux-reviewer、qa' '変えたファイル 1 件が対応に当たった（プロジェクト 0 件・既定 1 件）'
echo 'PASS review-next: 名前を変えたファイルは前後の名前の両方を当て、消したファイルも当てる'

# ---- ファイルの一覧を読めない、または切れているときは、有効な観点をすべて頼む。
reset
touch "$test_dir/files-fail"
run
expect_request "$all" "$(all_reason '変えたファイルの一覧を読めない')"
reset
fixture gh-pr-files | jq '[range(3000) as $n | . + {filename: "src/file\($n).sh"}]' >"$test_dir/files.json"
run
expect_request "$all" "$(all_reason '変えたファイルの一覧が GitHub の上限で切れている')"
echo 'PASS review-next: ファイルの一覧を読めない、または上限で切れているときは、有効な観点をすべて頼む'

# ---- 名簿にない役は頼まない。選んだ観点と有効な観点の重なりが空なら、有効な観点をすべて頼む。
reset
set_roster orchestrator code-reviewer qa
set_issue_labels label-imp
run
expect_request 'code-reviewer、qa' '印「重要」があるため、有効な観点をすべて頼む'
reset
set_roster orchestrator code-reviewer qa
set_files web/App.tsx src/auth/login.py
run
expect_request 'code-reviewer、qa' '変えたファイル 2 件が対応に当たった（プロジェクト 0 件・既定 2 件）'
reset
set_roster orchestrator qa
set_files README.md
run
expect_request qa '対応で選んだ観点が有効な観点にないため、有効な観点をすべて頼む'
echo 'PASS review-next: 名簿にある役だけを有効な観点とし、重なりが空なら有効な観点をすべて頼む'

# ---- 失敗したときは、依頼を書かずに標準エラーへ要約を出す。
reset
echo 1 >"$test_dir/watch-status"
run
expect_status 1
expect_no_comment
grep -q '依頼を書けません' "$test_dir/err"
[[ ! -s $test_dir/out ]]
reset
touch "$test_dir/post-fail"
run
expect_status 1
grep -q 'コメントの投稿に失敗した' "$test_dir/err"
[[ ! -s $test_dir/out ]]
# 見張りを入れたあとに投稿に失敗したら、見張りを消す。
[[ $(<"$test_dir/watch-calls") == "watch test-issue trigger-1 "*$'\nunwatch test-issue' ]] || fail "投稿の失敗で見張りを消していない: $(<"$test_dir/watch-calls")"
reset
set_roster orchestrator claude-implementer
run
expect_status 1
expect_no_comment
[[ ! -s $test_dir/watch-calls ]]
grep -q 'レビューと E2E の役がない' "$test_dir/err"
reset
touch "$test_dir/labels-fail"
run
expect_status 1
expect_no_comment
[[ ! -s $test_dir/watch-calls ]]
reset
jq '.metadata.pr_url = ""' "$test_dir/issue.base.json" >"$test_dir/issue.json"
run
expect_status 1
expect_no_comment
grep -q 'PR を決められない' "$test_dir/err"
reset
jq '.metadata.repository = "demo/other"' "$test_dir/issue.base.json" >"$test_dir/issue.json"
run
expect_status 1
expect_no_comment
reset
status=0
(cd "$test_dir" && bash monitor/squad-review-next request test-issue trigger-1 abc123) >"$test_dir/out" 2>"$test_dir/err" || status=$?
expect_status 1
expect_no_comment
grep -q '完全な SHA' "$test_dir/err"
status=0
(cd "$test_dir" && bash monitor/squad-review-next request test-issue) >"$test_dir/out" 2>"$test_dir/err" || status=$?
expect_status 2
status=0
(cd "$test_dir" && bash monitor/squad-review-next decide test-issue) >"$test_dir/out" 2>"$test_dir/err" || status=$?
expect_status 2
grep -q '使い方' "$test_dir/err"
echo 'PASS review-next: 見張りが入らない、投稿に失敗する、役がない、タスクを読めない、PR を決められない、SHA が不正なときは、依頼を書かず標準エラーに理由を出して終わる'
