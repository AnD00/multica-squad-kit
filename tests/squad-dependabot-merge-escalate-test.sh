#!/usr/bin/env bash
# ZIP のルートで bash tests/squad-dependabot-merge-escalate-test.sh。
# gh と multica を差し替え、実際の PR・タスクには書き込まない。escalate のタスクの作成と、引数・契約の検査を確かめる。
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

# escalate の Multica も差し替え、作成した状態を次の呼び出しに引き継ぐ。
cat >"$test_dir/bin/multica" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
dir=$DEPENDABOT_MERGE_TEST_DIR
stub_args=("$@")
args=("$@")
stub() { recorded=1; python3 "$DEPENDABOT_MERGE_TEST_ROOT/tests/cli-stub.py" multica "$dir" multica multica-calls.jsonl "$@" -- ${stub_args[@]+"${stub_args[@]}"}; }
if [[ ${1-} == version ]]; then
	python3 "$DEPENDABOT_MERGE_TEST_ROOT/tests/cli-stub.py" multica "$dir" multica - record -- "$@"
	echo 'multica fixture-version'; exit 0
fi
recorded=
trap '[[ -n $recorded ]] || stub record' EXIT
emit() { stub emit "$@"; }
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
	cp "$dir/metadata-prototype.json" "$dir/metadata.json"
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
python3 "$DEPENDABOT_MERGE_TEST_ROOT/tests/cli-stub.py" none "$dir" curl curl-calls.jsonl record -- "$@"
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
	cli_fixture issue-metadata | jq 'del(.repository,.pr_url)' >"$test_dir/metadata-prototype.json"
	cp "$test_dir/metadata-prototype.json" "$test_dir/metadata.json"
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
