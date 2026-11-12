#!/usr/bin/env bash
# リーダーの評価の場面の形と、流す仕組みを、本物のモデルを呼ばずに確かめる。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
export PYTHONDONTWRITEBYTECODE=1
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/leader-eval-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
eval_dir="$root/tests/leader-eval"
scenes_dir="$eval_dir/scenes"
helper=(python3 -I -B "$eval_dir/leader_eval.py")

# 設計の「場面の一覧」にある 18 場面。まだ置いていないものだけを pending に書く（今はすべて置いてある）。
expected_scenes='1-1 1-2 2-1 2-2 3-1 3-2 4-1 4-2 5-1 5-2 6-1 6-2 保-1 保-2 保-3 保-4 保-5 保-6'
pending_scenes=''

# --- 場面の形 ---
present=
for dir in "$scenes_dir"/*/; do
	id=$(basename "$dir")
	[[ " $expected_scenes " == *" $id "* ]] || { echo "設計にない場面です: $id" >&2; exit 1; }
	[[ " $pending_scenes " != *" $id "* ]] || { echo "置いてある場面が pending に残っています: $id" >&2; exit 1; }
	present="$present $id"
	[[ -f $dir/scene.md && -f $dir/cli.json ]] || { echo "$id: scene.md と cli.json が要ります" >&2; exit 1; }
	jq -e '.commands | type == "array" and all(.[]; has("match") and (.match | type == "string"))' "$dir/cli.json" >/dev/null ||
		{ echo "$id: cli.json の形が違います" >&2; exit 1; }
	"${helper[@]}" scene "$dir/scene.md" >"$test_dir/scene.json"
	[[ $(jq -r .id "$test_dir/scene.json") == "$id" ]] || { echo "$id: 場面の ID がディレクトリ名と違います" >&2; exit 1; }
	jq -e '.type | test("^[1-6保]$")' "$test_dir/scene.json" >/dev/null || { echo "$id: 型が 1〜6 か 保 ではありません" >&2; exit 1; }
	[[ $(jq -r .type "$test_dir/scene.json") == "${id%%-*}" ]] || { echo "$id: 型が ID の先頭と違います" >&2; exit 1; }
	if grep -Eqi '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$dir/scene.md" "$dir/cli.json"; then
		echo "$id: UUID の形の値があります" >&2
		exit 1
	fi
done
for id in $expected_scenes; do
	[[ " $present " == *" $id "* || " $pending_scenes " == *" $id "* ]] || { echo "場面がありません: $id" >&2; exit 1; }
done
for type in 1 2 3 4 5 6; do
	count=0
	for id in $expected_scenes; do [[ ${id%%-*} == "$type" ]] && count=$((count + 1)); done
	((count >= 2)) || { echo "型 $type の場面が 2 つ未満です" >&2; exit 1; }
done
if grep -Eqi '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$eval_dir/values.json"; then
	echo "values.json に UUID の形の値があります" >&2
	exit 1
fi
echo "PASS leader-eval: 18 場面の形が決まりどおり（pending: $(wc -w <<<"$pending_scenes" | tr -d ' ') 場面）"

# --- 悪い場面を拒む ---
bad="$test_dir/bad"
mkdir -p "$bad"
good="$scenes_dir/保-2/scene.md"
sed '/^## 入力$/,/^$/d' "$good" >"$bad/no-input.md"
sed 's/^1\. \[記録\]/1. [確認]/' "$good" >"$bad/bad-kind.md"
sed 's/ `判定: posted: mention:\/\/member\/member1`//' "$good" >"$bad/no-predicate.md"
sed 's/^- 型: 保$//' "$good" >"$bad/no-type.md"
for name in no-input bad-kind no-predicate no-type; do
	if "${helper[@]}" scene "$bad/$name.md" >/dev/null 2>&1; then
		echo "悪い場面を通しました: $name" >&2
		exit 1
	fi
done
echo "PASS leader-eval: 見出しの欠け、基準の種類、判定の欠けた場面を拒む"

# --- [記録] の判定 ---
cat >"$test_dir/calls.jsonl" <<'JSON'
{"command": "multica issue pull-requests issue-shop-1 --output json", "kind": "read", "exit": 0}
{"command": "multica issue comment add issue-shop-1 --content-file tmp/c.md", "kind": "write", "exit": 0, "bodies": ["お願いします [@member1](mention://member/member1)"]}
JSON
python3 -I -B - "$eval_dir" "$test_dir/calls.jsonl" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
import leader_eval as le
calls = [json.loads(l) for l in open(sys.argv[2])]
def check(predicate, expect):
    ok, reason = le.check_record(predicate, calls)
    assert ok is expect, (predicate, ok, reason)
check("called: issue pull-requests", True)
check("called: issue --help", False)
check("not-called: squad-pr-link", True)
check("not-called: issue pull-requests", False)
check("before: issue pull-requests => issue comment add", True)
check("before: issue comment add => issue pull-requests", False)
check("posted: mention://member/member1", True)
check("not-posted: mention://agent/", True)
check("not-posted: mention://member/", False)
check("called: issue pull-requests && posted: member1 && not-called: cancel-task", True)
check("called: issue pull-requests && not-called: issue comment add", False)
PY
echo "PASS leader-eval: [記録] の判定が呼び出しの記録と投稿した文から決まる"

# --- スタブの claude で流す ---
stub_bin="$test_dir/stub-bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/claude" <<'EOF2'
#!/usr/bin/env bash
model= effort= prev=
for arg in "$@"; do
	case $prev in --model) model=$arg ;; --effort) effort=$arg ;; esac
	prev=$arg
done
case "$*" in
*"[leader-eval-scorer]"*)
	echo "scorer $model $effort" >>"$STUB_LOG"
	echo '{"pass": true, "reason": "stub"}'
	exit 0
	;;
esac
echo "leader $model $effort $(basename "$PWD" | cut -c1-4)" >>"$STUB_LOG"
grep -q 'shop-orchestrator-member1' CLAUDE.md || exit 3
grep -q 'Multica Agent Runtime' CLAUDE.md || exit 3
test -f .claude/skills/squad-handoff/SKILL.md || exit 3
multica issue get issue-shop-1 >/dev/null
multica issue pull-requests issue-shop-1 --output json >/dev/null
multica no-such-command || true
printf '確認します [@member1](mention://member/member1)\n' >tmp/c.md
multica issue comment add issue-shop-1 --parent comment-2 --content-file tmp/c.md
multica issue status issue-shop-1 in_review
echo done
EOF2
chmod +x "$stub_bin/claude"
export STUB_LOG="$test_dir/stub.log"
out="$test_dir/out"
PATH="$stub_bin:$PATH" bash "$eval_dir/run.sh" --baseline HEAD --scenes 1-1,保-2 --runs 2 --jobs 2 --out "$out" >"$test_dir/run.out" 2>"$test_dir/run.err" ||
	{ cat "$test_dir/run.err" >&2; exit 1; }

for which in old new; do
	file="$out/instructions/$which/instructions.md"
	[[ -s $file ]] || { echo "$which の指示がありません" >&2; exit 1; }
	grep -q '^## このプロジェクトの値$' "$file"
	grep -q 'shop-orchestrator-member1' "$file"
	grep -q 'Multica Agent Runtime' "$file"
	if grep -Eq '\{\{|<!-- (IF|ELSE|ENDIF)' "$file"; then echo "$which: 差し込みが残っています" >&2; exit 1; fi
	[[ -f $out/instructions/$which/skills/squad-handoff/SKILL.md ]]
	jq -e '.model | length > 0' "$out/instructions/$which/meta.json" >/dev/null
done
echo "PASS leader-eval: 今と新しい指示を展開し、squad-handoff と一緒に作業ディレクトリへ置く"

[[ $(wc -l <"$out/runs.jsonl" | tr -d ' ') == $((2 * 2 * 2)) ]] || { echo "runs.jsonl の行数が違います" >&2; exit 1; }
jq -e -s 'all(.[]; has("scene") and has("which") and has("n") and has("model") and has("calls") and has("comments") and has("response") and has("criteria"))' "$out/runs.jsonl" >/dev/null
jq -e -s 'all(.[]; .pass == true)' "$out/runs.jsonl" >/dev/null
jq -e -s 'all(.[]; any(.calls[]; .kind == "unmatched" and .exit == 1))' "$out/runs.jsonl" >/dev/null
jq -e -s 'all(.[]; any(.calls[]; .kind == "write" and (.bodies | length) > 0))' "$out/runs.jsonl" >/dev/null
jq -e -s 'all(.[]; (.comments | length) > 0 and (.comments[0] | contains("member1")))' "$out/runs.jsonl" >/dev/null
jq -e -s 'all(.[]; .criteria | all(.[]; has("n") and has("kind") and has("pass") and has("reason")))' "$out/runs.jsonl" >/dev/null
grep -q '^| 保-2 | 保 | 2/2 | 2/2 | - |$' "$out/summary.md"
grep -q '^| 1-1 | 1 | 2/2 | 2/2 | - |$' "$out/summary.md"
echo "PASS leader-eval: スタブのコマンドが呼び出しを記録し、runs.jsonl と summary.md が決まった形で出る"

grep -q '^leader claude-sonnet-5-5 medium' "$test_dir/stub.log"
grep -q '^scorer claude-opus-5-5 high' "$test_dir/stub.log"
echo "PASS leader-eval: モデルと思考の深さは展開した front matter から、採点は opus の high で流す"

# --- 全場面をスタブで流す（合否は問わず、場面が読めて 1 行ずつ出ることだけを見る）---
all_out="$test_dir/all"
PATH="$stub_bin:$PATH" bash "$eval_dir/run.sh" --baseline HEAD --runs 1 --only new --jobs 4 --out "$all_out" >"$test_dir/all.out" 2>"$test_dir/all.err" ||
	{ cat "$test_dir/all.err" >&2; exit 1; }
[[ $(wc -l <"$all_out/runs.jsonl" | tr -d ' ') == "$(wc -w <<<"$expected_scenes" | tr -d ' ')" ]] || { echo "全場面の runs.jsonl の行数が違います" >&2; exit 1; }
for id in $expected_scenes; do
	jq -e -s --arg id "$id" 'any(.[]; .scene == $id and .which == "new" and (.criteria | length) > 0)' "$all_out/runs.jsonl" >/dev/null ||
		{ echo "$id: 全場面の結果に行がありません" >&2; exit 1; }
done
echo "PASS leader-eval: 18 場面すべてをスタブで流し、場面ごとに基準の結果が出る"
