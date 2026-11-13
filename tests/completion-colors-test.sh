#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/completion-colors-test.XXXXXX")
# 標準エラーを err に向けたまま止まっても、trap が err 自身へ書き足し続けないよう、元の標準エラーを控えて出す。
exec 8>&2
trap 'test_exit=$?; if [[ $test_exit != 0 ]]; then cat "$test_dir/out" "$test_dir/err" >&8; fi; rm -rf -- "$test_dir"' EXIT
esc=$'\033'
cat >"$test_dir/driver" <<'DRIVER'
set -euo pipefail
root=$1
source "$root/lib/ui.sh"
source "$root/lib/project.sh"
source "$root/lib/webhooks.sh"
source "$root/lib/installation.sh"
uses_runtime() { return 0; }
ui_init
project_name=デモ; workspace_name=ワークスペース; enabled='orchestrator dependabot-merger'; dependabot_webhook=true
created_agents=1; created_squads=1; created_autopilots=2; agent_home=/tmp/agent-home
setup_installation_rows='[{"name":"ラベル 開発","status":"一致","reason":""},{"name":"エージェント demo-verify","status":"要確認","reason":"定義と一致しません。"}]'
setup_webhook_rows='[{"repository":"example/one","trigger":"作成","registration":"作成","delivery":"成功（HTTP 200）","reason":""},{"repository":"example/two","trigger":"既存","registration":"既存","delivery":"記録なし","reason":"Webhook の配信の記録がありません。"},{"repository":"example/three","trigger":"既存","registration":"飛ばした","delivery":"失敗（HTTP 500）","reason":"理由です。"}]'
setup_issue_rows='[{"identifier":"ISSUE-1","title":"一つ目","action":"created"},{"identifier":"ISSUE-2","title":"C:\\work の設定","action":"existing"}]'
setup_issue_failures='[{"title":"三つ目","reason":"起票できません。"}]'
project_completion
DRIVER
run_pty() { env -i PATH="$PATH" HOME="$test_dir" "$@" python3 "$root/tests/ui-pty.py" out "$test_dir/out" "$test_dir/err" -- /bin/bash "$test_dir/driver" "$root"; tr -d '\r' <"$test_dir/out" >"$test_dir/screen"; }
paint() { printf '\033[%sm%s\033[0m' "$1" "$2"; }
success=38\;5\;28 warning=1\;38\;5\;166 error=1\;38\;5\;196 done=1\;38\;5\;30 grey=38\;5\;244 active=38\;5\;32 strong=1

# 端末の標準出力では、印・見出し・案内の記号・コマンドに種類の色が付き、本文は既定の色のまま。
run_pty TERM=xterm-256color
grep -qxF "$(paint $done '✔ デモ')  $(paint $grey 'ワークスペース  +1 エージェント  +1 スクワッド  +2 オートパイロット')" "$test_dir/screen"
grep -qxF "  $(paint $success ✔) ラベル 開発" "$test_dir/screen"
grep -qxF "  $(paint $warning '!') エージェント demo-verify  $(paint $grey '定義と一致しません。')" "$test_dir/screen"
grep -qxF "  example/one    $(paint $success ✔) トリガー  $(paint $success ✔) 登録  $(paint $success ✔) 配信 $(paint $grey 200)" "$test_dir/screen"
grep -qxF "  example/two    $(paint $success ✔) トリガー  $(paint $success ✔) 登録  $(paint $warning '!') 配信  $(paint $grey 'Webhook の配信の記録がありません。')" "$test_dir/screen"
grep -qxF "  example/three  $(paint $success ✔) トリガー  $(paint $grey ·) 登録  $(paint $error ✖) 配信 $(paint $grey 500)  $(paint $grey 理由です。)" "$test_dir/screen"
grep -qxF "  $(paint $success +) ISSUE-1  一つ目" "$test_dir/screen"
grep -qxF "  $(paint $grey ·) $(paint $grey 'ISSUE-2  C:\work の設定')" "$test_dir/screen"
grep -qxF "  $(paint $error ✖) 三つ目  $(paint $grey 起票できません。)" "$test_dir/screen"
grep -qxF "  $(paint $active ›) 表示したタスクを対象のプロジェクトで開き、担当と本文に沿って作業してください。" "$test_dir/screen"
grep -qxF "      $(paint $strong 'CLAUDE_CONFIG_DIR=/tmp/agent-home/claude claude')" "$test_dir/screen"
grep -qxF "      $(paint $strong 'CODEX_HOME=/tmp/agent-home/codex codex login')" "$test_dir/screen"
echo 'PASS completion color: 端末では印・見出し・案内の記号・コマンドに種類の色が付き、補足と理由は灰、本文は既定の色のまま'

# 色を付けない条件では、制御文字を出さず、文字は同じ。
cp "$test_dir/screen" "$test_dir/screen-color"
sed "s/$esc\[[0-9;]*m//g" "$test_dir/screen-color" >"$test_dir/screen-stripped"
for env_args in 'TERM=xterm-256color NO_COLOR=1' 'TERM=dumb' 'TERM='; do
	# shellcheck disable=SC2086
	run_pty $env_args
	! grep -qF "$esc" "$test_dir/screen"
	cmp -s "$test_dir/screen" "$test_dir/screen-stripped"
done
env -i PATH="$PATH" HOME="$test_dir" TERM=xterm-256color /bin/bash "$test_dir/driver" "$root" >"$test_dir/out" 2>"$test_dir/err"
! grep -qF "$esc" "$test_dir/out"
cmp -s "$test_dir/out" "$test_dir/screen-stripped"
grep -qxF '  example/three  ✔ トリガー  · 登録  ✖ 配信 500  理由です。' "$test_dir/out"
echo 'PASS completion color: ファイル・NO_COLOR・dumb・TERM 空では制御文字がなく、色を除いた文字と同じ'

# 画面の形: 見出し、字下げ、塊の区切り、案内。古い表示（件数の文、見出しの行、結果の語、「記録なし」）は出さない。
cat >"$test_dir/expected" <<'EXPECTED'

✔ デモ  ワークスペース  +1 エージェント  +1 スクワッド  +2 オートパイロット

  ✔ ラベル 開発
  ! エージェント demo-verify  定義と一致しません。

  example/one    ✔ トリガー  ✔ 登録  ✔ 配信 200
  example/two    ✔ トリガー  ✔ 登録  ! 配信  Webhook の配信の記録がありません。
  example/three  ✔ トリガー  · 登録  ✖ 配信 500  理由です。

  + ISSUE-1  一つ目
  · ISSUE-2  C:\work の設定
  ✖ 三つ目  起票できません。

  › 表示したタスクを対象のプロジェクトで開き、担当と本文に沿って作業してください。
  › ひな形の記入は skeleton/ の案内を参照してください。
  › Dependabot のイベントフィルターや登録を飛ばした場合の手順は、manual.md の「人間が行う Webhook の登録」を参照してください。
  › エージェント用のログインが切れた場合は、次を実行してから bash setup.sh を流し直してください。
      CLAUDE_CONFIG_DIR=/tmp/agent-home/claude claude
      CODEX_HOME=/tmp/agent-home/codex codex login
EXPECTED
cmp -s "$test_dir/out" "$test_dir/expected" || { diff "$test_dir/expected" "$test_dir/out" >&2; exit 1; }
! grep -qE '今回作った件数|プロジェクトの設定が終わりました|導入の確認:|Webhook の登録:|起票したタスク:|起票できなかったタスク:|次にすること:|記録なし|（新規）|（既存）|: 一致|: 要確認' "$test_dir/out"
! grep -rqF 'ui_result' "$root/lib" "$root/setup.sh" "$root/scripts"
echo 'PASS completion screen: 全項目を印で並べ、塊を空行で区切り、古い表示と「記録なし」を出さない'

# 行のない塊は、前の空行ごと出さない。残っている前回の Webhook のトリガーは、警告の印の行で出す。
cat >"$test_dir/driver-empty" <<'DRIVER'
set -euo pipefail
root=$1
source "$root/lib/ui.sh"
source "$root/lib/project.sh"
source "$root/lib/webhooks.sh"
source "$root/lib/installation.sh"
uses_runtime() { [[ $1 == codex ]]; }
ui_init
project_name=デモ; workspace_id=workspace-id; workspace_name=; enabled='orchestrator'; dependabot_webhook=false
created_agents=0; created_squads=0; created_autopilots=0; agent_home=/tmp/agent-home
setup_installation_rows='[]'
setup_webhook_rows='[]'
setup_webhook_leftovers='[{"repository":"example/old","state":"残っている"},{"repository":"example/unknown","state":"確認できない"}]'
setup_issue_rows='[]'
setup_issue_failures='[]'
project_completion
DRIVER
env -i PATH="$PATH" HOME="$test_dir" TERM=dumb /bin/bash "$test_dir/driver-empty" "$root" >"$test_dir/out" 2>"$test_dir/err"
cat >"$test_dir/expected" <<'EXPECTED'

✔ デモ  workspace-id

  ! example/old  Webhook を使わない答えですが、前の実行で作った Webhook のトリガーが残っています。外すよう起票しました。
  ! example/unknown  前の実行で作った Webhook のトリガーが残っているかを確認できませんでした。Multica の画面で確かめてください。

  › 表示したタスクを対象のプロジェクトで開き、担当と本文に沿って作業してください。
  › ひな形の記入は skeleton/ の案内を参照してください。
  › Dependabot の役は外したため、この役の Webhook の登録は不要です。
  › エージェント用のログインが切れた場合は、次を実行してから bash setup.sh を流し直してください。
      CODEX_HOME=/tmp/agent-home/codex codex login
EXPECTED
cmp -s "$test_dir/out" "$test_dir/expected" || { diff "$test_dir/expected" "$test_dir/out" >&2; exit 1; }
echo 'PASS completion screen: 行のない塊は空行ごと省き、件数が 0 の種類は出さず、残っているトリガーは警告の行にする'
