#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/setup-fixture.sh"
manifest
esc=$'\033'
pty_err() { env -u NO_COLOR "$@" python3 "$root/tests/ui-pty.py" err "$test_dir/pty-out" "$test_dir/pty-err" --stdin "$test_dir/pty-input" -- /bin/bash "$test_dir/package/setup.sh"; }
printf '\n' >"$test_dir/pty-input"

# ui_error と ui_warning は、印を色の有無によらず付け、端末のときだけ行全体を種類の色にする。
probe='source "$1/lib/ui.sh"; ui_init; ui_error 止まる理由; ui_warning 確かめてください'
env -i PATH="$PATH" HOME="$test_dir" TERM=xterm-256color python3 "$root/tests/ui-pty.py" err "$test_dir/out" "$test_dir/err" -- bash -c "$probe" _ "$root"
grep -qF "$esc[1;38;5;196mエラー: 止まる理由$esc[0m" "$test_dir/err"
grep -qF "$esc[1;38;5;166m警告: 確かめてください$esc[0m" "$test_dir/err"
env -i PATH="$PATH" HOME="$test_dir" TERM=xterm-256color NO_COLOR=1 python3 "$root/tests/ui-pty.py" err "$test_dir/out" "$test_dir/err" -- bash -c "$probe" _ "$root"
! grep -qF "$esc" "$test_dir/err"
tr -d '\r' <"$test_dir/err" | grep -qxF 'エラー: 止まる理由'
tr -d '\r' <"$test_dir/err" | grep -qxF '警告: 確かめてください'
bash -c "$probe" _ "$root" >"$test_dir/out" 2>"$test_dir/err"
[[ ! -s $test_dir/out ]]
[[ $(cat "$test_dir/err") == $'エラー: 止まる理由\n警告: 確かめてください' ]]
echo 'PASS marks: エラー: と警告: の印は色の有無によらず付き、色は端末の標準エラー出力だけで行全体に付く'

# MANIFEST の確認より前の die は、端末でも色を付けず、印だけを付ける。
env -u NO_COLOR TERM=xterm-256color python3 "$root/tests/ui-pty.py" err "$test_dir/out" "$test_dir/err" -- /bin/bash "$test_dir/package/setup.sh" x || true
! grep -qF "$esc" "$test_dir/err"
tr -d '\r' <"$test_dir/err" | grep -qxF 'エラー: 使い方: bash setup.sh [--extension <拡張のディレクトリ>] [--no-checkout]（ほかの値は質問に答えて入力する）'
mv "$test_dir/package/MANIFEST" "$test_dir/MANIFEST.saved"
env -u NO_COLOR TERM=xterm-256color python3 "$root/tests/ui-pty.py" err "$test_dir/out" "$test_dir/err" -- /bin/bash "$test_dir/package/setup.sh" </dev/null || true
! grep -qF "$esc" "$test_dir/err"
tr -d '\r' <"$test_dir/err" | grep -qE '^エラー: 原本のファイルが不足しているか改変されています。MANIFEST がありません。'
mv "$test_dir/MANIFEST.saved" "$test_dir/package/MANIFEST"
echo 'PASS marks: MANIFEST の確認より前の die は、端末でも制御文字を出さず印だけを付ける'

# MANIFEST の確認のあとの die は、印と色を付ける。続く案内の行は色を付けない。
TEST_LOGIN=no pty_err TERM=xterm-256color
grep -qF "$esc[1;38;5;196mエラー: Multica の接続とログインを確認してください。$esc[0m" "$test_dir/pty-err"
grep -qF "$esc[1;38;5;196mエラー: ログイン後に流し直してください。ここではログインや設定の変更を行いません。$esc[0m" "$test_dir/pty-err"
tr -d '\r' <"$test_dir/pty-err" | grep -qxF 'multica --server-url https://example.test login'
TEST_LOGIN=no pty_err TERM=dumb
! grep -qF "$esc" "$test_dir/pty-err"
tr -d '\r' <"$test_dir/pty-err" | grep -qxF 'エラー: ログイン後に流し直してください。ここではログインや設定の変更を行いません。'
no_state
echo 'PASS marks: MANIFEST の確認のあとの die は印と色を付け、色を付けない画面でも印で分かる'

# コマンド置換で受け取る失敗の理由は、色の制御文字も印の「エラー:」も含まない。
cat >"$test_dir/reason-driver" <<'DRIVER'
set -euo pipefail
root=$1
source "$root/lib/ui.sh"
source "$root/lib/project.sh"
die() { ui_error "$*"; exit 1; }
ensure_setup_issue() { ui_warning '途中の警告'; die '起票に失敗しました。権限を確認してください。'; }
ui_color_err=yes
project_work=$2
setup_issue_rows='[]'
setup_issue_failures='[]'
queue_project_issue repository-rules '["example/one"]' actor example/one
jq -r '.[0].reason' <<<"$setup_issue_failures"
DRIVER
mkdir "$test_dir/reason-work"
/bin/bash "$test_dir/reason-driver" "$root" "$test_dir/reason-work" >"$test_dir/out" 2>"$test_dir/err"
[[ $(cat "$test_dir/out") == '起票に失敗しました。権限を確認してください。' ]]
! grep -qF "$esc" "$test_dir/out" "$test_dir/reason-work/issue-error"
echo 'PASS marks: 起票の失敗の理由は色なしで受け取り、「エラー:」を外して issue と完了の表示に渡す'

# 注意の文は、種類が警告のときだけ行ごとに印と色を付ける。説明の種類では印も色も付けない。
cat >"$test_dir/notice-driver" <<'DRIVER'
set -euo pipefail
root=$1
source "$root/lib/ui.sh"
source "$root/lib/questions.sh"
ui_init
question_begin 題 説明 例
question_notice=$'一行目\n二行目'
question_notice_show
question_notice_kind=warning
question_notice_show
DRIVER
env -i PATH="$PATH" HOME="$test_dir" TERM=xterm-256color python3 "$root/tests/ui-pty.py" err "$test_dir/out" "$test_dir/err" -- /bin/bash "$test_dir/notice-driver" "$root"
tr -d '\r' <"$test_dir/err" >"$test_dir/notice"
[[ $(sed -n 1,2p "$test_dir/notice") == $'一行目\n二行目' ]]
[[ $(sed -n 3p "$test_dir/notice") == "$esc[1;38;5;166m警告: 一行目$esc[0m" ]]
[[ $(sed -n 4p "$test_dir/notice") == "$esc[1;38;5;166m警告: 二行目$esc[0m" ]]
echo 'PASS marks: 質問に添える注意は、警告のときだけ行ごとに警告: の印と色を付ける'
