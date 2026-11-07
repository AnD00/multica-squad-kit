#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/setup-fixture.sh"
manifest
export TEST_REPOS_FILE="$test_dir/repos.json"
printf '%s\n' '[{"url":"https://github.com/example/one"},{"url":"https://github.com/example/two"},{"url":"https://github.com/example/three"}]' >"$TEST_REPOS_FILE"
printf 'https://example.test\n1\n1\nshop\n1 3\nmember1\n1 2\n1\n5 7\nno\n' >"$test_dir/input"
TEST_SERVER='(not set)' deny
no_state
# 実際の質問画面を取り、手で書いた各質問の節に説明と例があることを照合する。
check_manual() {
 jq -nr --rawfile screen "$test_dir/err" --rawfile document "$1" '
  ($screen|split("\n")) as $lines |
  [range(0;$lines|length) as $i | select($lines[$i]|test("^質問 \\([0-9]+/[0-9]+\\) ")) |
   {title:($lines[$i]|sub("^質問 \\([0-9]+/[0-9]+\\) ";"")),description:$lines[$i+1],example:($lines[$i+2]|ltrimstr("例: "))}] as $questions |
  if ($questions|length)!=9 then error("9問の画面を取得できませんでした") else . end |
  ($document|gsub("`";"")) as $doc |
  [$questions[] | . as $q |
   (($doc|split("#### "+$q.title+"\n"))[1] // "" | split("\n#### ")[0] | split("\n### ")[0]) as $section |
   (if ($q.description|length)==0 or ($section|contains($q.description)|not) then "説明がない: "+$q.title else empty end),
   (if ($q.example|length)==0 or ($section|contains($q.example)|not) then "例がない: "+$q.title else empty end)] as $missing |
  if ($missing|length)>0 then error($missing|join("、")) else . end |
  (($screen|split(") 外す役\n"))[1] // "" | split("\n") |
   map(select(test("^[1-9][0-9]*: [^:]+: [^。]+。")) | capture("^(?<number>[0-9]+): (?<role>[^:]+): (?<purpose>[^。]+)。"))) as $roles |
  if ($roles|length)!=12 then error("12役の画面を取得できませんでした") else . end |
  (($doc|split("#### 外す役\n"))[1] // "" | split("\n### ")[0] | split("\n")) as $role_lines |
  [$roles[] | . as $role | select(any($role_lines[]; startswith("| "+$role.number+" | "+$role.role+" | ") and contains($role.purpose))|not) | "担当の説明がない: "+.role] as $missing_roles |
  if ($missing_roles|length)==0 then "9問の説明・例と12役の担当内容が手順書にある" else error($missing_roles|join("、")) end'
}
check_manual "$root/manual.md" >"$test_dir/checked"
echo 'PASS manual: CLIを差し替えた実際の9問の画面と、手で書いた各質問の節の説明・例が一致する'
sed '/^このホストのデーモン/d' "$root/manual.md" >"$test_dir/no-description.md"
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
