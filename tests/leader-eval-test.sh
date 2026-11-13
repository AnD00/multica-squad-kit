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

# 設計の「場面の一覧」にある 19 場面。まだ置いていないものだけを pending に書く（今はすべて置いてある）。
expected_scenes='1-1 1-2 2-1 2-2 3-1 3-2 4-1 4-2 5-1 5-2 6-1 6-2 keep-1 keep-2 keep-3 keep-4 keep-5 keep-6 keep-7'
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
	[[ $id =~ ^([1-6]|keep)-[0-9]+$ ]] || { echo "$id: 場面の ID が <型の数字>-<番号> か keep-<番号> ではありません" >&2; exit 1; }
	expected_type=${id%%-*}
	[[ $expected_type != keep ]] || expected_type=保
	[[ $(jq -r .type "$test_dir/scene.json") == "$expected_type" ]] || { echo "$id: 型が ID の先頭と違います" >&2; exit 1; }
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
echo "PASS leader-eval: 19 場面の形が決まりどおり（pending: $(wc -w <<<"$pending_scenes" | tr -d ' ') 場面）"

# --- 悪い場面を拒む ---
bad="$test_dir/bad"
mkdir -p "$bad"
good="$scenes_dir/keep-2/scene.md"
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

# Claude が拒否した呼び出しはスタブに届かなくても、未呼び出しの判定に数える。
# JSON の欄の形: https://github.com/anthropics/claude-code/issues/77037
python3 -I -B - "$eval_dir" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
import leader_eval as le
denials = [
    {"tool_name": "Bash", "tool_use_id": "tool-denied-1",
     "tool_input": {"command": "multica issue cancel-task issue-shop-1 task-fixer"}},
    {"tool_name": "Bash", "tool_use_id": "tool-denied-2",
     "tool_input": {"command": "squad-pr-link issue-shop-1 https://github.com/example/shop/pull/7"}},
    {"tool_name": "Read", "tool_use_id": "tool-denied-3", "tool_input": {"file_path": "/outside/file.md"}},
]
response, actual, calls, is_error = le.parse_agent_output(json.dumps({
    "type": "result", "result": "最後の返答", "is_error": False, "permission_denials": denials,
}))
assert response == "最後の返答" and actual == denials and not is_error
assert len(calls) == 3 and all(c["kind"] == "denied" and c["exit"] is None for c in calls)
for command in ("^multica issue cancel-task", "^squad-pr-link"):
    assert not le.check_record("not-called: " + command, calls)[0]
    assert not le.check_record("called: " + command, calls)[0]
assert calls[-1]["tool_input"] == denials[-1]["tool_input"]
for bad in ["not JSON", "[]", '{"type":"result","result":"done"}',
            '{"type":"result","permission_denials":[{}]}']:
    try:
        le.parse_agent_output(bad)
    except ValueError:
        continue
    raise AssertionError(bad)
PY
echo "PASS leader-eval: 拒否された道具の入力を残し、未呼び出しの合格や実行した扱いにしない"

# keep-7 は、通常の依頼を通し、CI・待ちの欠落、順序や対象コミットの違いを落とす。
python3 -I -B - "$eval_dir" <<'PY'
import copy, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import leader_eval as le
scene = le.parse_scene(Path(sys.argv[1]) / "scenes/keep-7/scene.md")
calls = [
    {"command": "multica issue pull-requests issue-shop-1 --output json"},
    {"command": "squad-pr-watch ci issue-shop-1 agent-ci-monitor comment-3"},
    {"command": "squad-review-wait watch issue-shop-1 comment-3 agent-code-reviewer agent-qa"},
    {"command": "multica issue comment add issue-shop-1 --parent comment-3 --content-file tmp/reply.md",
     "bodies": ["返事を待つ役: [@Code](mention://agent/agent-code-reviewer) [@QA](mention://agent/agent-qa)\n"
                "確認するコミット: 3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567"]},
]
def passed(records):
    return all(le.check_record(c["predicate"], records)[0] for c in scene["criteria"])
assert passed(calls)
for missing in range(4):
    assert not passed(calls[:missing] + calls[missing + 1:]), missing
assert not passed(calls[:2] + [calls[3], calls[2]])
for text in ["返事を待つ役:", "確認するコミット:", "agent-qa", "agent-code-reviewer", "3f9a2c1"]:
    wrong = copy.deepcopy(calls)
    wrong[-1]["bodies"][0] = wrong[-1]["bodies"][0].replace(text, "missing")
    assert not passed(wrong), text
PY
echo "PASS leader-eval: keep-7 は CI と返事の待ち、依頼の順序・役・コミットを確かめる"

# --- スタブの claude で流す ---
stub_bin="$test_dir/stub-bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/claude" <<'EOF2'
#!/usr/bin/env bash
model= effort= format= prev=
for arg in "$@"; do
	case $prev in --model) model=$arg ;; --effort) effort=$arg ;; --output-format) format=$arg ;; esac
	prev=$arg
done
case "$*" in
*"[leader-eval-scorer]"*)
	echo "scorer $model $effort" >>"$STUB_LOG"
	python3 -I - "$2" <<'PY'
import json, sys
prompt = sys.argv[1]
assert "## エージェントの最後の返答\n" in prompt
response = prompt.split("## エージェントの最後の返答\n", 1)[1].split("\n\n合否と理由を、", 1)[0]
ok = response == "/note\n返事の待ち: 回ごと済み" if "最後の返答にしている" in prompt else True
print(json.dumps({"pass": ok, "reason": "最後の返答で判定"}, ensure_ascii=False))
PY
	exit 0
	;;
esac
echo "leader $model $effort $(basename "$PWD" | cut -c1-4)" >>"$STUB_LOG"
[[ $format == json ]] || exit 4
grep -q 'shop-orchestrator-member1' CLAUDE.md || exit 3
grep -q 'Multica Agent Runtime' CLAUDE.md || exit 3
test -f .claude/skills/squad-handoff/SKILL.md || exit 3
if [[ $* == *'ほぼ同時に、レビューの役も同じ知らせ'* ]]; then
	squad-review-wait proceed issue-shop-1 comment-6 >tmp/proceed.md
	python3 -I - <<'PY'
import json, os
from pathlib import Path
denials = []
if os.environ.get("STUB_DENIAL"):
    denials = [{"tool_name": "Bash", "tool_use_id": "tool-denied",
                "tool_input": {"command": "multica issue status issue-shop-1 in_review"}}]
print(json.dumps({"type": "result", "is_error": False, "permission_denials": denials,
                  "result": os.environ.get("STUB_RESPONSE", Path("tmp/proceed.md").read_text().strip())}, ensure_ascii=False))
PY
	exit 0
fi
multica issue get issue-shop-1 >/dev/null
multica issue pull-requests issue-shop-1 --output json >/dev/null
multica no-such-command >/dev/null 2>&1 || true
printf '確認します [@member1](mention://member/member1)\n' >tmp/c.md
multica issue comment add issue-shop-1 --parent comment-2 --content-file tmp/c.md >/dev/null
multica issue status issue-shop-1 in_review >/dev/null
echo '{"type":"result","result":"done","is_error":false,"permission_denials":[]}'
EOF2
chmod +x "$stub_bin/claude"
export STUB_LOG="$test_dir/stub.log"
out="$test_dir/out"
PATH="$stub_bin:$PATH" bash "$eval_dir/run.sh" --baseline HEAD --scenes 1-1,keep-2 --runs 2 --jobs 2 --out "$out" >"$test_dir/run.out" 2>"$test_dir/run.err" ||
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
jq -e -s 'all(.[]; .response == "done" and .exit_code == 0 and (.duration_ms >= 0) and .permission_denials == [])' "$out/runs.jsonl" >/dev/null
jq -e -s 'all(.[]; .criteria | all(.[]; has("n") and has("kind") and has("pass") and has("reason")))' "$out/runs.jsonl" >/dev/null
grep -q '^| keep-2 | 保 | 2/2 | 2/2 | - |$' "$out/summary.md"
grep -q '^| 1-1 | 1 | 2/2 | 2/2 | - |$' "$out/summary.md"
echo "PASS leader-eval: スタブのコマンドが呼び出しを記録し、runs.jsonl と summary.md が決まった形で出る"

grep -q '^leader claude-sonnet-5-5 high' "$test_dir/stub.log"
grep -q '^scorer claude-opus-5-5 high' "$test_dir/stub.log"
echo "PASS leader-eval: モデルと思考の深さは展開した front matter から、採点は opus の high で流す"

# keep-6 の最後の返答だけを変え、採点が合格と不合格に分かれることを確かめる。
for mode in good bad denied; do
	case $mode in good | denied) reply=$'/note\n返事の待ち: 回ごと済み' ;; bad) reply='別の返答' ;; esac
	denial=
	[[ $mode != denied ]] || denial=1
	mode_out="$test_dir/final-$mode"
	STUB_RESPONSE="$reply" STUB_DENIAL="$denial" PATH="$stub_bin:$PATH" bash "$eval_dir/run.sh" \
		--baseline HEAD --scenes keep-6 --only new --runs 1 --jobs 1 --out "$mode_out" >"$test_dir/$mode.out" 2>"$test_dir/$mode.err" ||
		{ cat "$test_dir/$mode.err" >&2; exit 1; }
	done_file="$mode_out/runs.jsonl"
	case $mode in
	good) jq -e '.pass == true and .response == "/note\n返事の待ち: 回ごと済み" and .comments == []' "$done_file" >/dev/null ;;
	bad) jq -e '.pass == false and (.criteria[] | select(.n == 3) | .pass == false)' "$done_file" >/dev/null ;;
	denied)
		jq -e '.pass == false and (.error | contains("拒否")) and (.permission_denials | length) == 1
			and any(.calls[]; .kind == "denied" and .exit == null and .tool_use_id == "tool-denied"
				and .command == "multica issue status issue-shop-1 in_review")
			and (.criteria[] | select(.n == 2) | .pass == false)' "$done_file" >/dev/null
		;;
	esac
done
echo "PASS leader-eval: keep-6 の採点に最後の返答を渡し、拒否された状態の変更を記録と判定に含める"

# --- 全場面をスタブで流す（合否は問わず、場面が読めて 1 行ずつ出ることだけを見る）---
all_out="$test_dir/all"
PATH="$stub_bin:$PATH" bash "$eval_dir/run.sh" --baseline HEAD --runs 1 --only new --jobs 4 --out "$all_out" >"$test_dir/all.out" 2>"$test_dir/all.err" ||
	{ cat "$test_dir/all.err" >&2; exit 1; }
[[ $(wc -l <"$all_out/runs.jsonl" | tr -d ' ') == "$(wc -w <<<"$expected_scenes" | tr -d ' ')" ]] || { echo "全場面の runs.jsonl の行数が違います" >&2; exit 1; }
for id in $expected_scenes; do
	jq -e -s --arg id "$id" 'any(.[]; .scene == $id and .which == "new" and (.criteria | length) > 0)' "$all_out/runs.jsonl" >/dev/null ||
		{ echo "$id: 全場面の結果に行がありません" >&2; exit 1; }
done
echo "PASS leader-eval: 19 場面すべてをスタブで流し、場面ごとに基準の結果が出る"
