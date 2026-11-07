#!/usr/bin/env bash
set -euo pipefail
code_root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$code_root/tmp"
test_dir=$(mktemp -d "$code_root/tmp/workspace-test.XXXXXX")
trap 'test_exit=$?; if [[ $test_exit != 0 ]]; then cat "$test_dir/out" "$test_dir/err" >&2; fi; rm -rf -- "$test_dir"' EXIT
mkdir -p "$test_dir/package/common/skills/squad-check/scripts" "$test_dir/package/common/skills/squad-check/references" "$test_dir/bin"
cp "$code_root/common/labels" "$test_dir/package/common/labels"
cat >"$test_dir/package/common/skills/squad-check/SKILL.md" <<'SKILL'
---
name: squad-check
description: Workspace test skill
---

new primary content
SKILL
printf 'new script\n' >"$test_dir/package/common/skills/squad-check/scripts/run.sh"
printf 'text & literal $HOME\n' >"$test_dir/package/common/skills/squad-check/references/file with spaces.txt"
cat >"$test_dir/bin/multica" <<'STUB'
#!/bin/bash
set -euo pipefail
[[ $MULTICA_WORKSPACE_ID == ws-a && $MULTICA_SERVER_URL == https://example.test ]] || exit 95
printf '%s\n' "$*" >>"$TEST_DB/calls"
command_key="$1 $2"
[[ $command_key != 'skill files' ]] || command_key="$1 $2 $3"
if [[ -f $TEST_DB/fail && $(cat "$TEST_DB/fail") == "$command_key" ]]; then echo 'intentional CLI failure' >&2; exit 77; fi
option() { local key=$1; shift; while (($#)); do if [[ $1 == "$key" ]]; then printf '%s\n' "$2"; return; fi; shift; done; return 1; }
write() { printf '%s\n' "$command_key" >>"$TEST_DB/writes"; }
replace() { mv "$TEST_DB/new.json" "$1"; }
case $command_key in
'label list') cat "$TEST_DB/labels.json" ;;
'label create')
 write
 [[ $(option --resource-type "$@") == issue ]]
 item=$(jq -n --arg id "label-$(jq length "$TEST_DB/labels.json")" --arg name "$(option --name "$@")" --arg color "$(option --color "$@")" --arg description "$(option --description "$@")" '{id:$id,name:$name,color:$color,description:$description}')
 jq --argjson item "$item" '.+[$item]' "$TEST_DB/labels.json" >"$TEST_DB/new.json"; replace "$TEST_DB/labels.json"; echo "$item" ;;
'label update')
 write
 jq --arg id "$3" --arg color "$(option --color "$@")" --arg description "$(option --description "$@")" 'map(if .id==$id then .color=$color | .description=$description else . end)' "$TEST_DB/labels.json" >"$TEST_DB/new.json"
 replace "$TEST_DB/labels.json"; echo '{}' ;;
'skill list')
 if [[ -f $TEST_DB/bad-list ]]; then echo '{}'; elif [[ -f $TEST_DB/skill.json ]]; then jq '[{id:.id,name:.name}] + [{id:"unrelated-id",name:"personal-skill"}]' "$TEST_DB/skill.json"; else echo '[]'; fi ;;
'skill get') [[ $3 == skill-a && $* == *--with-content* ]]; cat "$TEST_DB/skill.json" ;;
'user profile') echo '{"id":"actor"}' ;;
'workspace member') jq -n --arg role "$(cat "$TEST_DB/role")" '[{id:"membership-row",user_id:"actor",role:$role,name:"Runner"},{id:"creator-row",user_id:"creator",role:"member",name:"Original Creator"}]' ;;
'skill import')
 write
 [[ $(option --on-conflict "$@") == fail && ! -f $TEST_DB/skill.json ]]
 [[ $(option --url "$@") == https://github.com/AnD00/multica-squad-kit/tree/*/common/skills/squad-check ]]
 mkdir "$TEST_DB/imported"
 cp -R "$TEST_SKILL_DIR/". "$TEST_DB/imported/"
 [[ -f $TEST_DB/imported/SKILL.md && -f "$TEST_DB/imported/references/file with spaces.txt" ]]
 files='[]'; counter=0
 while IFS= read -r -d '' file; do
  [[ $file != "$TEST_DB/imported/SKILL.md" ]] || continue
  counter=$((counter+1)); path=${file#"$TEST_DB/imported"/}
  files=$(jq -c --arg id "file-$counter" --arg path "$path" --rawfile content "$file" '.+[{id:$id,path:$path,content:$content}]' <<<"$files")
 done < <(find "$TEST_DB/imported" -type f -print0)
 jq -n --rawfile content "$TEST_DB/imported/SKILL.md" --argjson files "$files" --arg url "$(option --url "$@")" '{id:"skill-a",name:"squad-check",description:"Workspace test skill",created_by:"actor",content:$content,files:$files,config:{keep:"yes",origin:{type:"github",source_url:$url}}}' >"$TEST_DB/skill.json"
 echo '{"status":"created","skill":{"id":"skill-a","name":"squad-check"}}' ;;
'skill update')
 write
 [[ $3 == skill-a && $* != *--name* ]]
 if [[ $* == *--config* ]]; then
  jq --argjson config "$(option --config "$@")" '.config=$config' "$TEST_DB/skill.json" >"$TEST_DB/new.json"
 else
  jq --rawfile content "$(option --content-file "$@")" --arg description "$(option --description "$@")" '.content=$content | .description=$description' "$TEST_DB/skill.json" >"$TEST_DB/new.json"
 fi
 replace "$TEST_DB/skill.json"; echo '{}' ;;
'skill refresh')
 write
 files='[]'
 while IFS= read -r -d '' file; do
  [[ $file != "$TEST_SKILL_DIR/SKILL.md" ]] || continue
  path=${file#"$TEST_SKILL_DIR"/}
  files=$(jq -c --arg path "$path" --rawfile content "$file" '.+[{id:("file-"+((length+1)|tostring)),path:$path,content:$content}]' <<<"$files")
 done < <(find "$TEST_SKILL_DIR" -type f -print0)
 jq --rawfile content "$TEST_SKILL_DIR/SKILL.md" --argjson files "$files" '.content=$content | .description="Workspace test skill" | .files=$files' "$TEST_DB/skill.json" >"$TEST_DB/new.json"
 replace "$TEST_DB/skill.json"; cat "$TEST_DB/skill.json" ;;
'skill files upsert')
 write
 [[ $4 == skill-a ]]
 path=$(option --path "$@"); [[ $path != SKILL.md ]]
 file_id=$(jq -r --arg path "$path" '[.files[]|select(.path==$path)][0].id // ("file-"+((.files|length)+1|tostring))' "$TEST_DB/skill.json")
 jq --arg path "$path" --arg id "$file_id" --rawfile content "$(option --content-file "$@")" '.files=([.files[]|select(.path!=$path)]+[{id:$id,path:$path,content:$content}])' "$TEST_DB/skill.json" >"$TEST_DB/new.json"; replace "$TEST_DB/skill.json"; echo '{}' ;;
'skill files delete')
 write
 [[ $4 == skill-a ]]
 jq --arg id "$5" '.files|any(.[];.id==$id)' "$TEST_DB/skill.json" | grep -qx true
 jq --arg id "$5" '.files|=map(select(.id!=$id))' "$TEST_DB/skill.json" >"$TEST_DB/new.json"; replace "$TEST_DB/skill.json" ;;
*) echo "unexpected command: $*" >&2; exit 90 ;;
esac
STUB
chmod +x "$test_dir/bin/multica"
export PATH="$test_dir/bin:$PATH"
export TEST_SKILL_DIR="$test_dir/package/common/skills/squad-check"
cat >"$test_dir/run.sh" <<'RUN'
#!/bin/bash
set -euo pipefail
code_root=$1; root=$2
source "$code_root/lib/ui.sh"
source "$code_root/lib/check.sh"
source "$code_root/lib/workspace.sh"
die() { echo "$*" >&2; exit 1; }
server_url=https://example.test
workspace_id=ws-a
kit_version=${TEST_KIT_VERSION:-v1.0.0}
if [[ ${TEST_LOCAL:-no} == yes ]]; then
 sync_local_project_skill "$root/common/skills/squad-check" squad-check skill-a
else prepare_workspace; fi
RUN
run() { /bin/bash "$test_dir/run.sh" "$code_root" "$test_dir/package" >"$test_dir/out" 2>"$test_dir/err"; }
deny() { if run; then exit 1; fi; [[ -s $test_dir/err ]]; }
new_case() {
 export TEST_DB="$test_dir/$1"
 mkdir "$TEST_DB"; echo member >"$TEST_DB/role"
 if [[ -f $test_dir/good-labels.json ]]; then cp "$test_dir/good-labels.json" "$TEST_DB/labels.json"; else echo '[]' >"$TEST_DB/labels.json"; fi
}
old_skill() {
 jq '.content="old body" | .description="old description" | .created_by="creator" | .files=[{id:"old-file",path:"obsolete.txt",content:"old"},{id:"kept-file",path:"scripts/run.sh",content:"old script"}]' "$test_dir/good-skill.json" >"$TEST_DB/skill.json"
}
new_case initial
run
jq -e 'length==4' "$TEST_DB/labels.json" >/dev/null
jq -e '.id=="skill-a" and (.files|length)==2' "$TEST_DB/skill.json" >/dev/null
[[ $(grep -c '^skill import$' "$TEST_DB/writes") == 1 ]]
cp "$TEST_DB/labels.json" "$test_dir/good-labels.json"
cp "$TEST_DB/skill.json" "$test_dir/good-skill.json"
echo 'PASS workspace: ラベルと共通スキルを新規作成し、主本文と付属ファイルをタグの URL で取り込む'
: >"$TEST_DB/writes"; : >"$TEST_DB/calls"
run
[[ ! -s $TEST_DB/writes ]]
if grep -q '^user profile\|^workspace member' "$TEST_DB/calls"; then exit 1; fi
echo 'PASS workspace: 中身が同じなら権限によらず書き込まず、二度目の取り込みもしない'
for role in owner admin importer; do
 new_case "$role"; old_skill
 if [[ $role == importer ]]; then
  jq '.created_by="actor"' "$TEST_DB/skill.json" >"$TEST_DB/new.json"; mv "$TEST_DB/new.json" "$TEST_DB/skill.json"
 else echo "$role" >"$TEST_DB/role"; fi
 run
 jq -e '.id=="skill-a" and .config.keep=="yes" and (.files|length)==2 and all(.files[]; .path!="obsolete.txt")' "$TEST_DB/skill.json" >/dev/null
 [[ $(grep -c '^skill update$' "$TEST_DB/writes") == 1 ]]
 grep -qx 'skill refresh' "$TEST_DB/writes"
 if grep -q '^skill import' "$TEST_DB/writes"; then exit 1; fi
 : >"$TEST_DB/writes"; run; [[ ! -s $TEST_DB/writes ]]
done
echo 'PASS workspace: オーナー・管理者・最初の取り込み者は ID を変えず本文・追加・変更・削除を合わせる'
new_case ordinary; old_skill
cp "$TEST_DB/skill.json" "$TEST_DB/before.json"
run
cmp "$TEST_DB/skill.json" "$TEST_DB/before.json"
[[ ! -e $TEST_DB/writes ]]
grep -q '更新を飛ばしました: squad-check' "$test_dir/err"
grep -q 'Original Creator' "$test_dir/err"
echo 'PASS workspace: ほかの人は違う共通スキルを更新せず、更新できる人を表示して続ける'
new_case labels
jq '.[0].color="#000000" | .[0].description="old" | .+[{id:"keep-id",name:"unrelated",color:"#123456",description:"keep"}]' "$TEST_DB/labels.json" >"$TEST_DB/new.json"; mv "$TEST_DB/new.json" "$TEST_DB/labels.json"
cp "$test_dir/good-skill.json" "$TEST_DB/skill.json"
run
[[ $(grep -c '^label update$' "$TEST_DB/writes") == 1 ]]
jq -e 'length==5 and any(.[]; .id=="keep-id" and .description=="keep")' "$TEST_DB/labels.json" >/dev/null
echo 'PASS workspace: 差のあるラベルだけを更新し、無関係のラベルを保持する'
for failure in 'label list' 'skill list' 'skill get' 'workspace member'; do
 name=${failure// /-}; new_case "fail-$name"; old_skill; echo admin >"$TEST_DB/role"
 echo "$failure" >"$TEST_DB/fail"
 deny
 [[ ! -e $TEST_DB/writes ]]
done
echo 'PASS workspace: 読み取り失敗を不存在や更新許可とみなして書き込まない'
new_case malformed; touch "$TEST_DB/bad-list"
deny
[[ ! -e $TEST_DB/writes ]]
echo 'PASS workspace: 不正な一覧では新しいスキルを作らない'
new_case partial; old_skill; echo admin >"$TEST_DB/role"
echo 'skill refresh' >"$TEST_DB/fail"
deny
[[ $(grep -c '^skill update$' "$TEST_DB/writes") == 1 ]]
rm "$TEST_DB/fail"
run
[[ $(grep -c '^skill refresh$' "$TEST_DB/writes") == 1 ]]
jq -e '.id=="skill-a" and (.files|length)==2' "$TEST_DB/skill.json" >/dev/null
echo 'PASS workspace: 途中の更新失敗を返し、再実行では済んだ本文を重ねて書かず残りを合わせる'
for failure in 'label create' 'skill import' 'skill update' 'skill refresh'; do
 name=${failure// /-}; new_case "write-fail-$name"; echo admin >"$TEST_DB/role"
 case $failure in 'label create') echo '[]' >"$TEST_DB/labels.json" ;; 'skill import') : ;; *) old_skill ;; esac
 echo "$failure" >"$TEST_DB/fail"
 deny
done
[[ -z $(find "$test_dir/package/tmp" -name 'workspace.*' -print) ]]
echo 'PASS workspace: 作成・取り込み・編集・削除の失敗を返し、一時ファイルを片付ける'

new_case switch-tag
cp "$test_dir/good-skill.json" "$TEST_DB/skill.json"
TEST_KIT_VERSION=v2.0.0 run
jq -e '.id=="skill-a" and (.config.origin.source_url|contains("/v2.0.0/")) and .config.keep=="yes"' "$TEST_DB/skill.json" >/dev/null
grep -qx 'skill refresh' "$TEST_DB/writes"
echo 'PASS workspace: 同じ本文でもタグが変われば URL を更新して同じ ID を refresh する'

new_case local-project; old_skill; echo admin >"$TEST_DB/role"
TEST_LOCAL=yes run
jq -e '.id=="skill-a" and (.files|length)==2 and all(.files[]; .path!="obsolete.txt")' "$TEST_DB/skill.json" >/dev/null
! grep -q '^skill refresh\|^skill import' "$TEST_DB/calls"
: >"$TEST_DB/writes"
TEST_LOCAL=yes run
[[ ! -s $TEST_DB/writes ]]
echo 'PASS extension skill: 手元から本文・追加・変更・削除を合わせ、同じ ID を維持し、URL を取得しない'
