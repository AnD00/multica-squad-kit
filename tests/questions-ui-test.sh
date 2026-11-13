#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/setup-fixture.sh"
manifest
export TEMPLATE_STATE_ROOT="$test_dir/ui-state"
# すべて確認の no まで読み取りのみ。実サービスへは呼び出さない。
happy() { printf '1\nShop\n\n1,2\n\n\n1\n\n\nno\n' >"$test_dir/input"; }
happy
deny
no_state
# 答えた質問は 1 行に縮み、題は 9 問で最も長い題の幅にそろう。開いた質問は ●○ で進みを示す。
for entry in '? ワークスペース  ●○○○○○○○○' '? プロジェクト  ●●○○○○○○○' '? プロジェクトの区別  ●●●○○○○○○' '? リポジトリ  ●●●●○○○○○' '? メンバーの区別  ●●●●●○○○○' '? スクワッドに入れる人間  ●●●●●●○○○' '? 使うランタイム  ●●●●●●●○○' '? 外す役  ●●●●●●●●○' '? Dependabot の PR の Webhook  ●●●●●●●●●'; do grep -qxF "$entry" "$test_dir/err"; done
for entry in '✔ ワークスペース               Workspace A' '✔ プロジェクト                 Shop  新しく作る' '✔ プロジェクトの区別           shop' '✔ リポジトリ                   example/one  example/two' '✔ メンバーの区別               owner' '✔ スクワッドに入れる人間       Member A' '✔ 使うランタイム               Claude Code  Codex' '✔ 外す役                       何も外さない' '✔ Dependabot の PR の Webhook  使わない'; do grep -qxF "$entry" "$test_dir/err"; done
[[ $(grep -c '^? ' "$test_dir/err") == 11 ]]
[[ $(grep -c '^✔ ' "$test_dir/err") == 9 ]]
[[ $(grep -c '^› ' "$test_dir/err") == 11 ]]
# 出さない文字。旧い画面の見出し・例・既定値・入力の行は残さない。
! grep -qE '^質問 \(|^例:|^既定値:|^入力 |入力 \[' "$test_dir/err"
# 入力が端末でないときは書き換えない。上へ戻る制御と、以降を消す制御を出さない。
[[ -s $test_dir/err ]]
! grep -aqE $'\033\\[[0-9]*(A|J)' "$test_dir/err"
# 画面に出る順は、題・入力・縮めた答えの繰り返しになる。
awk '/^\? / {print "?"} /^› / {print "›"} /^✔ / {print "✔"}' "$test_dir/err" | tr -d '\n' >"$test_dir/question-order"
[[ $(cat "$test_dir/question-order") == "?›$(printf '?›✔%.0s' 1 2 3 4 5 6 7 8 9)?›" ]]
[[ $(grep -c '^    + shop-.*-owner$' "$test_dir/err") == 17 ]]
! grep -qE '^エージェント:' "$test_dir/err"
! grep -qF '名前の規則:' "$test_dir/err"
grep -qxF '    + SHOP-OWNER' "$test_dir/err"
grep -qxF '    + shop-verify' "$test_dir/err"
[[ $(grep -c '^    + .*shop example/' "$test_dir/err") == 4 ]]
grep -qxF '    + 使用上限の見張り shop-owner' "$test_dir/err"
grep -qxF '    + Dependabot の PR の週次の確認 shop example/two' "$test_dir/err"
grep -qxF '    + Member A' "$test_dir/err"
# Webhook は既定で使わず、最後の確認にもそう出す。
awk '/^\? Dependabot の PR の Webhook/ {show=1} /^  エージェント$/ {show=0} show {print}' "$test_dir/err" >"$test_dir/webhook-question"
grep -qxF '› 1 ' "$test_dir/webhook-question"
grep -qxF '    1  使わない（週次のスケジュールだけで扱う。Webhook の登録とタスクの起票をしない）' "$test_dir/webhook-question"
! grep -qF 'Dependabot の PR の Webhook:' "$test_dir/err"
# 説明に、人の目印との違いと、使う場所がある。
grep -qF '人の目印とは別です' "$test_dir/err"
grep -qF 'ホストと AI の利用枠' "$test_dir/err"
grep -qF '選んだものだけに push と PR' "$test_dir/err"
awk '/^\? リポジトリ/ {show=1} /^\? メンバーの区別/ {show=0} show {print}' "$test_dir/err" >"$test_dir/repository-question"
grep -qxF '    1  example/one' "$test_dir/repository-question"
grep -qxF '    2  example/two' "$test_dir/repository-question"
! grep -qE 'https://|git@|\.git' "$test_dir/repository-question"
awk '/^\? 外す役/ {show=1} /^\? Dependabot の PR の Webhook/ {show=0} show {print}' "$test_dir/err" >"$test_dir/role-question"
awk '/^  常に入る役:/ {fixed=NR} /^  リーダー（orchestrator）:/ {leader=NR} /^  外せる役:/ {optional=NR} /^    1  要件定義:/ {first=NR} END {exit !(fixed<leader && leader<optional && optional<first)}' "$test_dir/role-question"
grep -qF 'エージェント: shop-orchestrator-owner' "$test_dir/role-question"
grep -qF 'エージェント: shop-claude-implementer-owner、shop-claude-fixer-owner' "$test_dir/role-question"
grep -qF 'エージェント: shop-codex-implementer-owner、shop-codex-fixer-owner' "$test_dir/role-question"
grep -qxF '    6  セキュリティ: 危険な実装を確認する。' "$test_dir/role-question"
grep -qF 'オートパイロット: 週 1 回の依存ライブラリの脆弱性チェック shop example/one、週 1 回の依存ライブラリの脆弱性チェック shop example/two' "$test_dir/role-question"
grep -qxF '    10  PR の CI の見張り: CIの結果を知らせる。' "$test_dir/role-question"
grep -qF '見張り: リーダーが PR ごとに置く CI の見張り' "$test_dir/role-question"
grep -qF 'オートパイロット: 使用上限の見張り shop-owner' "$test_dir/role-question"
grep -qF 'ほかに変わること: Webhook を使うかを聞かず、GitHub への Webhook の登録をしない' "$test_dir/role-question"
! grep -qF '選べない役:' "$test_dir/role-question"
! grep -qE '^  shop-(orchestrator|codex-fixer)-owner（' "$test_dir/err"
echo 'PASS display: リポジトリ候補を OWNER/REPO にそろえ、リーダーを先に示し、外せる役と二つの実装・修正の組を分ける'
# ファイルへ出した画面には色の制御文字がない。端末なら種類ごとの色が付き、制御文字を除くと同じ文字になる。
esc=$'\033'
! grep -qF "$esc" "$test_dir/err"
cp "$test_dir/err" "$test_dir/err-plain"
{ printf '\n'; printf 'x\n'; cat "$test_dir/input"; } >"$test_dir/pty-input"
pty_setup() { env -u NO_COLOR "$@" python3 "$root/tests/ui-pty.py" err "$test_dir/pty-out" "$test_dir/pty-err" --stdin "$test_dir/pty-input" -- /bin/bash "$test_dir/package/setup.sh"; }
pty_setup TERM=xterm-256color
# 端末の選択肢は 100 桁に収まり、続く行も元の説明の開始列から始まる。
# ファイル出力との照合で、6 番と 12 番を含む説明の文字が欠けないことも確認する。
python3 - "$test_dir/role-question" "$test_dir/pty-err" <<'PY'
import re
import sys
import unicodedata
from pathlib import Path

plain = Path(sys.argv[1]).read_text()
terminal = re.sub(r"\x1b\[[0-9;]*m", "", Path(sys.argv[2]).read_text())

def choices(text):
    start = text.index("    1  要件定義:")
    end = text.index("    0  何も外さない", start) + len("    0  何も外さない")
    return text[start:end].splitlines()

expected, actual = choices(plain), choices(terminal)
position = 0
wrapped = []
for line in expected:
    indent = len(line) - len(line.lstrip(" "))
    combined = actual[position]
    position += 1
    while combined != line:
        assert line.startswith(combined), (line, combined)
        continuation = actual[position]
        assert continuation.startswith(" " * indent), continuation
        combined += continuation[indent:]
        wrapped.append(line)
        position += 1
assert position == len(actual)
assert any("脆弱性チェック" in line for line in wrapped)
assert any("Dependabot の PR の週次の確認" in line for line in wrapped)
for line in actual:
    width = sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in line)
    assert width <= 100, (width, line)
PY
echo 'PASS wrap: 長い選択肢は端末の幅に収まり、説明の文字と継続行の字下げを保つ'
grep -qF "$esc[1;38;5;32m? ワークスペース$esc[0m  $esc[38;5;32m●$esc[0m$esc[38;5;244m○$esc[0m" "$test_dir/pty-err"
grep -qF "$esc[38;5;32m●$esc[0m$esc[38;5;32m●$esc[0m$esc[38;5;244m○$esc[0m" "$test_dir/pty-err"
# 説明と例は、字下げ 2 の灰の行。例は例の値だけ。
grep -qF "$esc[38;5;244m  エージェントのチームを作る置き場です。自分が入っているものから選びます。$esc[0m" "$test_dir/pty-err"
grep -qF "$esc[38;5;244m  1（一覧の番号）$esc[0m" "$test_dir/pty-err"
# 選択肢は字下げ 4 で、番号は太字の紫。
grep -qF "    $esc[1;38;5;98m1$esc[0m  Workspace A" "$test_dir/pty-err"
# 入力の行は青の › と空白。既定値は灰で続く。
grep -qF "$esc[38;5;32m›$esc[0m $esc[38;5;244mshop$esc[0m " "$test_dir/pty-err"
grep -qF "$esc[1;38;5;196m✖$esc[0m 1つ以上の番号を、表示された候補から半角数字で選んでください。空のままでは進めません。" "$test_dir/pty-err"
! grep -qF 'エラー: 1つ以上の番号を' "$test_dir/pty-err"
# 縮めた答えは緑の ✔、補足は灰。
grep -qF "$esc[38;5;28m✔$esc[0m ワークスペース               Workspace A" "$test_dir/pty-err"
grep -qF "Shop  $esc[38;5;244m新しく作る$esc[0m" "$test_dir/pty-err"
pty_setup TERM=xterm-256color NO_COLOR=
! grep -qF "$esc" "$test_dir/pty-err"
grep -qF '✖ 1つ以上の番号を' "$test_dir/pty-err"
pty_setup TERM=dumb
! grep -qF "$esc" "$test_dir/pty-err"
# 色を付けない画面は、文字だけで題・入力・エラーを見分けられる。
grep -qE '^\? ワークスペース  ●' "$test_dir/pty-err"
grep -qE '^› ' "$test_dir/pty-err"
grep -qE '^✖ ' "$test_dir/pty-err"
echo 'PASS color: 質問の画面は端末のとき種類ごとの色が付き、ファイル・NO_COLOR・dumb では制御文字がなく、題・入力・エラーは印で分かる'
echo 'PASS questions: 8問の見出し・説明・例・既定と、名前と記号で示した予定を表示し、キャンセルで保存しない'

export TEST_PROJECTS_FILE="$test_dir/projects.json"
echo '[]' >"$TEST_PROJECTS_FILE"
printf '1\n\n123\n新しい店\nshop\n1\n\n\n1\n\n\nno\n' >"$test_dir/input"
deny; no_state
grep -qF 'まだプロジェクトがありません。新しい名前を入れると作ります' "$test_dir/err"
grep -qF 'プロジェクトの名前が空' "$test_dir/err"
grep -qF '数字だけにせず' "$test_dir/err"
grep -qF '新しい店  新しく作る' "$test_dir/err"
echo 'PASS questions: プロジェクト0件では新しい名前を直接待ち、空と数字だけの名前を同じ質問で直せる'
unset TEST_PROJECTS_FILE

printf '1\nShop\nBad\nx\n1shop\nshop-front\nabcdefghijklm\nshop\n1\nBad\nm\n1owner\nowner-name\nabcdefghijklm\nmember2\n0\n1\n0\n\nno\n' >"$test_dir/input"
deny; no_state
[[ $(grep -c '大文字・ハイフン・記号は使えません' "$test_dir/err") == 10 ]]
grep -qxF '    + SHOP-MEMBER2' "$test_dir/err"
echo 'PASS questions: 両方の区別は英小文字から始まる英小文字と数字の2〜12文字だけを受け付ける'

export TEST_SQUADS_FILE="$test_dir/squads.json"
echo '[{"id":"squad-a","name":"SHOP-OWNER"}]' >"$TEST_SQUADS_FILE"
printf '1\nShop\nshop\n1\nowner\nowner2\n0\n1\n0\n\nno\n' >"$test_dir/input"
TEST_SQUAD_OWNER=someone-else deny; no_state
grep -qF 'ほかの人が作ったスクワッド' "$test_dir/err"
grep -qxF '    + SHOP-OWNER2' "$test_dir/err"
echo 'PASS questions: 他人のスクワッドと同名の目印は、同じ質問で別の値へ直せる'

export TEST_AGENTS_FILE="$test_dir/agents.json" TEST_SKILLS_FILE="$test_dir/skills.json" TEST_AUTOPILOTS_FILE="$test_dir/autopilots.json"
export TEST_RESOURCES_DIR="$test_dir/resources"
mkdir -p "$TEST_RESOURCES_DIR"
echo '[{"resource_type":"github_repo","resource_ref":{"url":"https://github.com/example/one"}}]' >"$TEST_RESOURCES_DIR/project-a.json"
echo '[{"id":"agent-a","name":"shop-designer-owner","owner_id":"member-a"}]' >"$TEST_AGENTS_FILE"
echo '[{"id":"skill-a","name":"shop-verify"}]' >"$TEST_SKILLS_FILE"
echo '{"autopilots":[{"id":"auto-a","title":"Dependabot の PR の週次の確認 shop example/one","project_id":"project-a","assignee_type":"agent","assignee_id":"agent-a"}]}' >"$TEST_AUTOPILOTS_FILE"
printf '1\n1\nshop\n1\nowner\n1\n1\n0\n\nno\n' >"$test_dir/input"
deny; no_state
grep -qxF '    ~ SHOP-OWNER' "$test_dir/err"
grep -qxF '    ~ shop-designer-owner' "$test_dir/err"
grep -qxF '    · example/one' "$test_dir/err"
grep -qxF '    · shop-verify' "$test_dir/err"
grep -qF 'Dependabot の PR の週次の確認 shop example/one' "$test_dir/err"
echo 'PASS questions: 自分のスクワッドは受け付け、名前で調べた新規・更新・既存利用を答えの一覧へ出す'
jq '.autopilots[0].assignee_id="another-person-agent"' "$TEST_AUTOPILOTS_FILE" >"$test_dir/foreign-auto"
mv "$test_dir/foreign-auto" "$TEST_AUTOPILOTS_FILE"
deny; no_state
grep -qF 'Dependabot の PR の週次の確認 shop example/one' "$test_dir/err"
grep -qxF '    ! Dependabot の PR の週次の確認 shop example/one  別の担当' "$test_dir/err"
echo 'PASS display: 名前と記号にしても、別担当の既存設定を保持する注意と対象を隠さない'
printf '[]\n' >"$TEST_AGENTS_FILE"
for template in "$root/common/agents/"*.md; do
 role=$(basename "$template" .md)
 jq --arg role "$role" '.+[{id:("existing-"+$role),name:("shop-"+$role+"-owner"),owner_id:"member-a"}]' "$TEST_AGENTS_FILE" >"$test_dir/next-agents"
 mv "$test_dir/next-agents" "$TEST_AGENTS_FILE"
done
cat >"$TEST_AUTOPILOTS_FILE" <<'AUTOS'
{"autopilots":[
 {"id":"auto-security","title":"週 1 回の依存ライブラリの脆弱性チェック shop example/one","project_id":"project-a","assignee_type":"agent","assignee_id":"existing-security-reviewer"},
 {"id":"auto-dependabot","title":"Dependabot の PR の週次の確認 shop example/one","project_id":"project-a","assignee_type":"agent","assignee_id":"existing-dependabot-merger"},
 {"id":"auto-usage","title":"使用上限の見張り shop-owner","project_id":"project-a","assignee_type":"agent","assignee_id":"existing-usage-monitor"}
]}
AUTOS
deny; no_state
[[ $(grep -c '^    ~ shop-.*-owner$' "$test_dir/err") == 17 ]]
[[ $(grep -c '^    ~ .*shop' "$test_dir/err") == 20 ]]
! grep -qF '保持する既存の設定:' "$test_dir/err"
echo 'PASS display: 全件が既存のときも正しく集計し、作り直す予定と表示しない'
echo '[{"id":"squad-a","name":"Shop-owner"}]' >"$TEST_SQUADS_FILE"
deny; no_state
grep -qxF '    ~ Shop-owner' "$test_dir/err"
echo 'PASS questions: 大文字・小文字が違っても既存の表記で引き継ぐ予定を表示する'
echo '[{"id":"squad-a","name":"Shop-owner"},{"id":"squad-b","name":"SHOP-OWNER"}]' >"$TEST_SQUADS_FILE"
deny; no_state
grep -qF '大文字小文字の違いだけのスクワッドが複数あります' "$test_dir/err"
echo 'PASS questions: 表記の違いだけの候補が複数なら登録前に止まる'
echo '[{"id":"squad-a","name":"Shop-owner"}]' >"$TEST_SQUADS_FILE"
printf '1\n1\nshop\n1\nowner\nowner2\n0\n1\n0\n\nno\n' >"$test_dir/input"
TEST_SQUAD_OWNER=someone-else deny; no_state
grep -qF 'ほかの人が作ったスクワッド' "$test_dir/err"
echo 'PASS questions: 表記が違っても他人のスクワッドの所有者確認を省かない'
unset TEST_SQUADS_FILE TEST_AGENTS_FILE TEST_SKILLS_FILE TEST_AUTOPILOTS_FILE TEST_RESOURCES_DIR

printf 'http://wrong.example.test\nhttps://offline.example.test\nhttps://okay.example.test\n1\n1\nsecure\n1\nowner\n0\n1\n0\n\nno\n' >"$test_dir/input"
TEST_SERVER='(not set)' TEST_UNREACHABLE_URL=https://offline.example.test deny; no_state
# 入力を受け付けないときは、題を出し直さず、理由と入力の行だけをもう一度出す。
[[ $(grep -c '^? サーバーの URL  ○○○○○○○○○$' "$test_dir/err") == 1 ]]
[[ $(grep -c '^✖ ' "$test_dir/err") == 2 ]]
grep -qxF '✔ サーバーの URL               https://okay.example.test' "$test_dir/err"
grep -qxF '? 外す役  ●●●●●●●●○' "$test_dir/err"
grep -qF 'https:// で始まるサーバー' "$test_dir/err"
grep -qF 'サーバーに接続できないか' "$test_dir/err"
echo 'PASS questions: 未設定のURLだけ9問目まで表示し、HTTPSでない入力と応答しない接続先を同じ質問へ戻す'

export TEST_WORKSPACES_FILE="$test_dir/workspaces.json"
echo '[]' >"$TEST_WORKSPACES_FILE"
: >"$test_dir/input"
deny; no_state
grep -qF '? ワークスペース  ●○○○○○○○○' "$test_dir/err"
grep -qF '管理者に招待' "$test_dir/err"
echo 'PASS questions: ワークスペース0件は説明と作成・招待の案内を出して保存前に止まる'
unset TEST_WORKSPACES_FILE

printf '1\nShop\nshop\n1\nowner\n0\n1\n99\n3 4\n6,11\n\nno\n' >"$test_dir/input"
deny; no_state
grep -qF '一覧の番号を' "$test_dir/err"
grep -qF '少なくとも一系統を残してください' "$test_dir/err"
grep -qF '  オートパイロット: 週 1 回の依存ライブラリの脆弱性チェック shop example/one' "$test_dir/err"
grep -qF '  オートパイロット: 使用上限の見張り shop-owner' "$test_dir/err"
# 最後の確認に、外した役を作る予定が残らない。
awk '/^  エージェント$/ {show=1} show {print}' "$test_dir/err" >"$test_dir/summary"
grep -qxF '  役' "$test_dir/summary"
grep -qxF '    - security-reviewer  shop-security-reviewer-owner  週 1 回の依存ライブラリの脆弱性チェック shop example/one  返事を待つ役の一覧から外れる' "$test_dir/summary"
grep -qxF '    - usage-monitor  shop-usage-monitor-owner  使用上限の見張り shop-owner' "$test_dir/summary"
awk '/^  役$/ {exit} {print}' "$test_dir/summary" >"$test_dir/summary-plan"
if grep -qE 'shop-(security-reviewer|usage-monitor)-owner' "$test_dir/summary-plan"; then exit 1; fi
[[ $(grep -c '^    + shop-.*-owner$' "$test_dir/summary") == 15 ]]
[[ $(grep -c '^    + .*shop example/' "$test_dir/summary") == 1 ]]
! grep -qF '名前の規則:' "$test_dir/summary"
echo 'PASS questions: 役は番号で説明と一緒に選び、両系統の除外をやり直せて、外した役と一緒に外れるものを確認する'

printf '1\nShop\nshop\n1\nowner\n0\n1\n1 2 3 5 6 7 8 9 10 11 12\nno\n' >"$test_dir/input"
deny; no_state
[[ $(grep -c '^    + shop-.*-owner$' "$test_dir/err") == 5 ]]
! grep -qxF '  オートパイロット' "$test_dir/err"
# Dependabot の役を外したら、Webhook は番号の見出しだけで聞かず、確認にも出さない。
grep -qxF '· Dependabot の PR の Webhook  Dependabot の役を外したので聞きません。' "$test_dir/err"
[[ $(grep -c 'Dependabot の PR の Webhook' "$test_dir/err") == 1 ]]
echo 'PASS display: 最小の3役とオートパイロット0件の構成も、外した分を予定に含めず表示する'

happy
TEST_FAIL=agents deny; no_state
grep -qF 'エージェント を取得できませんでした' "$test_dir/err"
echo 'PASS questions: 最終一覧の読み取りに失敗したら、未存在と決めず保存前に止まる'

printf '1\nShop\nshop\n1\nowner\n0\n1\n0\n\nmaybe\nno\n' >"$test_dir/input"
deny; no_state
grep -qF 'yes で続けるか、no で中止' "$test_dir/err"
! grep -qxF '  役' "$test_dir/err"
echo 'PASS questions: 最後の確認も不正な入力はやり直し、noなら状態を残さない'


export TEST_PROFILE_FILE="$test_dir/profile.json"
echo '{"id":"member-a","name":"Member A","email":"Mixed.User123456@example.test"}' >"$TEST_PROFILE_FILE"
printf '1\nAB\n\n1\n\n0\n1\n0\n\nno\n' >"$test_dir/input"
deny; no_state
grep -qxF '    + AB-MIXEDUSER123' "$test_dir/err"
echo 'PASS questions: プロジェクト名とメールから有効な既定を作り、2文字と12文字の目印を受け付ける'
unset TEST_PROFILE_FILE


# 候補が一つでも自動では選ばない。入力終了まで質問1にとどまる。
export TEST_WORKSPACES_FILE="$test_dir/single-workspace.json"
echo '[{"id":"ws-a","name":"Only workspace"}]' >"$TEST_WORKSPACES_FILE"
printf '\n' >"$test_dir/input"
: >"$TEST_CALLS"
MULTICA_WORKSPACE_ID=ws-a deny; no_state
[[ $(grep -cF '? ワークスペース  ●○○○○○○○○' "$test_dir/err") == 1 ]]
[[ $(grep -c '^› ' "$test_dir/err") == 3 ]]
grep -qF '✖ 1つ以上の番号を' "$test_dir/err"
! grep -qF '? プロジェクト ' "$test_dir/err"
! grep -q 'project list' "$TEST_CALLS"
grep -qxF '› ' "$test_dir/err"
unset TEST_WORKSPACES_FILE
echo 'PASS questions: 候補が一つでもCLIの設定だけでは選ばず、Enter のみでは後続の取得・保存へ進まない'

# 最後に保存と再実行も確認する。以降は「状態なし」の検査はしない。
printf '2\nShop\nshop\n1\nowner\n0\n1\n0\n\nyes\n' >"$test_dir/input"
run
cp "$TEMPLATE_STATE_ROOT/ws-b/shop.json" "$test_dir/saved-before"
mkdir -p "$TEMPLATE_STATE_ROOT/ws-a"
jq '.workspace_id="ws-a" | .workspace_name="Workspace A" | .project_name="Earlier" | .project_key="earlier"' "$test_dir/saved-before" >"$TEMPLATE_STATE_ROOT/ws-a/earlier.json"
touch -t 202001010000 "$TEMPLATE_STATE_ROOT/ws-a/earlier.json"
printf '\n2\n\n\n\n\n\n\n\n\nno\n' >"$test_dir/input"
MULTICA_WORKSPACE_ID=ws-a deny
cmp "$TEMPLATE_STATE_ROOT/ws-b/shop.json" "$test_dir/saved-before"
grep -qF 'Workspace B' "$test_dir/err"
[[ $(grep -cF '? ワークスペース  ●○○○○○○○○' "$test_dir/err") == 1 ]]
grep -qxF '✔ ワークスペース               Workspace B' "$test_dir/err"
echo 'PASS questions: 前回の答えとCLIの既定があっても Enter では進まず、番号で選んだ ws の保存値を使う'
