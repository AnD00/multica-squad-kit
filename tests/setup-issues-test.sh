#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/setup-issues-test.XXXXXX")
trap 'test_exit=$?; if [[ $test_exit != 0 ]]; then cat "$test_dir/out" "$test_dir/err" >&2; fi; rm -rf -- "$test_dir"' EXIT
mkdir -p "$test_dir/bin"
cat >"$test_dir/bin/multica" <<'STUB'
#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

db = Path(os.environ["TEST_DB"])
args = sys.argv[1:]

def option(name, default=""):
    return args[args.index(name) + 1] if name in args else default

event = " ".join(args[:2])
if event in ("issue metadata", "issue label"):
    event += " " + args[2]
if event == "issue metadata set":
    event += ":" + option("--key")
with (db / "calls").open("a") as out:
    out.write(json.dumps({"event": event, "args": args}) + "\n")
if (db / "fail").exists() and (db / "fail").read_text().strip() == event:
    sys.exit(71)
issues = json.loads((db / "issues.json").read_text())
if event == "issue list":
    if (db / "bad-list").exists():
        print('{"issues":null}')
        sys.exit()
    issues = [i for i in issues if i["project_id"] == option("--project")]
    metadata = option("--metadata")
    if metadata:
        key, value = metadata.split("=", 1)
        issues = [i for i in issues if i.get("metadata", {}).get(key) == value]
    offset = int(option("--offset", "0"))
    if (db / "repeat-page").exists():
        offset = 0
    # 小さなページで最後まで読むことを試す。total/has_more は旧サーバー相当。
    page = issues[offset:offset + 2]
    print(json.dumps({"issues": page, "has_more": False, "total": len(page)}))
    sys.exit()
if event == "label list":
    print((db / "labels.json").read_text())
    sys.exit()
if event == "issue create":
    assert option("--status") == "backlog"
    if any(i["title"] == option("--title") for i in issues):
        assert "--allow-duplicate" in args
    body_file = Path(option("--description-file")).resolve()
    assert body_file.is_relative_to(Path.cwd())
    number = len(issues) + 1
    issue = {"id": f"issue-{number}", "identifier": f"TEST-{number}",
             "title": option("--title"), "description": body_file.read_text(),
             "status": "backlog", "metadata": {}, "labels": [],
             "project_id": option("--project"), "assignee_id": option("--assignee-id")}
    issues.append(issue)
else:
    issue_id = args[3] if event.startswith(("issue metadata", "issue label")) else args[2]
    issue = next(i for i in issues if i["id"] == issue_id)
    if event.startswith("issue metadata set:"):
        assert option("--type") == "string"
        issue["metadata"][option("--key")] = option("--value")
    elif event == "issue label add":
        if not any(label["id"] == args[4] for label in issue["labels"]):
            issue["labels"].append({"id": args[4]})
    elif event == "issue status":
        # todo への変更は、印とラベルを付けてから。
        assert issue["metadata"]["squad_kit_task"]
        assert isinstance(json.loads(issue["metadata"]["squad_kit_targets"]), list)
        assert issue["labels"]
        issue["status"] = args[3]
    else:
        raise AssertionError(args)
(db / "issues.json").write_text(json.dumps(issues))
with (db / "writes").open("a") as out:
    out.write(json.dumps({"event": event, "issue": issue}) + "\n")
print(json.dumps(issue))
STUB
chmod +x "$test_dir/bin/multica"
export PATH="$test_dir/bin:$PATH"
export TEST_DB="$test_dir/db"
source "$root/lib/check.sh"
source "$root/lib/setup-issues.sh"
server_url=https://example.test
workspace_id=workspace-a
project_id=project-a
kit_version=v9.8.7
cd "$root"

new_case() {
 TEST_DB="$test_dir/$1"; export TEST_DB
 mkdir -p "$TEST_DB"
 echo '[]' >"$TEST_DB/issues.json"
 printf '%s\n' '[{"id":"ops","name":"運用"},{"id":"instructions","name":"指示の改善"},{"id":"trial","name":"検証"}]' >"$TEST_DB/labels.json"
 : >"$test_dir/out"; : >"$test_dir/err"
}
run() { ensure_setup_issue "$@" >"$test_dir/out" 2>"$test_dir/err"; }
deny() { if run "$@"; then exit 1; fi; [[ -s $test_dir/err ]]; }
seed() {
 local id=$1 status=$2 kind=$3 targets=$4 title=$5 project=${6:-project-a}
 jq --arg id "$id" --arg status "$status" --arg kind "$kind" --arg targets "$targets" --arg title "$title" --arg project "$project" '
 .+[{id:$id,identifier:("TEST-"+$id),status:$status,title:$title,description:"人が記入した本文",project_id:$project,
 metadata:(if $kind=="" then {} else {squad_kit_task:$kind,squad_kit_targets:$targets} end),labels:[]}]
 ' "$TEST_DB/issues.json" >"$TEST_DB/new"
 mv "$TEST_DB/new" "$TEST_DB/issues.json"
}
assert_count() { [[ $(jq length "$TEST_DB/issues.json") == "$1" ]]; }

new_case definitions
[[ $(jq length common/setup-issues.json) == 9 ]]
while IFS= read -r kind; do
 assignee=actor
 case $kind in repository-rules) assignee=squad-a ;; handoff-skill-update) assignee=creator ;; esac
 run "$kind" '["対象の名前"]' "$assignee" example/repo
 jq -e --arg kind "$kind" --arg assignee "$assignee" '
 .[-1] | .metadata.squad_kit_task==$kind and (.metadata.squad_kit_targets|type=="string") and
 (.metadata.squad_kit_targets|fromjson)==["対象の名前"] and .assignee_id==$assignee and
 .metadata.repository=="example/repo" and (.labels|length)==1 and
 (.description|contains("/blob/v9.8.7/manual.md#")) and
 ([.title,.description]|all(.[]; contains("{{")|not)) and
 (if $kind=="repository-rules" then .status=="backlog" and (.description|contains("二つの issue を終えてから")) else .status=="todo" end)
 ' "$TEST_DB/issues.json" >/dev/null
done < <(jq -r 'keys[]' common/setup-issues.json)
jq -es '.[0].event=="issue create" and .[1].event=="issue metadata set:squad_kit_targets" and
 .[2].event=="issue metadata set:repository" and .[3].event=="issue metadata set:squad_kit_task" and
 .[4].event=="issue label add" and .[5].event=="issue status"' "$TEST_DB/writes" >/dev/null
echo 'PASS setup issues: 9 種の題・本文・タグの手順・担当・ラベルと、backlog → 印 → ラベル → 最終状態'

new_case rerun
run repository-rules '["example/repo"]' squad-a example/repo
run project-instructions '["project"]' actor
before=$(cat "$TEST_DB/issues.json")
: >"$TEST_DB/writes"
run repository-rules '["example/repo"]' squad-a example/repo
run project-instructions '["project"]' actor
[[ ! -s $TEST_DB/writes && $(cat "$TEST_DB/issues.json") == "$before" ]]
jq -e '.[0].action=="existing"' "$test_dir/out" >/dev/null
echo 'PASS setup issues: 同じ対象の再実行では作成・更新せず、既存の identifier を返す'

new_case terminal-pages
for status in done cancelled in_progress in_review; do
 seed "$status" "$status" removed-roles "[\"$status\"]" '変更された題'
done
seed elsewhere done removed-roles '["new"]' '別のプロジェクト' project-b
run removed-roles '["done","cancelled","in_progress","in_review","new","new"]' actor
assert_count 6
jq -e '.[-1].metadata.squad_kit_targets=="[\"new\"]" and (.[-1].description|contains("- new"))' "$TEST_DB/issues.json" >/dev/null
jq -e 'length==5 and ([.[].targets[]]|sort)==["cancelled","done","in_progress","in_review","new"]' "$test_dir/out" >/dev/null
jq -es 'any(.[]; .event=="issue list" and (.args|index("4"))!=null)' "$TEST_DB/calls" >/dev/null
jq -e '.[0].status=="done" and .[1].status=="cancelled" and .[2].status=="in_progress" and .[3].status=="in_review"' "$TEST_DB/issues.json" >/dev/null
echo 'PASS setup issues: 完了・取り下げ・改題も対象の印で照合し、全ページの対象を引いた残りだけをまとめる'

new_case new-targets
seed prior todo removed-roles '["前の対象"]' '外した役のエージェントを消すか決める'
run removed-roles '["前の対象","新しい対象その1","新しい対象その2"]' actor
assert_count 2
jq -e '.[-1] | (.metadata.squad_kit_targets|fromjson)==["新しい対象その1","新しい対象その2"] and (.description|contains("前の対象")|not)' "$TEST_DB/issues.json" >/dev/null
: >"$TEST_DB/writes"
run removed-roles '["前の対象","新しい対象その1","新しい対象その2"]' actor
[[ ! -s $TEST_DB/writes ]]
echo 'PASS setup issues: 同じ題でも新しい対象だけを 1 件にまとめ、次の実行では重ねて起票しない'

new_case adoption
for id in one two three; do seed "$id" todo '' '[]' '別の題'; done
seed adopt backlog '' '[]' 'example/repo に AGENTS.md と作業別のルールを置く'
run repository-rules '["example/repo"]' squad-a example/repo
assert_count 4
jq -e '.[-1] | .id=="adopt" and .description=="人が記入した本文" and .status=="backlog" and .metadata.repository=="example/repo"' "$TEST_DB/issues.json" >/dev/null
jq -e '.[0].id=="adopt" and .[0].action=="existing"' "$test_dir/out" >/dev/null
echo 'PASS setup issues: 後ろのページの印のない同じ題を採用し、本文を保持する'

for status in done cancelled; do
 new_case "adopt-$status"
 seed old "$status" '' '[]' 'プロジェクトの説明と検証スキルを記入する'
 run project-instructions '["project"]' actor
 assert_count 1
 jq -e --arg status "$status" '.[0].status==$status and (.[0].labels|length)==1' "$TEST_DB/issues.json" >/dev/null
done
echo 'PASS setup issues: 印のない完了・取り下げ済みの issue も開き直さない'

for failure in 'issue create' 'issue metadata set:squad_kit_targets' 'issue metadata set:repository' 'issue metadata set:squad_kit_task' 'issue label add' 'issue status'; do
 new_case "fail-${failure//[ :]/-}"
 echo "$failure" >"$TEST_DB/fail"
 deny dependabot-filter '["example/repo"]' actor example/repo
 rm "$TEST_DB/fail"
 run dependabot-filter '["example/repo"]' actor example/repo
 assert_count 1
 jq -e '.[0] | .status=="todo" and .metadata.repository=="example/repo" and .metadata.squad_kit_task=="dependabot-filter" and (.labels|length)==1' "$TEST_DB/issues.json" >/dev/null
 [[ $(jq -s '[.[]|select(.event=="issue create")]|length' "$TEST_DB/writes") == 1 ]]
done
echo 'PASS setup issues: 作成・各印・ラベル・状態の途中停止後も同じ issue を仕上げる'

new_case partial-targets
seed partial backlog '' '[]' '外した役のエージェントを消すか決める'
jq '.[0].metadata.squad_kit_targets="[\"前の対象\"]"' "$TEST_DB/issues.json" >"$TEST_DB/new"
mv "$TEST_DB/new" "$TEST_DB/issues.json"
run removed-roles '["追加の対象"]' actor
jq -e '.[0].metadata.squad_kit_targets|fromjson|sort==["前の対象","追加の対象"]' "$TEST_DB/issues.json" >/dev/null
echo 'PASS setup issues: 種類の印の直前で止まっても、それまでの対象の印を保つ'

for failure in 'issue list' 'label list'; do
 new_case "read-${failure// /-}"
 echo "$failure" >"$TEST_DB/fail"
 deny project-instructions '["project"]' actor
 [[ ! -e $TEST_DB/writes ]]
done
for mode in bad-list repeat-page bad-targets ambiguous; do
 new_case "$mode"
 case $mode in
 bad-list) touch "$TEST_DB/bad-list" ;;
 repeat-page) seed old done project-instructions '["project"]' '題'; touch "$TEST_DB/repeat-page" ;;
 bad-targets) seed old done project-instructions '壊れた印' '題' ;;
 ambiguous)
  seed one backlog '' '[]' 'プロジェクトの説明と検証スキルを記入する'
  seed two backlog '' '[]' 'プロジェクトの説明と検証スキルを記入する' ;;
 esac
 deny project-instructions '["project"]' actor
 [[ ! -e $TEST_DB/writes ]]
done
new_case invalid
deny unknown '["project"]' actor
deny project-instructions '[]' actor
deny project-instructions '[1]' actor
deny repository-rules '["example/repo"]' squad-a
deny project-instructions '["project"]' ''
[[ ! -e $TEST_DB/calls && ! -e $TEST_DB/writes ]]
[[ -z $(find "$root/tmp" -maxdepth 1 -name 'setup-issue.*' -print) ]]
echo 'PASS setup issues: 読み取り失敗・不正な印・重複ページ・採用候補の重複・不正な入力では新規起票しない'
