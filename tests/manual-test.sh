#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/setup-fixture.sh"
manifest
export TEST_REPOS_FILE="$test_dir/repos.json"
printf '%s\n' '[{"url":"https://github.com/example/one"},{"url":"https://github.com/example/two"},{"url":"https://github.com/example/three"}]' >"$TEST_REPOS_FILE"
printf 'https://example.test\n1\n1\nshop\n1 3\nmember1\n1 2\n1\n5 7\n\nno\n' >"$test_dir/input"
TEST_SERVER='(not set)' deny
no_state
# 実際の質問画面を取り、手で書いた各質問の節に説明と例があることを照合する。
check_manual() {
 jq -nr --rawfile screen "$test_dir/err" --rawfile document "$1" '
  ($screen|split("\n")) as $lines |
  [range(0;$lines|length) as $i | select($lines[$i]|test("^\\? .+  [●○]{9}$")) |
   {title:($lines[$i]|sub("^\\? ";"")|sub("  [●○]{9}$";"")),description:($lines[$i+1]|ltrimstr("  ")),example:($lines[$i+2]|ltrimstr("  "))}] as $questions |
  if ($questions|length)!=10 then error("10問の画面を取得できませんでした") else . end |
  ($document|gsub("`";"")) as $doc |
  [$questions[] | . as $q |
   (($doc|split("#### "+$q.title+"\n"))[1] // "" | split("\n#### ")[0] | split("\n### ")[0]) as $section |
   (if ($q.description|length)==0 or ($section|contains($q.description)|not) then "説明がない: "+$q.title else empty end),
   (if ($q.example|length)==0 or ($section|contains($q.example)|not) then "例がない: "+$q.title else empty end)] as $missing |
  if ($missing|length)>0 then error($missing|join("、")) else . end |
  (($screen|split("\n? 外す役  "))[1] // "" | split("\n? ")[0] | split("\n") |
   map(select(test("^    [1-9][0-9]*  [^:]+: [^。]+。")) | capture("^    (?<number>[0-9]+)  (?<role>[^:]+): (?<purpose>[^。]+)。"))) as $roles |
  if ($roles|length)!=12 then error("12役の画面を取得できませんでした") else . end |
  (($doc|split("#### 外す役\n"))[1] // "" | split("\n### ")[0] | split("\n")) as $role_lines |
  [$roles[] | . as $role | select(any($role_lines[]; startswith("| "+$role.number+" | "+$role.role+" | ") and contains($role.purpose))|not) | "担当の説明がない: "+.role] as $missing_roles |
  # 画面の役ごとの見出し（エージェント・オートパイロット・見張り・ほかに変わること）を、表の同じ行と照らす。
  ([(($screen|split("\n? 外す役  "))[1] // "" | split("\n? ")[0] | split("外せる役:\n")[1] // "" | split("\n"))[] | select(test("^    [1-9][0-9]*  ") or test("^ +(エージェント|オートパイロット|見張り|ほかに変わること): "))] |
   reduce .[] as $line ([]; if ($line|test("^    [1-9]")) then .+[{number:($line|capture("^    (?<n>[0-9]+)  ").n),details:{}}]
     else .[-1].details[$line|capture("^ +(?<k>[^:]+): (?<v>.*)$").k] = ($line|capture("^ +(?<k>[^:]+): (?<v>.*)$").v) end)) as $blocks |
  [$blocks[] | . as $block |
   ([$role_lines[]|select(startswith("| "+$block.number+" | "))][0] // "" | ltrimstr("| ") | rtrimstr(" |") | gsub("`";"") | gsub("<p>";"shop") | gsub("<m>";"member1") | split(" | ")) as $cells |
   ($block.details."エージェント" // "" | split("、")) as $agents |
   (($block.details."オートパイロット" // "" | split("、") | map(gsub("example/(one|three)";"<OWNER/REPO>"))) + [$block.details."見張り" // empty]) as $watches |
   select(
    ($cells|length)!=6 or
    ($agents|length)==0 or any($agents[]; . as $name | $cells[3]|contains($name)|not) or
    (if ($watches|length)==0 then $cells[4]!="なし" else any($watches[]; . as $name | $cells[4]|contains($name)|not) end) or
    (if $block.details."ほかに変わること" then ($cells[5]|contains($block.details."ほかに変わること")|not) else $cells[5]!="なし" end)
   ) | "外れるものの表示が表と違う: "+$block.number] as $mismatch |
  if ($blocks|length)!=12 or ($mismatch|length)>0 then error(($mismatch + (if ($blocks|length)!=12 then ["12役の見出しを取得できませんでした"] else [] end))|join("、")) else . end |
  if ($missing_roles|length)==0 then "9問の説明・例と12役の担当内容と一緒に外れるものが手順書にある" else error($missing_roles|join("、")) end'
}
check_manual "$root/manual.md" >"$test_dir/checked"
echo 'PASS manual: CLIを差し替えた実際の9問の画面と、手で書いた各質問の節の説明・例が一致する'
sed '/^> このホストのデーモン/d' "$root/manual.md" >"$test_dir/no-description.md"
if check_manual "$test_dir/no-description.md" >"$test_dir/out" 2>"$test_dir/check-error"; then exit 1; fi
grep -q '説明がない: サーバーの URL' "$test_dir/check-error"
sed '/multica.example.test/d' "$root/manual.md" >"$test_dir/no-example.md"
if check_manual "$test_dir/no-example.md" >"$test_dir/out" 2>"$test_dir/check-error"; then exit 1; fi
grep -q '例がない: サーバーの URL' "$test_dir/check-error"
echo 'PASS manual: 説明か例を欠いた手順書では検査が失敗する'
sed 's/画面の使いやすさを確認する/未記入/' "$root/manual.md" >"$test_dir/no-role-purpose.md"
if check_manual "$test_dir/no-role-purpose.md" >"$test_dir/out" 2>"$test_dir/check-error"; then exit 1; fi
grep -q '担当の説明がない: UX' "$test_dir/check-error"
echo 'PASS manual: 画面の12役それぞれの担当内容を照合し、名前と外した影響だけでは通さない'
sed 's/オートパイロット: 「使用上限の見張り/オートパイロット: 「別の名前/' "$root/manual.md" >"$test_dir/no-usage-name.md"
if check_manual "$test_dir/no-usage-name.md" >"$test_dir/out" 2>"$test_dir/check-error"; then exit 1; fi
grep -q '外れるものの表示が表と違う: 11' "$test_dir/check-error"
sed 's/返事を待つ役の一覧から外れる |$/なし |/' "$root/manual.md" >"$test_dir/no-change.md"
if check_manual "$test_dir/no-change.md" >"$test_dir/out" 2>"$test_dir/check-error"; then exit 1; fi
grep -q '外れるものの表示が表と違う: 5' "$test_dir/check-error"
echo 'PASS manual: 画面の12役の一緒に外れるもの（エージェント・オートパイロット・見張り・ほかに変わること）を表の同じ行と照合する'

# 入れ直しの案内には、配置ファイルと対象プロジェクトの回答の片付けが必要。
python3 - "$root" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
readme = (root / 'README.md').read_text()
section = (root / 'manual.md').read_text().split('## 導入済みの配布物を入れ直す\n')[1].split('\n## ')[0]
for document in (readme, section):
    assert '保存済み回答' in document
    assert '~/.multica-agent/template/answers/<workspace-id>/<project-key>.json' in document
assert '別のワークスペースやプロジェクトの回答は消さない' in section
PY
base_input yes
mkdir -p "$TEMPLATE_STATE_ROOT/ws-a"
printf '%s\n' '{"schema":0}' >"$TEMPLATE_STATE_ROOT/ws-a/demo.json"
printf '%s\n' '{"schema":0}' >"$TEMPLATE_STATE_ROOT/ws-a/other.json"
cp "$TEMPLATE_STATE_ROOT/ws-a/other.json" "$test_dir/other-answer"
deny
grep -qF '保存済みの答えが不正です。内容を確認してください。' "$test_dir/err"
! grep -q 'TEST-project-prepared' "$test_dir/out"
# 手順どおり、対象の回答だけを片付けて質問に答え直す。
rm "$TEMPLATE_STATE_ROOT/ws-a/demo.json"
run
grep -q 'TEST-project-prepared' "$test_dir/out"
jq -e '.schema==1 and .workspace_id=="ws-a" and .project_key=="demo"' "$TEMPLATE_STATE_ROOT/ws-a/demo.json" >/dev/null
cmp "$TEMPLATE_STATE_ROOT/ws-a/other.json" "$test_dir/other-answer"
echo 'PASS manual: 入れ直しで対象の保存済み回答を片付けると設定が成功し、別プロジェクトの回答を保つ'
