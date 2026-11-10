#!/usr/bin/env bash
# tests/*-test.sh（引数があればそのファイル）を並べて流し、結果をまとめて出す。
#
# 並べ方: 並列数は SQUAD_KIT_TEST_JOBS、なければ論理 CPU の数にし、正の整数で
# なければ 2 で終わる。macOS の bash 3.2 には wait -n がないので、xargs -P で
# 1 本ごとに tests/run-one.sh を起こす。run-one.sh は成否によらず 0 で終わり、
# 結果をファイルに書く。xargs が途中で起こすのをやめないようにするため。
# 下の slow の一覧のファイルを先に、残りを名前の順に起こす。遅いファイルが後に
# 回ると、全体がその分だけ延びるため。一覧のファイルがなければ 2 で終わる。
# 補助の run-one.sh と run-hook.sh は、テストとして拾われないよう -test.sh で
# 終えない。
#
# 分け方: 1 回の実行で tmp/test-run.XXXXXX/ を作り、ファイルごとに空の HOME と
# TMPDIR を渡す。既定の置き場所に書くテストどうしが取り合わず、開発者の本物の
# 設定も書き換えないため。python3 だけは、本物の HOME で実体を引いてから渡す。置き場所を指定しない mktemp と mktemp -t は、macOS では
# TMPDIR を見ないことがあり、ここでは分けられない。テストの側で置き場所を明示する
# （CONTRIBUTING.md の「テストを書く決まり」）。1 本ずつ流すときも同じに分ける。
#
# 失敗の出し方: テストの出力はファイルごとのログに書き、終わるたびに done の
# 1 行だけを出す。すべて終わったら、通ったファイルのログを名前の順に出し、
# 失敗したファイルのログを最後に出す。CI のログでは、最後が最初に読まれるため。
# 失敗したファイルには、失敗した場所と直前に通ったケース（最後の PASS の行）を
# 添え、GITHUB_ACTIONS が true なら ::error の注釈も出す。失敗した場所は、
# BASH_ENV で読ませる tests/run-hook.sh が、テストの最上位のシェルで最初に
# 起きた、errexit が有効なときの ERR を書く。
#
# 結果の欠落: 結果の記録がないファイルは、起こせなかったか途中で止まったものと
# して失敗に数える。割り込まれたら、起こしたテストを止めて 0 以外で終わる。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

if [[ ${SQUAD_KIT_TEST_JOBS+x} ]]; then
	jobs=$SQUAD_KIT_TEST_JOBS
else
	jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null) || jobs=1
	if [[ ! $jobs =~ ^[0-9]+$ || ! $jobs =~ [1-9] ]]; then jobs=1; fi
fi
if [[ ! $jobs =~ ^[0-9]+$ || ! $jobs =~ [1-9] ]]; then
	echo 'SQUAD_KIT_TEST_JOBS は正の整数にしてください' >&2
	exit 2
fi
while [[ $jobs == 0* ]]; do jobs=${jobs#0}; done
slow=(tests/project-test.sh tests/project-followup-test.sh tests/squad-dispatch-pick-test.sh tests/squad-dependabot-merge-test.sh)
for test in "${slow[@]}"; do
	if [[ ! -f $test ]]; then
		printf '起こす順の一覧にあるファイルがありません: %s\n' "$test" >&2
		exit 2
	fi
done
if [[ $# == 0 ]]; then set -- tests/*-test.sh; fi
selected=("$@")
for test in "${selected[@]}"; do
	if [[ ! -f $test ]]; then
		printf 'テストのファイルがありません: %s\n' "$test" >&2
		exit 2
	fi
done
mkdir -p "$root/tmp"
run_dir=$(mktemp -d "$root/tmp/test-run.XXXXXX")
# 版を管理する道具（asdf・pyenv・mise など）の python3 は、HOME の設定から版を決める shim のことがある。
# 空の HOME ではその shim が版を決められないので、本物の HOME で実体を引き、PATH の先頭から呼ばせる。
if real_python=$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null) && [[ -n $real_python && -x $real_python ]]; then
	mkdir -p "$run_dir/bin"
	# スクリプトで包むと、#! に python3 のパスを書くテストのスタブが動かないので、実体へのリンクにする。
	ln -s "$real_python" "$run_dir/bin/python3"
	export PATH="$run_dir/bin:$PATH"
fi
worker_pid=
cleanup() {
	if [[ -n $worker_pid ]]; then
		# 専用のグループにいる xargs と、その子として起こしたテストを止める。
		kill -TERM -- "-$worker_pid" 2>/dev/null || :
		kill -KILL -- "-$worker_pid" 2>/dev/null || :
		wait "$worker_pid" 2>/dev/null || :
	fi
	rm -rf -- "$run_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if ! printf '%s\0' "${selected[@]}" | LC_ALL=C sort -z >"$run_dir/selected"; then
	echo '起こす順の並べ替えに失敗しました' >&2
	exit 1
fi
ordered=()
for priority in "${slow[@]}"; do
	for test in "${selected[@]}"; do
		if [[ $test == "$priority" ]]; then ordered+=("$test"); fi
	done
done
while IFS= read -r -d '' test; do
	is_slow=no
	for priority in "${slow[@]}"; do
		if [[ $test == "$priority" ]]; then is_slow=yes; break; fi
	done
	if [[ $is_slow == no ]]; then ordered+=("$test"); fi
done <"$run_dir/selected"
for ((i=0; i<${#ordered[@]}; i++)); do
	mkdir -p "$run_dir/$i/home" "$run_dir/$i/tmp"
	printf '%s\0%s\0' "$i" "${ordered[$i]}" >>"$run_dir/queue"
done
# bash 3.2 でも使える xargs。割り込み時に子も止められる専用のグループで起こす。
set -m
xargs -0 -n 2 -P "$jobs" bash "$root/tests/run-one.sh" "$root" "$run_dir" <"$run_dir/queue" &
worker_pid=$!
set +m
launch_status=0
wait "$worker_pid" || launch_status=$?
worker_pid=
if [[ $launch_status != 0 ]]; then printf 'テストを起こす処理が失敗しました（終了コード %s）\n' "$launch_status" >&2; fi

annotation_escape() {
	local value=$1
	value=${value//%/%25}
	value=${value//$'\r'/%0D}
	value=${value//$'\n'/%0A}
	value=${value//:/%3A}
	value=${value//,/%2C}
	printf '%s' "$value"
}
failed=()
# 表示用の並べ替えが失敗しても、起こした全ファイルの結果を確認する。
report_order=()
sort_status=0
if printf '%s\0' "${selected[@]}" | LC_ALL=C sort -zu >"$run_dir/report-order"; then
	while IFS= read -r -d '' test; do
		for ((i=0; i<${#ordered[@]}; i++)); do
			if [[ ${ordered[$i]} == "$test" ]]; then report_order+=("$i"); fi
		done
	done <"$run_dir/report-order"
else
	echo '結果の並べ替えに失敗しました。起こした順で結果を確認します' >&2
	sort_status=1
	for ((i=0; i<${#ordered[@]}; i++)); do report_order+=("$i"); done
fi
# 成功を名前順に出してから、失敗を名前順に出す。
for outcome in PASS FAIL; do
	for i in "${report_order[@]}"; do
		test=${ordered[$i]}
		status=missing elapsed=0
		if [[ -f $run_dir/$i/result ]]; then read -r status elapsed <"$run_dir/$i/result" || status=missing; fi
		actual=FAIL
		if [[ $status == 0 ]]; then actual=PASS; fi
		[[ $actual == "$outcome" ]] || continue
		if [[ $actual == PASS ]]; then
			printf '==== PASS %s（%s 秒）\n' "$test" "$elapsed"
		else
			failed+=("$test")
			printf '==== FAIL %s（終了コード %s、%s 秒）\n' "$test" "$status" "$elapsed"
		fi
		if [[ -f $run_dir/$i/log ]]; then cat "$run_dir/$i/log"; fi
		if [[ $actual == FAIL ]]; then
			file=$test line=1 command='失敗した場所の記録なし'
			if [[ -s $run_dir/$i/error ]]; then
				{ IFS= read -r file; IFS= read -r line; IFS= read -r command; } <"$run_dir/$i/error"
				printf '失敗した場所: %s:%s: %s\n' "$file" "$line" "$command"
				sed '1,3d' "$run_dir/$i/error"
			else
				printf '失敗した場所: %s（記録なし）\n' "$test"
			fi
			previous=$(awk '/^PASS / {last=$0} END {print last}' "$run_dir/$i/log" 2>/dev/null || :)
			printf '直前に通ったケース: %s\n' "${previous:-なし}"
			if [[ $status == missing ]]; then echo '結果の記録なし: 起こせなかったか途中で止まりました'; fi
			if [[ ${GITHUB_ACTIONS:-} == true ]]; then
				printf '::error file=%s,line=%s::%s\n' "$(annotation_escape "$file")" "$line" "$(annotation_escape "$test: $command / 直前に通ったケース: ${previous:-なし}")"
			fi
		fi
	done
done
if [[ ${#failed[@]} != 0 || $launch_status != 0 || $sort_status != 0 ]]; then
	printf 'FAIL suite: %s 本が失敗:' "${#failed[@]}"
	if [[ ${#failed[@]} != 0 ]]; then printf ' %s' "${failed[@]}"; fi
	printf '\n'
	exit 1
fi
printf 'PASS suite: すべてのテスト（%s 本、並列 %s）\n' "${#ordered[@]}" "$jobs"
