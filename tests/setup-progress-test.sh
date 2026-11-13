#!/usr/bin/env bash
# セットアップの作る間の表示（lib/ui.sh の ui_phase_*、ui_notice）を確かめる。
# 一覧が動いていないときは今までの表示のまま、書き換えない出力では終わった手順の行だけ、端末では同じ行の書き換えで出る。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/setup-progress-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT

# 一覧を使わないとき（試験や、一覧の外から呼ぶ関数）は、何も出さず、呼ぶ側が今までの表示に戻れる。
cat >"$test_dir/inactive.sh" <<'SH'
source "$1/lib/ui.sh"
ui_init
ui_phase_start 1
ui_phase_progress 1 2 "名前"
ui_phase_subject "名前"
ui_phase_done "値"
ui_phase_done_counted 3
ui_phase_fail "名前"
ui_notice add "本文" "値" && exit 11
ui_phase_active && exit 12
echo fallback-ok
SH
bash "$test_dir/inactive.sh" "$root" >"$test_dir/out" 2>"$test_dir/err"
[[ $(cat "$test_dir/out") == fallback-ok && ! -s $test_dir/err ]]
echo 'PASS setup-progress: 一覧が動いていないときは何も出さず、通知は 1 を返して今までの表示に戻れる'

# 子のプロセスの通知は置き場を通して親が出す。書き換えない出力でも、手順の行のあとに続きの行が順に並ぶ。
# 手順が止まると、✖ の行に扱っていた名前が灰で付き、たまった通知を出してから止まる。
cat >"$test_dir/relay.sh" <<'SH'
source "$1/lib/ui.sh"
ui_init
ui_steps_begin err 2 "手順 一" "手順 二" "手順 三"
ui_steps_notice_file=$(mktemp "$1/tmp/${2}/notice.XXXXXX")
trap ui_steps_cleanup EXIT
ui_phase_start 1
( ui_notice add "子の通知" "値 1"; ( ui_notice warn "孫の通知" ) )
ui_phase_progress 1 2 "名前甲"
ui_phase_done "5  3s"
ui_phase_start 2
ui_phase_progress 0 3 "名前乙"
( ui_notice - "止まる前の通知" )
die() { ui_phase_fail; ui_error "$*"; exit 1; }
die "止まりました"
SH
rc=0
bash "$test_dir/relay.sh" "$root" "${test_dir##*/}" >"$test_dir/out" 2>"$test_dir/err" || rc=$?
[[ $rc == 1 && ! -s $test_dir/out ]]
printf '  ✔ 手順 一  5  3s\n      + 子の通知  値 1\n      ! 孫の通知\n  ✖ 手順 二  名前乙\n      止まる前の通知\nエラー: 止まりました\n' >"$test_dir/expected"
cmp "$test_dir/err" "$test_dir/expected"
[[ -z $(ls "$test_dir" | grep -e '^notice\.' || true) ]] || { ls "$test_dir"; exit 1; }
echo 'PASS setup-progress: 子と孫の通知は親が手順の下へ順に出し、止まると ✖ に名前を添えて、同じエラーと終了コードで止まる'

# 手順が動いていないときの ui_phase_fail は何も出さない（一覧の外で die が呼ばれても、行を増やさない）。
cat >"$test_dir/idle-fail.sh" <<'SH'
source "$1/lib/ui.sh"
ui_init
ui_steps_begin err 2 "手順 一" "手順 二"
ui_phase_fail
ui_phase_start 1
ui_phase_done
ui_phase_fail
echo idle-ok
SH
bash "$test_dir/idle-fail.sh" "$root" >"$test_dir/out" 2>"$test_dir/err"
[[ $(cat "$test_dir/out") == idle-ok ]]
[[ $(cat "$test_dir/err") == '  ✔ 手順 一' ]]
echo 'PASS setup-progress: 動いている手順がないときの失敗は何も出さない'

# サブシェルの中の die と、それを受けた親の die が続いても、✖ の行は 1 度だけ出る。
cat >"$test_dir/nested-die.sh" <<'SH'
source "$1/lib/ui.sh"
ui_init
ui_steps_begin err 2 "手順 一" "手順 二"
ui_steps_notice_file=$(mktemp "$1/tmp/${2}/notice.XXXXXX")
trap ui_steps_cleanup EXIT
die() { ui_phase_fail; ui_error "$*"; exit 1; }
ui_phase_start 1
ui_phase_progress 0 1 "名前甲"
( die "子が止まりました" ) || die "親も止まりました"
SH
rc=0
bash "$test_dir/nested-die.sh" "$root" "${test_dir##*/}" >"$test_dir/out" 2>"$test_dir/err" || rc=$?
[[ $rc == 1 && $(grep -c '✖' "$test_dir/err") == 1 ]]
grep -qF 'エラー: 子が止まりました' "$test_dir/err"
grep -qF 'エラー: 親も止まりました' "$test_dir/err"
[[ -z $(ls "$test_dir" | grep -e '^notice\.' || true) ]] || { ls "$test_dir"; exit 1; }
echo 'PASS setup-progress: 子と親の die が続いても ✖ は 1 度だけ出る'

# 端末では、○ の一覧がスピナーを経て ✔ に変わり、サブシェルの通知は手順の下に出て、描く裏のプロセスも無い。
cat >"$test_dir/live.sh" <<'SH'
source "$1/lib/ui.sh"
ui_init
ui_steps_begin err 2 "手順 一" "手順 二" "手順 三"
ui_steps_notice_file=$(mktemp "$1/tmp/${2}/notice.XXXXXX")
trap ui_steps_cleanup EXIT
ui_phase_start 1
ui_step_tick
ui_step_tick
ui_phase_done "値 一"
ui_phase_start 2
ui_phase_progress 0 2 "名前乙"
(
	ui_step_tick
	ui_notice add "子の通知" "値"
)
ui_phase_progress 2 2 "名前乙"
ui_phase_done_counted 2
printf 'jobs=[%s]\n' "$(jobs -p | tr -d '\n')"
SH
env -i PATH="$PATH" HOME="$test_dir" TERM=xterm-256color python3 "$root/tests/ui-pty.py" err "$test_dir/out" "$test_dir/err" -- bash "$test_dir/live.sh" "$root" "${test_dir##*/}"
python3 "$root/tests/ansi-to-png.py" "$test_dir/err" --text >"$test_dir/screen"
grep -qE '^  ✔ 手順 一  値 一$' "$test_dir/screen"
grep -qE '^  ✔ 手順 二  2  [0-9]+s$' "$test_dir/screen"
grep -qF '      + 子の通知  値' "$test_dir/screen"
grep -qE '^  ○ 手順 三$' "$test_dir/screen"
python3 - "$test_dir/err" <<'PY'
from pathlib import Path
import sys
data = Path(sys.argv[1]).read_bytes().decode()
esc = '\x1b'
assert any(f in data for f in '⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'), 'スピナーが出ていない'
assert f'{esc}[38;5;28m✔{esc}[0m 手順 一' in data
PY
echo 'PASS setup-progress: 端末では ○ からスピナーを経て ✔ になり、サブシェルの通知は手順の下に出る'
