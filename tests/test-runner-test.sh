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
cp "$root/tests/run.sh" "$root/tests/run-one.sh" "$root/tests/run-hook.sh" "$kit/tests/"
for name in project project-followup squad-dispatch-pick squad-dependabot-merge; do
	printf ':\n' >"$kit/tests/$name-test.sh"
done
export TEST_RUNNER_KIT="$kit" TEST_RUNNER_STATE="$test_dir/state"
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

rm "$kit/tests/project-test.sh"
run_suite 2 1 "$fixtures/pass.sh"
grep -qxF '起こす順の一覧にあるファイルがありません: tests/project-test.sh' "$test_dir/err"
[[ ! -s $test_dir/out ]]
echo 'PASS runner: 起こす順の一覧が古ければテストを流さず 2 で終わる'

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
