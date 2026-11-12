#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/setup-fixture.sh"
manifest
export TEMPLATE_STATE_ROOT="$test_dir/fold-state"
# 端末に答えを打つ画面で、答えた質問が 1 行に縮むかを確かめる。確認の no まで進み、実サービスへは呼び出さない。
esc=$'\033'
# 先頭の空行は拡張のディレクトリの質問への答え。
happy='1\nShop\n\n1,2\n\n\n1\n\n\nno\n'

# fold <名前> <答えの行（printf の書式）> [question-pty.py の大きさの指定...]
# 端末の出力を $test_dir/<名前>.raw に、画面に残る文字を $test_dir/<名前>.txt に保存する。画面の大きさは --size で決める。
fold() {
 local name=$1 answers=$2 columns=100 rows=40 args=("${@:3}") index
 for ((index = 0; index < ${#args[@]}; index++)); do
  if [[ ${args[index]} == --size ]]; then columns=${args[index + 1]}; rows=${args[index + 2]}; fi
 done
 printf "\\n$answers" >"$test_dir/$name.answers"
 env -u NO_COLOR python3 "$root/tests/question-pty.py" "$test_dir/$name.raw" "$test_dir/$name.answers" "${args[@]}" -- /bin/bash "$test_dir/package/setup.sh" || true
 python3 -I - "$root/tests/ansi-to-png.py" "$test_dir/$name.raw" "$test_dir/$name.txt" "$columns" "$rows" <<'PY'
import importlib.util
import sys

sys.dont_write_bytecode = True
path, raw, output, columns, rows = sys.argv[1:]
spec = importlib.util.spec_from_file_location("ansi_to_png", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
terminal = module.Terminal(int(columns), int(rows))
with open(raw, "rb") as handle:
    terminal.feed(handle.read().decode("utf-8", "replace"), final=True)
with open(output, "w", encoding="utf-8") as handle:
    handle.write(module.plain_text(terminal.lines()) + "\n")
PY
}
# 縮めた答えの行（✔ で始まる行）の数と、開いたままの質問の行（? と › で始まる行）の数。
folded() { grep -c '^✔ ' "$test_dir/$1.txt" || true; }
opened() { grep -cE '^(\?|›) ' "$test_dir/$1.txt" || true; }

# 高さが足りるときは、9 問とも 1 行に縮み、題・説明・選択肢・入力の行が残らない。
fold tall "$happy" --size 100 100
grep -qF '✔ ワークスペース               Workspace A' "$test_dir/tall.txt"
[[ $(folded tall) == 9 ]]
[[ $(opened tall) == 3 ]]
! grep -qE '^ +[0-9]+  ' "$test_dir/tall.txt"
! grep -qF 'エージェントのチームを作る置き場です' "$test_dir/tall.txt"
# 縮めた 9 行は続けて並び、間の空行を残さない。
awk '/^✔ ワークスペース/ {start=NR} /^  エージェント$/ {end=NR} {line[NR]=$0} END {for (i = start; i < start + 9; i++) if (line[i] !~ /^✔ /) exit 1; if (line[start + 9] != "" || end != start + 10) exit 1}' "$test_dir/tall.txt"
# 縮めるのに使う制御は、上へ戻る ESC[nA、行頭の \r、以降を消す ESC[J だけ。
grep -qE "$esc\\[[0-9]+A" "$test_dir/tall.raw"
grep -qF "$esc[J" "$test_dir/tall.raw"
! grep -aqE "$esc\\[[0-9;]*[HfBCDEFGSTK]" "$test_dir/tall.raw"
echo 'PASS fold: 端末に収まるとき、答えた質問は 9 問とも 1 行に縮み、題・説明・選択肢・入力の行が残らない'

# 受け付けなかった答えの ✖ と入力の行も、答えたときにまとめて消える。画面に残るのは縮めた行だけ。
fold rejected "\n$happy" --size 100 100
grep -qF "✖$esc[0m 1つ以上の番号を" "$test_dir/rejected.raw"
! grep -qF '✖' "$test_dir/rejected.txt"
[[ $(folded rejected) == 9 ]]
[[ $(opened rejected) == 3 ]]
echo 'PASS fold: 受け付けなかった理由の行と入力の行は、答えたときにまとめて消える'

# 入力が端末の幅で折り返しても、折り返した行まで消す（半角 150 字と、全角 60 字）。
ascii=$(printf 'a%.0s' $(seq 1 150))
wide=$(printf '店%.0s' $(seq 1 60))
for name in ascii wide; do
 value=${!name}
 fold "wrap-$name" "1\n$value\nshop\n1,2\n\n\n1\n\n\nno\n" --size 100 100
 grep -qF "$value" "$test_dir/wrap-$name.raw"
 [[ $(folded "wrap-$name") == 9 ]]
 [[ $(opened "wrap-$name") == 3 ]]
 ! grep -qE '^ +[0-9]+  ' "$test_dir/wrap-$name.txt"
 ! grep -qF 'タスクを入れる場所です' "$test_dir/wrap-$name.txt"
 ! grep -qF 'Existing project' "$test_dir/wrap-$name.txt"
 # 縮めた行の前にも間にも、消し残りの行と空行がない。
 awk '/^✔ ワークスペース/ {start=NR} /^  エージェント$/ {end=NR} {line[NR]=$0} END {for (i = 1; i < start; i++) if (line[i] ~ /^\? (ワークスペース|プロジェクト|リポジトリ)/ || line[i] ~ /エージェントの/) exit 1; for (i = start; i < end - 1; i++) if (line[i] ~ /^[›?]/ || line[i] == "") exit 1}' "$test_dir/wrap-$name.txt"
done
echo 'PASS fold: 入力が端末の幅で折り返しても、折り返した行まで消して縮める'

# 開いた質問が高さに収まらないとき（外す役は選択肢が多い）は、その質問を縮めず、入力の行のあとに ✔ を足す。切らない。
fold short "$happy" --size 100 40
grep -qxF '? 外す役  ●●●●●●●●○' "$test_dir/short.txt"
grep -qxF '    12  Dependabot の PR: 更新を週次で扱う。' "$test_dir/short.txt"
grep -qF 'エージェント: shop-orchestrator-owner' "$test_dir/short.txt"
awk '/^\? 外す役/ {open=NR} /^› 0$/ && open && !input {input=NR} /^✔ 外す役/ {done=NR} END {exit !(open && input && done == input + 1)}' "$test_dir/short.txt"
# 前後の質問は縮み、Webhook の質問も縮む。
grep -qF '✔ スクワッドに入れる人間       Member A' "$test_dir/short.txt"
grep -qF '✔ 使うランタイム               Claude Code  Codex' "$test_dir/short.txt"
grep -qF '✔ Dependabot の PR の Webhook  使わない' "$test_dir/short.txt"
! grep -qE '^\? (ワークスペース|プロジェクト|リポジトリ|使うランタイム|Dependabot の PR の Webhook)' "$test_dir/short.txt"
[[ $(grep -c '^? ' "$test_dir/short.txt") == 3 ]]
echo 'PASS fold: 高さに収まらない質問は縮めず、切らずに入力の行のあとへ ✔ を足し、前後の質問は縮める'

# 答えるまでに端末の大きさが変わった質問は縮めない。次の質問からは縮める。
fold resized "$happy" --size 100 100 --resize-on '? プロジェクトの区別' 100 90
grep -qxF '? プロジェクトの区別  ●●●○○○○○○' "$test_dir/resized.txt"
awk '/^\? プロジェクトの区別/ {open=NR} /^› / && open && !input && NR > open {input=NR} /^✔ プロジェクトの区別/ {done=NR} END {exit !(open && input && done == input + 1)}' "$test_dir/resized.txt"
[[ $(grep -c '^? ' "$test_dir/resized.txt") == 3 ]]
grep -qF '✔ ワークスペース               Workspace A' "$test_dir/resized.txt"
grep -qF '✔ リポジトリ                   example/one  example/two' "$test_dir/resized.txt"
[[ $(folded resized) == 9 ]]
echo 'PASS fold: 答えるまでに端末の大きさが変わった質問は縮めず、次の質問からは縮める'
