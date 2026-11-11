#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/test-runner.XXXXXX")
# 標準エラーを err に向けたまま止まっても、trap が err 自身へ書き足し続けないよう、元の標準エラーを控えて出す。
exec 8>&2
trap 'test_exit=$?; if [[ $test_exit != 0 ]]; then cat "$test_dir/out" "$test_dir/err" >&8; fi; rm -rf -- "$test_dir"' EXIT
# 小さな原本のコピーを使い、本物のテストの再帰実行や一覧の書き換えを避ける。
kit="$test_dir/kit"
fixtures="$test_dir/fixtures with spaces"
mkdir -p "$kit/tests" "$fixtures"
cp "$root/tests/run.sh" "$root/tests/run-one.sh" "$root/tests/run-hook.sh" "$root/tests/stop-session.py" "$kit/tests/"
for name in project project-followup squad-dispatch-pick squad-dependabot-merge; do
	printf ':\n' >"$kit/tests/$name-test.sh"
done
printf '# 小さな原本の重み\ntests/project-test.sh 10\n\ntests/squad-dependabot-merge-test.sh 40\n' >"$kit/tests/test-weights"
export TEST_RUNNER_KIT="$kit" TEST_RUNNER_STATE="$test_dir/state"
# CI のシャードの指定が、ここで流す小さな走らせ役へ漏れないようにする（シャードの指定は各ケースで渡す）。
unset SQUAD_KIT_TEST_SHARD
cat >"$fixtures/a.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
name=$(basename "$0" .sh)
[[ $PWD == "$TEST_RUNNER_KIT" ]]
[[ -z $(ls -A "$HOME") && -z $(ls -A "$TMPDIR") ]]
[[ ! ${BASH_ENV+x} && ! ${SQUAD_KIT_TEST_ERROR_FILE+x} ]]
bash -c '[[ ! ${BASH_ENV+x} && ! ${SQUAD_KIT_TEST_ERROR_FILE+x} ]]'
printf '%s\n%s\n' "$HOME" "$TMPDIR" >"$TEST_RUNNER_STATE/$name.env"
touch "$HOME/marker"
mktemp "$TMPDIR/probe.XXXXXX" >/dev/null
touch "$TEST_RUNNER_STATE/$name.started"
if [[ $TEST_RUNNER_PARALLEL == yes ]]; then
	for ((attempt=0; attempt<500; attempt++)); do
		if [[ -e $TEST_RUNNER_STATE/a.started && -e $TEST_RUNNER_STATE/b.started ]]; then break; fi
		sleep 0.02
	done
	[[ -e $TEST_RUNNER_STATE/a.started && -e $TEST_RUNNER_STATE/b.started ]]
elif [[ $name == a ]]; then
	[[ ! -e $TEST_RUNNER_STATE/b.started ]]
else
	[[ -e $TEST_RUNNER_STATE/a.finished ]]
fi
touch "$TEST_RUNNER_STATE/$name.finished"
echo "PASS fixture: $name"
FIXTURE
cp "$fixtures/a.sh" "$fixtures/b.sh"
run_suite() {
	local expected=$1 jobs=$2 result=0
	shift 2
	SQUAD_KIT_TEST_JOBS="$jobs" bash "$kit/tests/run.sh" "$@" >"$test_dir/out" 2>"$test_dir/err" || result=$?
	[[ $result == "$expected" ]]
	# 成功・失敗にかかわらず、走らせ役の一時ディレクトリが残らない。
	[[ -z $(find "$kit/tmp" -name 'test-run.*' -type d -print 2>/dev/null) ]]
}
for mode in parallel serial; do
	rm -rf -- "$TEST_RUNNER_STATE"
	mkdir -p "$TEST_RUNNER_STATE"
	if [[ $mode == parallel ]]; then jobs=2; export TEST_RUNNER_PARALLEL=yes
	else jobs=1; export TEST_RUNNER_PARALLEL=no; fi
	run_suite 0 "$jobs" "$fixtures/b.sh" "$fixtures/a.sh"
	grep -qxF "PASS suite: すべてのテスト（2 本、並列 ${jobs}）" "$test_dir/out"
	grep -qxF 'PASS fixture: a' "$test_dir/out"
	grep -qxF 'PASS fixture: b' "$test_dir/out"
	[[ $(sed -n '1p' "$TEST_RUNNER_STATE/a.env") != "$(sed -n '1p' "$TEST_RUNNER_STATE/b.env")" ]]
	[[ $(sed -n '2p' "$TEST_RUNNER_STATE/a.env") != "$(sed -n '2p' "$TEST_RUNNER_STATE/b.env")" ]]
	# ログは引数の順によらず名前順で、ケースの出力が混ざらない。
	[[ $(awk '/^==== PASS/ {print; getline; print}' "$test_dir/out" | grep '^PASS fixture:') == $'PASS fixture: a\nPASS fixture: b' ]]
	echo "PASS runner: $mode で外のファイルを流し、環境とログを分け、後片付けする"
done

# HOME の設定からバージョンを決める python3 の shim でも、空の HOME のテストから動く。
mkdir -p "$test_dir/shim" "$test_dir/real python" "$test_dir/real-home"
touch "$test_dir/real-home/.tool-versions"
# 走らせ役は python3 -c で新しいセッションやグループを作るので、実体を尋ねる -c と -I は、shim を通さない本物の python3 へ渡す。
TEST_RUNNER_SYSTEM_PYTHON=$(command -v python3)
export TEST_RUNNER_SYSTEM_PYTHON
cat >"$test_dir/real python/python3" <<'STUB'
#!/usr/bin/env bash
if [[ ${1:-} == -c && ${2:-} == 'import sys; print(sys.executable)' ]]; then printf '%s\n' "$0"
elif [[ ${1:-} == -c || ${1:-} == -I ]]; then exec "$TEST_RUNNER_SYSTEM_PYTHON" "$@"
else printf 'REAL %s\n' "$*"; fi
STUB
cat >"$test_dir/shim/python3" <<'STUB'
#!/usr/bin/env bash
[[ -e $HOME/.tool-versions ]] || { echo 'No version is set for python3' >&2; exit 126; }
exec "$TEST_RUNNER_REAL_PYTHON" "$@"
STUB
chmod +x "$test_dir/real python/python3" "$test_dir/shim/python3"
cat >"$fixtures/python.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
[[ $(python3 'with space') == 'REAL with space' ]]
echo 'PASS fixture: python'
FIXTURE
HOME="$test_dir/real-home" PATH="$test_dir/shim:$PATH" TEST_RUNNER_REAL_PYTHON="$test_dir/real python/python3" run_suite 0 1 "$fixtures/python.sh"
grep -qxF 'PASS fixture: python' "$test_dir/out"
echo 'PASS runner: HOME からバージョンを決める python3 の shim でも、本物の HOME で引いた実体を空の HOME のテストへ渡す'

cat >"$fixtures/fail.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
echo 'PASS fixture: before failure'
fail_case() { false; }
fail_case
FIXTURE
cat >"$fixtures/pass.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
echo 'PASS fixture: after failure'
FIXTURE
GITHUB_ACTIONS=true run_suite 1 1 "$fixtures/fail.sh" "$fixtures/pass.sh"
grep -qxF 'PASS fixture: after failure' "$test_dir/out"
grep -qxF "失敗した場所: $fixtures/fail.sh:4: false" "$test_dir/out"
grep -qxF "呼び出し: $fixtures/fail.sh:5: fail_case" "$test_dir/out"
grep -qxF '直前に通ったケース: PASS fixture: before failure' "$test_dir/out"
grep -qF "::error file=$fixtures/fail.sh,line=4::" "$test_dir/out"
[[ $(grep '^==== ' "$test_dir/out" | head -n 1) == "==== PASS $fixtures/pass.sh"* ]]
[[ $(grep '^==== ' "$test_dir/out" | tail -n 1) == "==== FAIL $fixtures/fail.sh"* ]]
grep -qxF "FAIL suite: 1 本が失敗: $fixtures/fail.sh" "$test_dir/out"
echo 'PASS runner: 失敗しても最後まで流し、失敗のログ・行・コマンド・呼び出し・ケース・注釈を出す'

cat >"$fixtures/expected-status.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
set +e
false # 想定内の失敗
status=$?
set -e
[[ $status == 1 ]]
echo 'PASS fixture: expected status checked'
actual_failure() { false; }
actual_failure
FIXTURE
GITHUB_ACTIONS=true run_suite 1 1 "$fixtures/expected-status.sh"
grep -qxF "失敗した場所: $fixtures/expected-status.sh:9: false" "$test_dir/out"
grep -qxF "呼び出し: $fixtures/expected-status.sh:10: actual_failure" "$test_dir/out"
grep -qxF '直前に通ったケース: PASS fixture: expected status checked' "$test_dir/out"
grep -qF "::error file=$fixtures/expected-status.sh,line=9::" "$test_dir/out"
echo 'PASS runner: 想定内の終了コードを確認した後の、本当の失敗の行と呼び出しを出す'

# 並べ替えが一部だけ出力して失敗しても、その一覧で成功扱いしない。
mkdir -p "$test_dir/bin"
export TEST_RUNNER_REAL_SORT
TEST_RUNNER_REAL_SORT=$(command -v sort)
cat >"$test_dir/bin/sort" <<'FIXTURE'
#!/usr/bin/env bash
if [[ $1 == "$TEST_RUNNER_FAIL_SORT" ]]; then
	printf '%s\0' "$TEST_RUNNER_SORT_PARTIAL"
	echo 'sort: simulated temporary-file error' >&2
	exit 1
fi
exec "$TEST_RUNNER_REAL_SORT" "$@"
FIXTURE
chmod +x "$test_dir/bin/sort"
TEST_RUNNER_SORT_PARTIAL="$fixtures/pass.sh" TEST_RUNNER_FAIL_SORT=-z PATH="$test_dir/bin:$PATH" \
	run_suite 1 1 tests/project-test.sh "$fixtures/fail.sh" "$fixtures/pass.sh"
grep -qxF '起こす順の並べ替えに失敗しました' "$test_dir/err"
[[ ! -s $test_dir/out ]]
echo 'PASS runner: 起こす順の並べ替えが失敗したら、テストを起こさず失敗する'

for fixture in fail pass; do
	TEST_RUNNER_SORT_PARTIAL="$fixtures/pass.sh" TEST_RUNNER_FAIL_SORT=-zu PATH="$test_dir/bin:$PATH" \
		run_suite 1 2 "$fixtures/$fixture.sh" "$fixtures/pass.sh"
	grep -qxF '結果の並べ替えに失敗しました。起こした順で結果を確認します' "$test_dir/err"
	grep -qxF 'PASS fixture: after failure' "$test_dir/out"
	if [[ $fixture == fail ]]; then
		grep -qxF "失敗した場所: $fixtures/fail.sh:4: false" "$test_dir/out"
		grep -qxF "FAIL suite: 1 本が失敗: $fixtures/fail.sh" "$test_dir/out"
	else
		grep -qxF 'FAIL suite: 0 本が失敗:' "$test_dir/out"
	fi
	! grep -q '^PASS suite:' "$test_dir/out"
done
echo 'PASS runner: 結果の並べ替えが失敗しても全ファイルを確認し、全体を失敗にする'

# 明示した exit は ERR の記録がなくても失敗になる。255 でも次を起こす。
printf 'exit 255\n' >"$fixtures/exit.sh"
run_suite 1 1 "$fixtures/exit.sh" "$fixtures/pass.sh"
grep -qF '終了コード 255' "$test_dir/out"
grep -qxF "失敗した場所: $fixtures/exit.sh（記録なし）" "$test_dir/out"
grep -qxF 'PASS fixture: after failure' "$test_dir/out"
echo 'PASS runner: ERR の記録がない exit 255 も失敗とし、次のファイルを流す'

# 起動に成功したように見えて結果がない場合を、コピー内の補助で再現する。
printf 'exit 0\n' >"$kit/tests/run-one.sh"
run_suite 1 2 "$fixtures/pass.sh"
grep -qxF '結果の記録なし: 起こせなかったか途中で止まりました' "$test_dir/out"
grep -qxF "FAIL suite: 1 本が失敗: $fixtures/pass.sh" "$test_dir/out"
cp "$root/tests/run-one.sh" "$kit/tests/run-one.sh"
echo 'PASS runner: 結果を残さないファイルを全体の失敗に数える'

for invalid in '' 0 -1 invalid 1.5; do
	run_suite 2 "$invalid" "$fixtures/pass.sh"
	grep -qF 'SQUAD_KIT_TEST_JOBS は正の整数にしてください' "$test_dir/err"
	[[ ! -s $test_dir/out ]]
done
echo 'PASS runner: 並列数が正の整数でなければテストを流さず 2 で終わる'

# 時間の上限。別のプロセスグループで子を起こして眠るファイルを、短い上限で止める。
cat >"$fixtures/sleeper.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
echo 'PASS fixture: before timeout'
python3 -c 'import os, sys; os.setpgrp(); os.execvp(sys.argv[1], sys.argv[1:])' sleep 60 &
printf '%s\n' "$!" >"$TEST_RUNNER_STATE/child.pid"
printf '%s\n' "$$" >"$TEST_RUNNER_STATE/test.pid"
sleep 60
FIXTURE
# TERM を無視するファイルは、5 秒の猶予のあと KILL で止める。
sed 's/^set -euo pipefail$/set -euo pipefail\ntrap "" TERM/' "$fixtures/sleeper.sh" >"$fixtures/stubborn.sh"
pid_gone() {
	local pid=$1 attempt
	for ((attempt=0; attempt<50; attempt++)); do
		kill -0 "$pid" 2>/dev/null || return 0
		sleep 0.1
	done
	return 1
}
for name in sleeper stubborn; do
	rm -rf -- "$TEST_RUNNER_STATE"
	mkdir -p "$TEST_RUNNER_STATE"
	SQUAD_KIT_TEST_TIMEOUT=2 GITHUB_ACTIONS=true run_suite 1 2 "$fixtures/$name.sh" "$fixtures/pass.sh"
	grep -qxF "done TIMEOUT $fixtures/$name.sh 2s" "$test_dir/out"
	grep -qxF "==== FAIL $fixtures/$name.sh（時間切れ: 2 秒で止めた）" "$test_dir/out"
	grep -qxF '直前に通ったケース: PASS fixture: before timeout' "$test_dir/out"
	grep -qF "::error file=$fixtures/$name.sh," "$test_dir/out"
	grep -qF "時間切れ%3A 2 秒で止めた" "$test_dir/out"
	grep -qxF "FAIL suite: 1 本が失敗: $fixtures/$name.sh" "$test_dir/out"
	grep -qxF 'PASS fixture: after failure' "$test_dir/out"
	# テストと、別のグループで起こした子の両方が、残っていない。
	pid_gone "$(cat "$TEST_RUNNER_STATE/test.pid")"
	pid_gone "$(cat "$TEST_RUNNER_STATE/child.pid")"
done
echo 'PASS runner: 上限を超えたファイルを、別のグループの子ごと止めて時間切れの失敗にし、ほかのファイルは流す'

# 上限の中で終わるファイルは、上限を設ける前と同じ結果と出力になる。
SQUAD_KIT_TEST_TIMEOUT=2 run_suite 0 1 "$fixtures/pass.sh"
grep -qE "^done PASS $fixtures/pass.sh [0-9]+s$" "$test_dir/out"
grep -qE "^==== PASS $fixtures/pass.sh（[0-9]+ 秒）$" "$test_dir/out"
! grep -qF '時間切れ' "$test_dir/out"
grep -qxF 'PASS suite: すべてのテスト（1 本、並列 1）' "$test_dir/out"
echo 'PASS runner: 上限の中で終わるファイルは、時間切れの表示なしで今までと同じ結果になる'

for invalid in '' 0 -1 invalid 1.5; do
	SQUAD_KIT_TEST_TIMEOUT="$invalid" run_suite 2 1 "$fixtures/pass.sh"
	grep -qF 'SQUAD_KIT_TEST_TIMEOUT は正の整数（秒）にしてください' "$test_dir/err"
	[[ ! -s $test_dir/out ]]
done
echo 'PASS runner: 上限が正の整数でなければテストを流さず 2 で終わる'

# 割り込まれたときも、別のセッションで動いているテストとその子を残さない。
rm -rf -- "$TEST_RUNNER_STATE"
mkdir -p "$TEST_RUNNER_STATE"
SQUAD_KIT_TEST_JOBS=1 bash "$kit/tests/run.sh" "$fixtures/sleeper.sh" >"$test_dir/out" 2>"$test_dir/err" &
suite_pid=$!
for ((attempt=0; attempt<200; attempt++)); do
	[[ -s $TEST_RUNNER_STATE/child.pid && -s $TEST_RUNNER_STATE/test.pid ]] && break
	sleep 0.1
done
[[ -s $TEST_RUNNER_STATE/child.pid && -s $TEST_RUNNER_STATE/test.pid ]]
kill -TERM "$suite_pid"
result=0
wait "$suite_pid" || result=$?
[[ $result == 143 ]]
pid_gone "$(cat "$TEST_RUNNER_STATE/test.pid")"
pid_gone "$(cat "$TEST_RUNNER_STATE/child.pid")"
[[ -z $(find "$kit/tmp" -name 'test-run.*' -type d -print 2>/dev/null) ]]
echo 'PASS runner: 割り込まれたら、動いているテストとその子もセッションごと止めて終わる'

# 起動の直後、セッションの ID を登録する前に割り込まれても、テストを残さない。
# run-one.sh の test_pid=$! の直前に止める補助を BASH_ENV で入れ、止まっている間に run.sh へ TERM を送る。
cat >"$fixtures/startup.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$$" >"$TEST_RUNNER_STATE/startup.pid"
sleep 60
FIXTURE
cat >"$fixtures/stall-hook.sh" <<'HOOK'
_stall() {
	if [[ $BASH_COMMAND == 'test_pid=$!' && -n ${TEST_RUNNER_STATE-} ]]; then
		touch "$TEST_RUNNER_STATE/stalled"
		sleep 5
	fi
}
trap _stall DEBUG
HOOK
rm -rf -- "$TEST_RUNNER_STATE"
mkdir -p "$TEST_RUNNER_STATE"
BASH_ENV="$fixtures/stall-hook.sh" SQUAD_KIT_TEST_JOBS=1 bash "$kit/tests/run.sh" "$fixtures/startup.sh" >"$test_dir/out" 2>"$test_dir/err" &
suite_pid=$!
for ((attempt=0; attempt<200; attempt++)); do
	[[ -e $TEST_RUNNER_STATE/stalled ]] && break
	sleep 0.1
done
[[ -e $TEST_RUNNER_STATE/stalled ]]
# 子が起きて、登録を待たずに新しいセッションへ移る作りなら、テストが動き出す時間を置く。
sleep 1.5
kill -TERM "$suite_pid"
result=0
wait "$suite_pid" || result=$?
[[ $result == 143 ]]
# 登録の前に割り込まれたので、テストは起きない。起きていたら、割り込みのあとに残る。
sleep 1
[[ ! -e $TEST_RUNNER_STATE/startup.pid ]]
[[ -z $(find "$kit/tmp" -name 'test-run.*' -type d -print 2>/dev/null) ]]
echo 'PASS runner: セッションの ID を登録する前に割り込まれても、テストを起こさず、何も残さない'

rm "$kit/tests/project-test.sh"
run_suite 2 1 "$fixtures/pass.sh"
grep -qxF '重みの一覧にあるファイルがありません: tests/project-test.sh' "$test_dir/err"
[[ ! -s $test_dir/out ]]
printf ':\n' >"$kit/tests/project-test.sh"
echo 'PASS runner: 重みの一覧が古ければテストを流さず 2 で終わる'

# 標準エラーを err に向けた中で止まったときも、失敗の後始末が err へ書き足し続けず、元の標準エラーへ出して終わる。
mkdir -p "$fixtures/trap/tests"
{ sed -n "1,/^trap 'test_exit=/p" "$root/tests/webhooks-test.sh"; cat <<'FIXTURE'
printf 'out of case\n' >"$test_dir/out"
{ echo 'error of case' >&2; false; } 2>"$test_dir/err"
FIXTURE
} >"$fixtures/trap/tests/trap-test.sh"
result=0
perl -e 'alarm 20; exec @ARGV' bash "$fixtures/trap/tests/trap-test.sh" >"$test_dir/trap-out" 2>"$test_dir/trap-err" || result=$?
[[ $result == 1 ]]
grep -qxF 'out of case' "$test_dir/trap-err"
grep -qxF 'error of case' "$test_dir/trap-err"
[[ -z $(find "$fixtures/trap/tmp" -mindepth 1 -print) ]]
# 失敗の後始末で out と err を出すテストは、どれも控えた標準エラーへ出す。
for file in "$root"/tests/*.sh; do
	grep -q "^trap 'test_exit=" "$file" || continue
	[[ $(grep -B1 "^trap 'test_exit=" "$file" | head -n 1) == 'exec 8>&2' ]]
	! grep "^trap 'test_exit=" "$file" | grep -qF '>&2'
done
echo 'PASS runner: 標準エラーを err に向けた中で止まっても、失敗の後始末は元の標準エラーへ出して終わる'

# 重みと分け方。重みの一覧と流す順は、小さな原本のコピーで確かめる。
rm -f "$kit"/tests/*-test.sh
printf '# 重み\ntests/a-test.sh 50\ntests/b-test.sh 40\ntests/c-test.sh 30\ntests/d-test.sh 20\n tests/e-test.sh   20 \n\n# 一覧にない f・g・h は 30 秒\n' >"$kit/tests/test-weights"
all_tests=(tests/a-test.sh tests/b-test.sh tests/c-test.sh tests/d-test.sh tests/e-test.sh tests/f-test.sh tests/g-test.sh tests/h-test.sh)
# 1 本ずつ流し、テストが起こされた順を記録する。
for name in a b c d e f g h; do
	printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s" >>"$TEST_RUNNER_ORDER"\necho "PASS fixture: %s"\n' "$name" "$name" >"$kit/tests/$name-test.sh"
done
export TEST_RUNNER_ORDER="$test_dir/order"
shard_suite() {
	local expected=$1 shard=$2 result=0
	shift 2
	: >"$TEST_RUNNER_ORDER"
	SQUAD_KIT_TEST_SHARD="$shard" SQUAD_KIT_TEST_JOBS=1 bash "$kit/tests/run.sh" "$@" >"$test_dir/out" 2>"$test_dir/err" || result=$?
	[[ $result == "$expected" ]]
}
# 重みの大きい順、同じ重みは名前の順に、1 本ずつ起こす。f・g・h は 30 秒の扱い。
SQUAD_KIT_TEST_JOBS=1 bash "$kit/tests/run.sh" >"$test_dir/out" 2>"$test_dir/err"
[[ $(tr '\n' ' ' <"$TEST_RUNNER_ORDER") == 'a b c f g h d e ' ]]
grep -qxF 'PASS suite: すべてのテスト（8 本、並列 1）' "$test_dir/out"
echo 'PASS runner: 重みの大きい順、同じ重みは名前の順に起こし、一覧にないファイルは 30 秒として扱う'

# どのシャードの分け方でも、各ファイルがちょうど 1 つのシャードに入り、合わせると選んだ全部になる。
for count in 1 2 3 4 5 6; do
	: >"$test_dir/union"
	for ((index=1; index<=count; index++)); do
		shard_suite 0 "$index/$count"
		ran=$(wc -l <"$TEST_RUNNER_ORDER" | tr -d ' ')
		grep -qxF "PASS suite: すべてのテスト（${ran} 本、並列 1、シャード ${index}/${count}）" "$test_dir/out"
		cat "$TEST_RUNNER_ORDER" >>"$test_dir/union"
		# シャードの中の起こす順も、重みの大きい順。
		shard_order=$(tr '\n' ' ' <"$TEST_RUNNER_ORDER")
		expected_order=$(for name in a b c f g h d e; do grep -qx "$name" "$TEST_RUNNER_ORDER" && printf '%s ' "$name"; done; true)
		[[ $shard_order == "$expected_order" ]]
	done
	[[ $(sort "$test_dir/union" | tr '\n' ' ') == 'a b c d e f g h ' ]]
done
echo 'PASS runner: N を 1〜6 にしたとき、各シャードのファイルが重ならず、合わせると選んだ全部になる'

# 分け方は重みの合計がいちばん小さいシャードへ入れる決まりで、同じ合計なら番号の小さいほうへ入れる。
shard_suite 0 1/3 "${all_tests[@]}"
[[ $(tr '\n' ' ' <"$TEST_RUNNER_ORDER") == 'a h ' ]]
shard_suite 0 2/3 "${all_tests[@]}"
[[ $(tr '\n' ' ' <"$TEST_RUNNER_ORDER") == 'b g e ' ]]
shard_suite 0 3/3 "${all_tests[@]}"
[[ $(tr '\n' ' ' <"$TEST_RUNNER_ORDER") == 'c f d ' ]]
echo 'PASS runner: 重みの大きい順に、合計がいちばん小さい（同じなら番号の小さい）シャードへ入れる'

# 引数でファイルを選んだときは、選んだファイルを分ける。
shard_suite 0 2/2 tests/c-test.sh tests/a-test.sh tests/b-test.sh
[[ $(tr '\n' ' ' <"$TEST_RUNNER_ORDER") == 'b c ' ]]
shard_suite 0 1/2 tests/c-test.sh tests/a-test.sh tests/b-test.sh
[[ $(tr '\n' ' ' <"$TEST_RUNNER_ORDER") == 'a ' ]]
echo 'PASS runner: 引数でファイルを選んだときは、選んだファイルを分ける'

# 流すファイルがないシャードは、0 本と書いて 0 で終わる。
shard_suite 0 3/3 tests/a-test.sh
[[ ! -s $TEST_RUNNER_ORDER ]]
grep -qxF 'PASS suite: すべてのテスト（0 本、並列 1、シャード 3/3）' "$test_dir/out"
echo 'PASS runner: 流すファイルがないシャードは 0 本と書いて 0 で終わる'

# 指定が正しくなければ、テストを流さず 2 で終わる。
for invalid in '' 0 0/2 3/2 1/0 1 2/ /2 a/b 1/2/3 -1/2 1.5/2 ' 1/2' '1/2 ' 1234567/1234568; do
	shard_suite 2 "$invalid"
	grep -qF 'SQUAD_KIT_TEST_SHARD は k/N の形' "$test_dir/err"
	[[ ! -s $test_dir/out && ! -s $TEST_RUNNER_ORDER ]]
done
echo 'PASS runner: シャードの指定が k/N（1 ≦ k ≦ N の正の整数）でなければテストを流さず 2 で終わる'

# 重みの一覧の誤りは、テストを流さず 2 で終わる。
for bad in 'tests/a-test.sh' 'tests/a-test.sh abc' 'tests/a-test.sh -5' 'tests/a-test.sh 1.5' 'tests/a-test.sh 1 2' 'tests/a-test.sh 1234567890' $'tests/a-test.sh 5\ntests/a-test.sh 6'; do
	printf '%b\n' "$bad" >"$kit/tests/test-weights"
	run_suite 2 1 tests/a-test.sh
	grep -qE '重みの一覧(の行が正しくありません|に同じファイルが 2 回あります)' "$test_dir/err"
	[[ ! -s $test_dir/out ]]
done
rm "$kit/tests/test-weights"
run_suite 2 1 tests/a-test.sh
grep -qxF '重みの一覧がありません: tests/test-weights' "$test_dir/err"
echo 'PASS runner: 重みの一覧がないか書き方が正しくなければ、テストを流さず 2 で終わる'

# 本物の重みの一覧は、すべてのテストに重みがあり、存在しないファイルがない。
weighted=$(grep -vE '^[[:space:]]*(#|$)' "$root/tests/test-weights" | awk '{print $1}' | LC_ALL=C sort)
[[ -z $(printf '%s\n' "$weighted" | uniq -d) ]]
actual=$(cd "$root" && ls tests/*-test.sh | LC_ALL=C sort)
if [[ $weighted != "$actual" ]]; then
	diff <(printf '%s\n' "$weighted") <(printf '%s\n' "$actual") >&2 || :
	echo 'tests/test-weights が tests/*-test.sh と一致しません（重みのないファイルは追記し、なくなったファイルは消す）' >&2
	false
fi
while read -r name seconds extra; do
	case $name in ''|'#'*) continue ;; esac
	[[ -f $root/$name && -z $extra && $seconds =~ ^[0-9]+$ ]]
done <"$root/tests/test-weights"
echo 'PASS runner: 重みの一覧の名前が tests/*-test.sh と一致し、重複や存在しないファイルがない'
