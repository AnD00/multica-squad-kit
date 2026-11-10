#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/preflight.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
mkdir -p "$test_dir/guard bin" "$test_dir/tools" "$test_dir/other"
guard_bin="$test_dir/guard bin"
cp "$root/common/monitor/squad-preflight" "$guard_bin/squad-preflight"
chmod +x "$guard_bin/squad-preflight"
# PATH を閉じ、ホストの gh や見張りへ抜けないようにする。
for cmd in bash dirname; do
	ln -s "$(command -v "$cmd")" "$test_dir/tools/$cmd"
done
cat >"$test_dir/stub" <<'STUB'
#!/bin/bash
echo called >>"$PREFLIGHT_TEST_CALLED"
exit 99
STUB
export PREFLIGHT_TEST_CALLED="$test_dir/called"
monitors=()
for file in "$root/common/monitor/"squad-*; do
	cmd=${file##*/}
	[[ $cmd != squad-preflight ]] || continue
	monitors+=("$cmd")
done
for cmd in gh "${monitors[@]}"; do
	cp "$test_dir/stub" "$guard_bin/$cmd"
	chmod +x "$guard_bin/$cmd"
done

run_preflight() {
	local expected=$1 test_path=$2 status=0
	BASH_ENV= PATH="$test_path" /bin/bash -c 'squad-preflight' \
		>"$test_dir/out" 2>"$test_dir/err" || status=$?
	if [[ $status != "$expected" ]]; then
		cat "$test_dir/out" "$test_dir/err" >&2
		echo "FAIL preflight: status=$status (expected $expected)" >&2
		exit 1
	fi
	[[ ! -e $PREFLIGHT_TEST_CALLED ]]
}
assert_failure() {
	local cmd=$1 actual=$2
	[[ ! -s $test_dir/out ]]
	grep -Fq "squad-preflight: $cmd が使えません。実際の解決先: ${actual}（期待: $guard_bin/${cmd}）" "$test_dir/err"
	grep -q '動いているタスクがないときに、同じプロジェクトでセットアップを流し直' "$test_dir/err"
}

run_preflight 0 "$guard_bin:$test_dir/tools"
[[ $(wc -l <"$test_dir/out") -eq 1 && ! -s $test_dir/err ]]
grep -q 'すべての見張りが使えます' "$test_dir/out"
echo 'PASS preflight: 正常時は 1 行を出して 0、コマンド自体は実行しない'

cp "$test_dir/stub" "$test_dir/other/gh"
chmod +x "$test_dir/other/gh"
run_preflight 1 "$test_dir/other:$guard_bin:$test_dir/tools"
assert_failure gh "$test_dir/other/gh"
grep -q 'CLAUDE_ENV_FILE（Claude）か custom_args（Codex）' "$test_dir/err"
echo 'PASS preflight: 別の gh が先にあると、解決先とランタイムの直し方を出す'

mv "$guard_bin/gh" "$test_dir/gh.saved"
run_preflight 1 "$guard_bin:$test_dir/tools"
assert_failure gh 見つからない
mv "$test_dir/gh.saved" "$guard_bin/gh"
echo 'PASS preflight: gh の欠落を報告する'

for cmd in "${monitors[@]}"; do
	mv "$guard_bin/$cmd" "$test_dir/monitor.saved"
	run_preflight 1 "$guard_bin:$test_dir/tools"
	assert_failure "$cmd" 見つからない
	grep -q '見張りを置き直してください' "$test_dir/err"
	[[ $(grep -c 'が使えません' "$test_dir/err") == 1 ]]
	mv "$test_dir/monitor.saved" "$guard_bin/$cmd"
done
echo 'PASS preflight: 配布する見張りをそれぞれ欠落させ、確認の一覧の書き忘れを検出する'

cp "$test_dir/stub" "$test_dir/other/squad-pr-watch"
chmod +x "$test_dir/other/squad-pr-watch"
run_preflight 1 "$test_dir/other:$guard_bin:$test_dir/tools"
assert_failure squad-pr-watch "$test_dir/other/squad-pr-watch"
assert_failure gh "$test_dir/other/gh"
[[ $(grep -c 'が使えません' "$test_dir/err") == 2 ]]
echo 'PASS preflight: 別の見張りが先にある場合と、複数の不一致をまとめて報告する'

# すべて外した結果と配布元を照合し、余分な確認対象も検出する。
for cmd in gh "${monitors[@]}"; do mv "$guard_bin/$cmd" "$test_dir/$cmd.saved"; done
run_preflight 1 "$guard_bin:$test_dir/tools"
for cmd in gh "${monitors[@]}"; do assert_failure "$cmd" 見つからない; done
[[ $(grep -c 'が使えません' "$test_dir/err") == $((${#monitors[@]} + 1)) ]]
echo 'PASS preflight: 確認する一覧が配布する全見張りと一致する'

run_preflight 127 "$test_dir/tools"
echo 'PASS preflight: PATH に関所のディレクトリがなければ、名前での呼び出しが 127 で失敗する'
