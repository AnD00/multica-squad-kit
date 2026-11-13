#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/setup-fixture.sh"
# 一覧の取得は既存の CLI スタブを使う。保存・登録はしない。
cat >"$test_dir/plan.sh" <<'DRIVER'
set -euo pipefail
root=$1
die() { ui_error "$*"; exit 1; }
source "$root/lib/ui.sh"
source "$root/lib/check.sh"
source "$root/lib/answers.sh"
source "$root/lib/questions.sh"
ui_init
server_url=https://example.test workspace_id=ws-a project_id=project-a project_key=shop member_key=owner question_actor_id=member-a
question_squads='[{"id":"squad-a","name":"SHOP-OWNER"}]'
question_people='[{"user_id":"member-a","name":"Member A"},{"user_id":"member-b","name":"Member B"}]'
template_roles='orchestrator planner security-reviewer old-extension'
extension_disabled_roles=old-extension
runtimes='["claude","codex"]'
repositories='[{"repository":"example/one"},{"repository":"example/two"}]'
link_repositories='["example/three"]'
member_ids='["member-a","member-b"]'
excluded_roles='["security-reviewer"]'
if [[ ${2:-} == confirm ]]; then
 confirmation_plan() { cat "$TEST_PLAN"; }
 confirm_answers
 echo accepted
else
 confirmation_plan >"$TEST_PLAN"
 confirmation_show "$(cat "$TEST_PLAN")"
fi
DRIVER
export TEST_PLAN="$test_dir/plan.json" TEST_AGENTS_FILE="$test_dir/agents.json" TEST_SKILLS_FILE="$test_dir/skills.json" TEST_ROSTER_FILE="$test_dir/roster.json" TEST_AUTOPILOTS_FILE="$test_dir/autos.json" TEST_RESOURCES_DIR="$test_dir/resources"
mkdir -p "$TEST_RESOURCES_DIR"
printf '%s\n' '[{"id":"a","name":"shop-orchestrator-owner","owner_id":"member-a"}]' >"$TEST_AGENTS_FILE"
printf '%s\n' '[{"id":"v","name":"shop-verify"}]' >"$TEST_SKILLS_FILE"
printf '%s\n' '[{"member_type":"member","member_id":"member-a"},{"member_type":"agent","member_id":"member-b"}]' >"$TEST_ROSTER_FILE"
printf '%s\n' '[{"resource_type":"github_repo","resource_ref":{"url":"https://github.com/example/one"}}]' >"$TEST_RESOURCES_DIR/project-a.json"
printf '%s\n' '{"autopilots":[{"id":"foreign","title":"Dependabot の PR の週次の確認 shop example/one","project_id":"other","assignee_type":"agent","assignee_id":"a"}]}' >"$TEST_AUTOPILOTS_FILE"
/bin/bash "$test_dir/plan.sh" "$root" >"$test_dir/out" 2>"$test_dir/err"
[[ ! -s $test_dir/out ]]
jq -e '
 any(.[]; .group=="エージェント" and .mark=="change" and .name=="shop-orchestrator-owner") and
 any(.[]; .group=="エージェント" and .mark=="add" and .name=="shop-planner-owner") and
 any(.[]; .group=="スクワッド" and .mark=="change") and
 any(.[]; .group=="スキル" and .mark=="keep") and
 any(.[]; .group=="リポジトリ" and .mark=="keep" and .name=="example/one") and
 any(.[]; .group=="リポジトリ" and .mark=="add" and .name=="example/three" and .value=="紐付けだけ") and
 any(.[]; .group=="オートパイロット" and .mark=="warn" and .value=="別の担当") and
 any(.[]; .group=="人間" and .mark=="keep" and .name=="Member A") and
 any(.[]; .group=="人間" and .mark=="add" and .name=="Member B") and
 any(.[]; .group=="役" and .mark=="drop" and .name=="old-extension" and .value=="エージェントは残す") and
 all(.[]|select(.group=="エージェント"); .name!="shop-security-reviewer-owner" and .name!="shop-old-extension-owner")
' "$TEST_PLAN" >/dev/null
python3 - "$TEST_PLAN" "$test_dir/err" <<'PY'
import collections
import json
import sys

plan = json.load(open(sys.argv[1]))
screen = open(sys.argv[2]).read()
symbols = dict(add="+", change="~", keep="·", warn="!", drop="-")
expected = [""]
for group in ["エージェント", "スクワッド", "スキル", "リポジトリ", "オートパイロット", "人間", "役"]:
    rows = [row for row in plan if row["group"] == group]
    if rows:
        expected.append("  " + group)
    for row in rows:
        expected.append("    " + symbols[row["mark"]] + " " + row["name"] + ("  " + row["value"] if row["value"] else ""))
counts = collections.Counter(row["mark"] for row in plan)
expected.extend(["", "  " + "  ".join(symbol + str(counts[mark]) for mark, symbol in symbols.items() if counts[mark])])
assert screen == "\n".join(expected) + "\n", screen
assert not any(word in screen for word in ["答えの一覧", "名前の規則:", "サーバー:", "既存", "新規", "成功"])
assert "example/three" not in "\n".join(row["name"] for row in plan if row["group"] == "オートパイロット")
PY
echo 'PASS confirmation: 名前ごとの予定、所属済みの人間、別担当、紐付け専用、外れた拡張、全記号の件数を表示する'

cp "$TEST_ROSTER_FILE" "$test_dir/roster-before"
printf '{}\n' >"$TEST_ROSTER_FILE"
if /bin/bash "$test_dir/plan.sh" "$root" >"$test_dir/out" 2>"$test_dir/err"; then exit 1; fi
grep -qF 'スクワッドのメンバーの応答が不正です。' "$test_dir/err"
[[ ! -s $TEST_PLAN && ! -e $TEMPLATE_STATE_ROOT ]]
cp "$test_dir/roster-before" "$TEST_ROSTER_FILE"
/bin/bash "$test_dir/plan.sh" "$root" >"$test_dir/out" 2>"$test_dir/err"
echo 'PASS confirmation: 人間の所属を読めなければ新規と決めず、一覧・保存・登録の前に止まる'

# 色は種類・印・名前・補足・件数の範囲を照合する。
env -u NO_COLOR TERM=xterm-256color python3 "$root/tests/ui-pty.py" err "$test_dir/color-out" "$test_dir/color-err" -- /bin/bash "$test_dir/plan.sh" "$root"
esc=$'\033'
grep -qF "$esc[1m  エージェント$esc[0m" "$test_dir/color-err"
grep -qF "    $esc[38;5;28m+$esc[0m shop-planner-owner" "$test_dir/color-err"
grep -qF '    ~ shop-orchestrator-owner' "$test_dir/color-err"
grep -qF "    $esc[38;5;244m·$esc[0m $esc[38;5;244mshop-verify$esc[0m" "$test_dir/color-err"
grep -qF "    $esc[1;38;5;166m!$esc[0m Dependabot" "$test_dir/color-err"
grep -qF "    $esc[38;5;244m-$esc[0m old-extension  $esc[38;5;244mエージェントは残す$esc[0m" "$test_dir/color-err"
grep -qF "$esc[38;5;28m+$esc[0m6" "$test_dir/color-err"
echo 'PASS confirmation: 種類は太字、記号と補足は設計の色、名前は既定の色で表示する'

for mode in no-color dumb; do
 if [[ $mode == no-color ]]; then settings=(TERM=xterm-256color NO_COLOR=); else settings=(TERM=dumb); fi
 env -u NO_COLOR "${settings[@]}" python3 "$root/tests/ui-pty.py" err "$test_dir/$mode.out" "$test_dir/$mode.err" -- /bin/bash "$test_dir/plan.sh" "$root"
 ! grep -qF "$esc" "$test_dir/$mode.err"
 tr -d '\r' <"$test_dir/$mode.err" >"$test_dir/$mode.txt"
 cmp "$test_dir/err" "$test_dir/$mode.txt"
done
echo 'PASS confirmation: NO_COLOR と dumb でも同じ一覧と記号を出し、制御文字を付けない'

# yes だけを受け付ける。no と Enter は今の文・終了コード1で中止する。
for answer in no ''; do
 printf '%s\n' "$answer" >"$test_dir/input"
 if /bin/bash "$test_dir/plan.sh" "$root" confirm <"$test_dir/input" >"$test_dir/out" 2>"$test_dir/err"; then exit 1; else [[ $? == 1 ]]; fi
 grep -qxF 'エラー: 中止しました。答えは保存していません。' "$test_dir/err"
 [[ ! -s $test_dir/out ]]
done
printf 'YES\nmaybe\nyes\n' >"$test_dir/input"
/bin/bash "$test_dir/plan.sh" "$root" confirm <"$test_dir/input" >"$test_dir/out" 2>"$test_dir/err"
grep -qxF accepted "$test_dir/out"
[[ $(grep -c '^✖ ' "$test_dir/err") == 2 ]]
[[ $(grep -c '^  エージェント$' "$test_dir/err") == 1 ]]
[[ $(grep -c '^? 保存して作りますか  yes/no$' "$test_dir/err") == 1 ]]
[[ $(grep -c '^› no ' "$test_dir/err") == 3 ]]
! grep -qF "$esc" "$test_dir/err"
[[ ! -e $TEMPLATE_STATE_ROOT ]]
echo 'PASS confirmation: yes/no/Enter の動きと終了コードを保ち、聞き直しても一覧と問いを繰り返さない'

# 端末では誤った入力と理由だけを消す。問いと一覧は一度だけ残る。
env -u NO_COLOR python3 "$root/tests/question-pty.py" "$test_dir/retry.raw" "$test_dir/input" -- /bin/bash "$test_dir/plan.sh" "$root" confirm
python3 -I - "$root/tests/ansi-to-png.py" "$test_dir/retry.raw" <<'PY'
import importlib.util
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("ansi_to_png", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
terminal = module.Terminal(100, 40)
terminal.feed(open(sys.argv[2], "rb").read().decode("utf-8", "replace"), final=True)
text = module.plain_text(terminal.lines())
assert text.count("  エージェント\n") == 1, text
assert text.count("? 保存して作りますか  yes/no") == 1, text
assert "✖" not in text and "maybe" not in text and "YES" not in text, text
assert "› no yes" in text and "accepted" in text, text
PY
echo 'PASS confirmation: 端末では聞き直した入力と理由だけを消し、一覧と問いと受け付けた入力を残す'

/bin/bash -s -- "$root" 2>"$test_dir/only.err" <<'ONLY'
source "$1/lib/ui.sh"
source "$1/lib/questions.sh"
confirmation_show '[{"group":"リポジトリ","mark":"keep","name":"example/one","value":""}]'
ONLY
printf '\n  リポジトリ\n    · example/one\n\n  ·1\n' >"$test_dir/only.expected"
cmp "$test_dir/only.expected" "$test_dir/only.err"
echo 'PASS confirmation: 行のない種類と件数0の記号は出さない'
