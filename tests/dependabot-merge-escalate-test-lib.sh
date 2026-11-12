#!/usr/bin/env bash
# escalate の分割テストが読むスタブと fixture。単独では実行しない。
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

existing_escalation() {
 cli_fixture issue-search | jq '.issues[0] as $base | .issues=[$base + {
  id:"issue-a",identifier:"TEST-9000",project_id:"project-a",title:"確認（example/template#1）"}]' >"$test_dir/search.json"
 cli_fixture issue-labels | jq '[. + {id:"label-a"}]' >"$test_dir/issue-labels.json"
}
