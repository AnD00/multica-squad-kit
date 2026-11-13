#!/usr/bin/env bash
# tests/*-test.sh（引数があればそのファイル）を並べて流し、結果をまとめて出す。
#
# 並べ方: 並列数は SQUAD_KIT_TEST_JOBS、なければ論理 CPU の数にし、正の整数で
# なければ 2 で終わる。macOS の bash 3.2 には wait -n がないので、xargs -P で
# 1 本ごとに tests/run-one.sh を起こす。run-one.sh は成否によらず 0 で終わり、
# 結果をファイルに書く。xargs が途中で起こすのをやめないようにするため。
# 重みの大きい順（同じ重みは名前の順）に起こす。遅いファイルが後に回ると、全体が
# その分だけ延びるため。重みは tests/test-weights に 1 行 1 ファイルで書く（名前と
# macOS の CI での秒数を空白で区切る。# で始まる行と空の行は読み飛ばす）。一覧に
# ないファイルは 30 秒として扱い、一覧にあるファイルがなければ 2 で終わる。
# 補助の run-one.sh と run-hook.sh は、テストとして拾われないよう -test.sh で
# 終えない。
#
# 時間の上限: テスト 1 本ごとに SQUAD_KIT_TEST_TIMEOUT 秒（なければ 450 秒。正の整数で
# なければ 2 で終わる）の上限を設ける。上限を超えたファイルは、run-one.sh がテストの
# セッションごと止め、時間切れの失敗として出す。手元でも CI でも同じ上限が効く。
#
# シャード: SQUAD_KIT_TEST_SHARD=k/N（1 ≦ k ≦ N の正の整数）なら、選んだファイルを
# N 個に分け、k 番目だけを流す。重みの大きい順に、それまでの重みの合計がいちばん
# 小さいシャード（同じなら番号の小さいほう）へ入れるので、同じ一覧からは毎回同じ分け
# 方になり、全シャードを合わせると指定のないときと同じファイルを流す。流すファイル
# がないシャードは、0 本として 0 で終わる。指定がなければすべてを流す。
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
shard=
shard_index=1 shard_count=1
if [[ ${SQUAD_KIT_TEST_SHARD+x} ]]; then
	shard=$SQUAD_KIT_TEST_SHARD
	if [[ ! $shard =~ ^([0-9]{1,6})/([0-9]{1,6})$ ]]; then
		echo 'SQUAD_KIT_TEST_SHARD は k/N の形（1 ≦ k ≦ N の正の整数、例: 2/4）にしてください' >&2
		exit 2
	fi
	shard_index=$((10#${BASH_REMATCH[1]})) shard_count=$((10#${BASH_REMATCH[2]}))
	if ((shard_index < 1 || shard_index > shard_count)); then
		echo 'SQUAD_KIT_TEST_SHARD は k/N の形（1 ≦ k ≦ N の正の整数、例: 2/4）にしてください' >&2
		exit 2
	fi
fi
if [[ ${SQUAD_KIT_TEST_TIMEOUT+x} ]]; then
	timeout_seconds=$SQUAD_KIT_TEST_TIMEOUT
else
	timeout_seconds=450
fi
if [[ ! $timeout_seconds =~ ^[0-9]+$ || ! $timeout_seconds =~ [1-9] ]]; then
	echo 'SQUAD_KIT_TEST_TIMEOUT は正の整数（秒）にしてください' >&2
	exit 2
fi
while [[ $timeout_seconds == 0* ]]; do timeout_seconds=${timeout_seconds#0}; done
export SQUAD_KIT_TEST_TIMEOUT=$timeout_seconds
default_weight=30
weights_file=tests/test-weights
if [[ ! -f $weights_file ]]; then
	printf '重みの一覧がありません: %s\n' "$weights_file" >&2
	exit 2
fi
weight_names=() weight_values=()
while IFS= read -r line || [[ -n $line ]]; do
	if [[ $line =~ ^[[:space:]]*(#|$) ]]; then continue; fi
	read -r name seconds extra <<<"$line"
	if [[ -n $extra || ! $seconds =~ ^[0-9]{1,9}$ ]]; then
		printf '重みの一覧の行が正しくありません（名前と秒を空白で区切る）: %s\n' "$line" >&2
		exit 2
	fi
	for existing in ${weight_names[@]+"${weight_names[@]}"}; do
		if [[ $existing == "$name" ]]; then
			printf '重みの一覧に同じファイルが 2 回あります: %s\n' "$name" >&2
			exit 2
		fi
	done
	if [[ ! -f $name ]]; then
		printf '重みの一覧にあるファイルがありません: %s\n' "$name" >&2
		exit 2
	fi
	weight_names+=("$name") weight_values+=("$((10#$seconds))")
done <"$weights_file"
weight_of() {
	local i
	for ((i=0; i<${#weight_names[@]}; i++)); do
		if [[ ${weight_names[$i]} == "$1" ]]; then printf '%s' "${weight_values[$i]}"; return; fi
	done
	printf '%s' "$default_weight"
}
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
# バージョンを管理する道具（asdf・pyenv・mise など）の python3 は、HOME の設定からバージョンを決める shim のことがある。
# 空の HOME ではその shim がバージョンを決められないので、本物の HOME で実体を引き、PATH の先頭から呼ばせる。
if real_python=$(python3 -c 'import sys; print(sys.executable)' 2>/dev/null) && [[ -n $real_python && -x $real_python ]]; then
	mkdir -p "$run_dir/bin"
	# スクリプトで包むと、#! に python3 のパスを書くテストのスタブが動かないので、実体へのリンクにする。
	ln -s "$real_python" "$run_dir/bin/python3"
	export PATH="$run_dir/bin:$PATH"
fi
worker_pid=
cleanup() {
	if [[ -n $worker_pid ]]; then
		# 専用のグループにいる xargs と run-one.sh を止める。グループを作る前なら、プロセスに直接送る。
		kill -TERM -- "-$worker_pid" 2>/dev/null || kill -TERM -- "$worker_pid" 2>/dev/null || :
		kill -KILL -- "-$worker_pid" 2>/dev/null || kill -KILL -- "$worker_pid" 2>/dev/null || :
		wait "$worker_pid" 2>/dev/null || :
	fi
	# テストは run-one.sh が別のセッションで起こしたので、動いているものをセッションごと止める。
	for session_file in "$run_dir"/*/session; do
		[[ -f $session_file ]] || continue
		read -r session <"$session_file" || continue
		[[ $session =~ ^[0-9]+$ ]] && { python3 -I "$root/tests/stop-session.py" "$session" KILL 2>/dev/null || :; }
	done
	rm -rf -- "$run_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# 重みの大きい順、同じ重みは名前の順に並べる。鍵は「999999999 - 重み」を 9 桁にした数と名前。
for test in "${selected[@]}"; do
	printf '%09d\t%s\0' "$((999999999 - $(weight_of "$test")))" "$test"
done >"$run_dir/keyed"
if ! LC_ALL=C sort -z <"$run_dir/keyed" >"$run_dir/selected"; then
	echo '起こす順の並べ替えに失敗しました' >&2
	exit 1
fi
# 重みの大きい順に、合計がいちばん小さいシャードへ入れ、k 番目のシャードのファイルを起こす順に残す。
ordered=()
shard_totals=()
for ((i=0; i<shard_count; i++)); do shard_totals+=(0); done
while IFS= read -r -d '' line; do
	test=${line#*$'\t'}
	weight=$((999999999 - 10#${line%%$'\t'*}))
	target=0
	for ((i=1; i<shard_count; i++)); do
		if ((shard_totals[i] < shard_totals[target])); then target=$i; fi
	done
	shard_totals[target]=$((shard_totals[target] + weight))
	if ((target == shard_index - 1)); then ordered+=("$test"); fi
done <"$run_dir/selected"
suite_note=
if [[ -n $shard ]]; then suite_note="、シャード $shard_index/$shard_count"; fi
if [[ ${#ordered[@]} == 0 ]]; then
	printf 'PASS suite: すべてのテスト（0 本、並列 %s%s）\n' "$jobs" "$suite_note"
	exit 0
fi
for ((i=0; i<${#ordered[@]}; i++)); do
	mkdir -p "$run_dir/$i/home" "$run_dir/$i/tmp"
	printf '%s\0%s\0' "$i" "${ordered[$i]}" >>"$run_dir/queue"
done
# bash 3.2 でも使える xargs。割り込み時に子も止められる専用のグループで起こす。
# グループは、set -m ではなく子が自分で作る。set -m は親と子の両方が setpgid を呼び、
# 負荷が高いと子の側が失敗して、標準エラーに警告を出すため。
python3 -c 'import os, sys; os.setpgrp(); os.execvp(sys.argv[1], sys.argv[1:])' \
	xargs -0 -n 2 -P "$jobs" bash "$root/tests/run-one.sh" "$root" "$run_dir" <"$run_dir/queue" &
worker_pid=$!
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
		status=missing elapsed=0 limit=
		if [[ -f $run_dir/$i/result ]]; then read -r status elapsed limit <"$run_dir/$i/result" || status=missing; fi
		actual=FAIL
		if [[ $status == 0 ]]; then actual=PASS; fi
		[[ $actual == "$outcome" ]] || continue
		if [[ $actual == PASS ]]; then
			printf '==== PASS %s（%s 秒）\n' "$test" "$elapsed"
		elif [[ -n $limit ]]; then
			failed+=("$test")
			printf '==== FAIL %s（時間切れ: %s 秒で止めた）\n' "$test" "$limit"
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
			if [[ -n $limit ]]; then command="時間切れ: $limit 秒で止めた"; fi
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
printf 'PASS suite: すべてのテスト（%s 本、並列 %s%s）\n' "${#ordered[@]}" "$jobs" "$suite_note"
