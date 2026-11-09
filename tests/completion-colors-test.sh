#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/completion-colors-test.XXXXXX")
trap 'test_exit=$?; if [[ $test_exit != 0 ]]; then cat "$test_dir/out" "$test_dir/err" >&2; fi; rm -rf -- "$test_dir"' EXIT
esc=$'\033'
cat >"$test_dir/driver" <<'DRIVER'
set -euo pipefail
root=$1
source "$root/lib/ui.sh"
source "$root/lib/project.sh"
source "$root/lib/webhooks.sh"
source "$root/lib/installation.sh"
uses_runtime() { return 1; }
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
success=38\;5\;28 warning=1\;38\;5\;166 error=1\;38\;5\;196 done=1\;38\;5\;30

# 端末の標準出力では、結果の語と完了の案内の行にだけ色が付く。
run_pty TERM=xterm-256color
grep -qxF "$(paint $done 'プロジェクトの設定が終わりました: デモ（ワークスペース）')" "$test_dir/screen"
grep -qxF "$(paint $done '次にすること:')" "$test_dir/screen"
grep -qxF "  ラベル 開発: $(paint $success 一致)" "$test_dir/screen"
grep -qxF "  エージェント demo-verify: $(paint $warning 要確認)。定義と一致しません。" "$test_dir/screen"
grep -qxF "  example/one: トリガー $(paint $success 作成)、登録 $(paint $success 作成)、配信 $(paint $success 成功)（HTTP 200）" "$test_dir/screen"
grep -qxF "  example/two: トリガー $(paint $success 既存)、登録 $(paint $success 既存)、配信 $(paint $warning 記録なし)。Webhook の配信の記録がありません。" "$test_dir/screen"
grep -qxF "  example/three: トリガー $(paint $success 既存)、登録 $(paint $warning 飛ばした)、配信 $(paint $error 失敗)（HTTP 500）。理由です。" "$test_dir/screen"
grep -qxF "  ISSUE-1 一つ目（$(paint $success 新規)）" "$test_dir/screen"
grep -qxF "  ISSUE-2 C:\work の設定（$(paint $success 既存)）" "$test_dir/screen"
# 件数、見出し、失敗した起票、案内の本文は、端末の既定の色のまま。
grep -qxF '今回作った件数: エージェント 1 件、スクワッド 1 件、オートパイロット 2 件' "$test_dir/screen"
grep -qxF '起票できなかった issue:' "$test_dir/screen"
grep -qxF '  三つ目: 起票できません。' "$test_dir/screen"
grep -qxF '表示した issue を対象のプロジェクトで開き、担当と本文に沿って作業してください。' "$test_dir/screen"
echo 'PASS completion color: 端末では結果の語と完了の案内の行に種類の色が付き、括弧の補足と理由は既定の色のまま'

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
grep -qxF '  example/three: トリガー 既存、登録 飛ばした、配信 失敗（HTTP 500）。理由です。' "$test_dir/out"
echo 'PASS completion color: ファイル・NO_COLOR・dumb・TERM 空では制御文字がなく、色を除いた文字と同じ'
