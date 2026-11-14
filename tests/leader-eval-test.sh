#!/usr/bin/env bash
# リーダーの評価の場面の形と、流す仕組みを、本物のモデルを呼ばずに確認する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
export PYTHONDONTWRITEBYTECODE=1
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/leader-eval-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
eval_dir="$root/tests/leader-eval"
scenes_dir="$eval_dir/scenes"
helper=(python3 -I -B "$eval_dir/leader_eval.py")

# 原則の 19 場面、最終レビュー・CI 待ちの 9 場面、PR の紐付けの 8 場面、次の依頼の決定と使用率の待ちの 8 場面。まだ置いていないものだけを pending に書く（今はすべて置いてある）。
expected_scenes='1-1 1-2 2-1 2-2 3-1 3-2 4-1 4-2 5-1 5-2 6-1 6-2 keep-1 keep-2 keep-3 keep-4 keep-5 keep-6 keep-7 keep-8 keep-9 keep-10 keep-11 keep-12 keep-13 keep-14 keep-15 keep-16 keep-17 keep-18 keep-19 keep-20 keep-21 keep-22 keep-23 keep-24 keep-25 keep-26 keep-27 keep-28 keep-29 keep-30 keep-31 keep-32'
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
echo "PASS leader-eval: 44 場面の形が決まりどおり（pending: $(wc -w <<<"$pending_scenes" | tr -d ' ') 場面）"

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

# keep-7 は、通常の依頼を通し、CI・依頼の欠落や対象コミットの違いを落とす。
python3 -I -B - "$eval_dir" <<'PY'
import copy, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import leader_eval as le
scene = le.parse_scene(Path(sys.argv[1]) / "scenes/keep-7/scene.md")
request = "squad-review-next request issue-shop-1 comment-3 3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567"
calls = [
    {"command": "squad-pr-watch link-check issue-shop-1"},
    {"command": "squad-pr-watch ci issue-shop-1 agent-ci-monitor comment-3"},
    {"command": request},
]
def passed(records):
    return all(le.check_record(c["predicate"], records)[0] for c in scene["criteria"] if c["kind"] == "記録")
assert passed(calls)
for missing in range(3):
    assert not passed(calls[:missing] + calls[missing + 1:]), missing
for wrong in ("squad-review-next request issue-shop-1 comment-3 0000000", "squad-review-next request issue-shop-1 comment-2 3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567"):
    assert not passed(calls[:2] + [{"command": wrong}]), wrong
# 役を自分で選んで返事の待ちを入れる、または依頼の本文を自分で書く手順は通さない。
assert not passed(calls + [{"command": "squad-review-wait watch issue-shop-1 comment-3 agent-code-reviewer agent-qa"}])
assert not passed(calls + [{"command": "multica issue comment add issue-shop-1 --content-file tmp/c.md",
                            "bodies": ["返事を待つ役: x"]}])
assert not passed(calls + [{"command": "multica issue comment add issue-shop-1 --content-file tmp/c.md",
                            "bodies": ["確認するコミット: 3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567"]}])
PY
echo "PASS leader-eval: keep-7 は CI の見張りと review-next request の対象コミットを確認する"

# 紐付けの各分岐で、正しい記録を通し、禁止した進め方と要る確認の欠落を落とす。
python3 -I -B - "$eval_dir" <<'PY'
import json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import leader_eval as le
def command(text):
    return {"command": text}
def post(text):
    return {"command": "multica issue comment add issue-shop-1 --content-file tmp/reply.md", "bodies": [text]}
link = command("squad-pr-watch link-check issue-shop-1")
now = command("squad-pr-watch ci-now issue-shop-1 agent-orchestrator comment-3 agent-ci-monitor")
conflicts = command("squad-pr-watch conflicts-check issue-shop-1")
ci_watch = command("squad-pr-watch ci issue-shop-1 agent-ci-monitor comment-5")
ci_wait = command("squad-pr-watch ci-wait issue-shop-1 agent-orchestrator comment-5")
conflicts_watch = command("squad-pr-watch conflicts issue-shop-1 agent-orchestrator")
review = command("squad-review-next request issue-shop-1 comment-3 3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567")
old_review = command("squad-review-wait watch issue-shop-1 comment-3 agent-code-reviewer agent-qa")
in_review = command("multica issue status issue-shop-1 in_review")
ask_review = post("mention://agent/agent-code-reviewer mention://agent/agent-qa")
human = post("mention://member/member1 https://github.com/example/shop/pull/7 https://github.com/example/shop/pull/8")
cases = {
    "keep-3": [link, post("mention://agent/agent-claude-implementer pr_url を補ってください")],
    "5-2": [link, now, conflicts, review],
    "keep-17": [link, now, conflicts, review],
    "keep-18": [link, conflicts, ci_watch, ci_wait, conflicts_watch,
               command("squad-pr-watch unlinked issue-shop-1 comment-5 agent-ci-monitor"),
               post("mention://member/member1 マージ後 done にしてください\n見張り: 1 時間おき、2026-01-13T10:00Z まで\n紐付けの失敗: 警告"), in_review],
    "keep-19": [link, human, in_review],
    "keep-20": [link, link, post("mention://member/member1 紐付け: 未確認"), in_review],
    "keep-21": [link, human],
    "keep-22": [link, command("squad-pr-watch ci-now issue-shop-1 agent-orchestrator comment-3"), conflicts, review],
    "keep-23": [link, conflicts, ci_watch, conflicts_watch, human, in_review],
    "keep-24": [link, post("mention://member/member1 紐付け: 作業先と違う pr: https://github.com/elsewhere/shop/pull/7 作業先: example/shop metadata の修正をお願いします"), in_review],
}
scenes = {id: le.parse_scene(Path(sys.argv[1]) / "scenes" / id / "scene.md") for id in cases}
def passed(id, calls):
    return all(le.check_record(c["predicate"], calls)[0] for c in scenes[id]["criteria"] if c["kind"] == "記録")
for id, calls in cases.items():
    assert passed(id, calls), id
    if id != "keep-22":
        assert not passed(id, [c for c in calls if c != link]), (id, "判定なし")
# 追加した場面では、一覧と link-check の見本が同じ PR の状態を表す。
for n in range(17, 25):
    id = f"keep-{n}"
    table = json.loads((Path(sys.argv[1]) / "scenes" / id / "cli.json").read_text())["commands"]
    def response(prefix):
        return next(c["stdout"] for c in table if c["match"] == prefix + " issue-shop-1")
    state = response("squad-pr-watch link-check")
    if state.startswith("紐付け: 未確認 "):
        continue
    if state.startswith("紐付け: 作業先と違う "):
        metadata = json.loads(response("multica issue get"))["metadata"]
        assert metadata["pr_url"] in state and "作業先: " + metadata["repository"] in state
        assert "/".join(metadata["pr_url"].split("/")[3:5]).casefold() != metadata["repository"].casefold()
        continue
    prs = json.loads(response("multica issue pull-requests"))["pull_requests"]
    urls = [p["html_url"] for p in prs]
    pr = json.loads(response("multica issue get"))["metadata"]["pr_url"]
    if "紐付け: 紐付いている " in state:
        assert pr in urls, id
    elif "紐付け: 紐付いていない " in state:
        assert urls == [], id
    else:
        assert "紐付け: 食い違い " in state and urls and pr not in urls, id
for id in ("5-2", "keep-17", "keep-18", "keep-22"):
    assert not passed(id, [c for c in cases[id] if c != conflicts]), (id, "コンフリクトの確認なし")
    check = "ci-wait" if id == "keep-18" else "ci-now"
    assert not passed(id, [c for c in cases[id] if check not in c["command"]]), (id, "CI の確認なし")
# 見張り役があるマージ前は ci-now を重ねない。
assert not passed("keep-18", cases["keep-18"] + [now]), "keep-18 の ci-now"
for id in ("keep-3", "keep-17", "keep-22"):
    assert not passed(id, cases[id] + [human]), (id, "紐付けだけで人間を呼ぶ")
for id in ("keep-19", "keep-20", "keep-21", "keep-24"):
    assert not passed(id, cases[id] + [ask_review]), (id, "止まらずレビューへ回す")
for forbidden in (command("multica issue metadata set issue-shop-1 --key pr_url --value wrong"),
                  now, conflicts, review, old_review, command("gh pr view https://github.com/elsewhere/shop/pull/7"),
                  command("multica issue pull-requests issue-shop-1 --output json")):
    assert not passed("keep-24", cases["keep-24"] + [forbidden]), forbidden
for missing in ("https://github.com/elsewhere/shop/pull/7", "作業先: example/shop", "mention://member/member1"):
    import copy
    wrong = copy.deepcopy(cases["keep-24"])
    wrong[1]["bodies"][0] = wrong[1]["bodies"][0].replace(missing, "なし")
    assert not passed("keep-24", wrong), missing
assert not passed("5-2", cases["5-2"] + [in_review])
assert not passed("keep-3", cases["keep-3"] + [review])
assert not passed("keep-3", cases["keep-3"] + [ask_review])
assert not passed("keep-3", cases["keep-3"] + [old_review])
for id in ("keep-17", "keep-22"):
    assert not passed(id, cases[id] + [old_review]), (id, "役を自分で選ぶ返事の待ち")
    assert not passed(id, [c for c in cases[id] if c != review]), (id, "review-next request がない")
assert not passed("keep-22", [c if "ci-now" not in c["command"] else now for c in cases["keep-22"]])
assert not passed("keep-23", cases["keep-23"] + [command("squad-pr-watch unlinked issue-shop-1 comment-5 agent-ci-monitor")])
for missing in ("done", "見張り:", "紐付けの失敗:"):
    import copy
    wrong = copy.deepcopy(cases["keep-18"])
    wrong[-2]["bodies"][0] = wrong[-2]["bodies"][0].replace(missing, "なし")
    assert not passed("keep-18", wrong), missing
PY
echo "PASS leader-eval: 紐付けの判定ごとの進め方、停止、マージへの依頼を記録で区別する"

# 追加した場面の基準は、正しい記録を通し、最終レビューの省略や CI 待ちの欠落を落とす。
python3 -I -B - "$eval_dir" <<'PY_FINAL_SCENES'
import copy, json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import leader_eval as le
root = Path(sys.argv[1]) / 'scenes'
for n in range(8, 17):
    path = root / f'keep-{n}'
    scene = le.parse_scene(path / 'scene.md')
    records = json.loads((path / 'cli.json').read_text())['expected_records']
    def passed(calls):
        return all(le.check_record(c['predicate'], calls)[0]
                   for c in scene['criteria'] if c['kind'] == '記録')
    assert passed(records), (n, '期待する記録が通らない')
    wrong = copy.deepcopy(records)
    if n in (8, 9, 10):
        wrong = [r for r in wrong if 'squad-review-wait watch' not in r['command']]
    elif n == 11:
        wrong[-1]['bodies'][0] = wrong[-1]['bodies'][0].replace('見る範囲:', '範囲なし:')
    elif n in (12, 13, 15):
        wrong[-1]['bodies'][0] += '\n[@Owner](mention://member/member1)'
    elif n == 14:
        wrong[0]['command'] = wrong[0]['command'].replace(' ci-wait-rule', '')
    elif n == 16:
        wrong = [wrong[-1], wrong[0]]
    assert not passed(wrong), (n, '手順を外した記録が通った')
print('PASS leader-eval: 最終レビューと CI 待ちの 9 場面は、期待する記録と手順を外した記録を区別する')
PY_FINAL_SCENES

# 次の依頼の決定と使用率の待ちの 8 場面は、期待する記録を通し、手順を外した記録を落とす。
python3 -I -B - "$eval_dir" <<'PY_NEXT_SCENES'
import copy, json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import leader_eval as le
root = Path(sys.argv[1]) / 'scenes'
def command(text, kind='read', exit=0):
    return {'command': text, 'kind': kind, 'exit': exit}
def post(text, parent='comment-5'):
    return {'command': f'multica issue comment add issue-shop-1 --parent {parent} --content-file tmp/reply.md',
            'bodies': [text], 'kind': 'write', 'exit': 0}
for n in range(25, 33):
    path = root / f'keep-{n}'
    scene = le.parse_scene(path / 'scene.md')
    records = json.loads((path / 'cli.json').read_text())['expected_records']
    def passed(calls):
        return all(le.check_record(c['predicate'], calls)[0]
                   for c in scene['criteria'] if c['kind'] == '記録')
    assert passed(records), (n, '期待する記録が通らない')
    wrongs = []
    if n == 25:
        wrongs = [[command('squad-pr-watch ci-wait issue-shop-1 agent-orchestrator comment-final ci-wait-rule')],
                  [command('squad-review-next decide issue-shop-1 principal-done')],
                  [command('squad-review-next decide issue-shop-1 principal-done ci-wait-rule'),
                   command('squad-pr-watch ci-wait issue-shop-1 agent-orchestrator comment-final ci-wait-rule')],
                  records + [post('マージの依頼: 3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567', 'comment-final')]]
    elif n == 26:
        wrongs = [records[::-1], records[:1], records[1:],
                  [records[0], copy.deepcopy(records[1])] ,
                  records + [command('squad-dispatch-pick issue-shop-1 fix')]]
        wrongs[3][1]['bodies'] = [records[1]['bodies'][0].replace('mention://agent/agent-claude-fixer', 'mention://member/member1')]
    elif n == 27:
        extension = records[0]
        wrongs = [records[1:], records[::-1], records[:1],
                  [post('使用率の待ちの延長: implement。決めた人: Owner'), records[1]],
                  [post('使用率の待ちの延長: fix。決めた人: Owner'), records[1],
                   post('[@fixer](mention://agent/agent-claude-fixer) 直してください')]]
    elif n == 28:
        wrongs = [records + [post('使用率の待ちの延長: fix。決めた人: Owner')],
                  records + [command('squad-usage-wait pick issue-shop-1 fix')],
                  [post('待ちます。')]]
    elif n == 29:
        wrongs = [records[1:], [records[0], records[1], records[3]],
                  [records[0], records[1], post(records[2]['bodies'][0].replace('pull/8', 'pull/9'), 'comment-6'), records[3]],
                  records + [command('squad-review-next request issue-shop-1 comment-6 3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567')],
                  records + [command('multica issue metadata set issue-shop-1 --key pr_url --value x')]]
    elif n == 30:
        human = post('[@Owner](mention://member/member1) マージの判断をお願いします。', 'comment-6')
        swapped = copy.deepcopy(records)
        swapped[2]['bodies'] = [records[2]['bodies'][0].replace('mention://agent/agent-claude-fixer', 'mention://member/member1')]
        wrongs = [records[1:], [records[0], records[2]], records[::-1], swapped, records + [human],
                  records + [command('squad-review-next request issue-shop-1 comment-6 3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567')]]
    elif n == 31:
        human = post('[@Owner](mention://member/member1) コンフリクトを確認してください。', 'comment-6')
        swapped = copy.deepcopy(records)
        swapped[3]['bodies'] = [records[3]['bodies'][0].replace('mention://agent/agent-claude-fixer', 'mention://member/member1')]
        wrongs = [records[1:], [records[0], records[2], records[3]], [records[0], records[2], records[1], records[3]],
                  swapped, records + [human]]
    elif n == 32:
        wrongs = [[records[0], records[2]], [records[0], records[2], records[1]], records[:2],
                  records + [post('[@Owner](mention://member/member1) マージの判断をお願いします。', 'comment-5')],
                  records + [command('squad-review-next request issue-shop-1 comment-4 3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567')]]
    for wrong in wrongs:
        assert not passed(wrong), (n, wrong)
print('PASS leader-eval: 次の依頼の決定と使用率の待ちの 8 場面は、期待する記録と手順を外した記録を区別する')
PY_NEXT_SCENES

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
if [[ $* == *'このスクワッドには CI の見張り役がいません'* ]]; then
	if grep -q 'agent-ci-monitor' CLAUDE.md; then exit 5; fi
else
	grep -q 'agent-ci-monitor' CLAUDE.md || exit 5
fi
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

# keep-6 の最後の返答だけを変え、採点が合格と不合格に分かれることを確認する。
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
jq -e -s 'any(.[]; .scene == "keep-22" and .exit_code == 0)' "$all_out/runs.jsonl" >/dev/null
grep -q 'agent-ci-monitor' "$all_out/instructions/new/instructions.md"
if grep -q 'agent-ci-monitor' "$all_out/instructions/new/scenes/keep-22/instructions.md"; then
	echo "keep-22: CI の見張り役が指示に残っています" >&2; exit 1
fi
echo "PASS leader-eval: 44 場面すべてをスタブで流し、場面ごとに基準の結果が出て、見張り役のない場面では指示からも外す"

# 比較する前の指示にも、場面に合わせた役の構成を使う。
no_monitor_out="$test_dir/no-monitor"
PATH="$stub_bin:$PATH" bash "$eval_dir/run.sh" --baseline HEAD --scenes keep-22 --runs 1 --jobs 2 --out "$no_monitor_out" >"$test_dir/no-monitor.out" 2>"$test_dir/no-monitor.err" ||
	{ cat "$test_dir/no-monitor.err" >&2; exit 1; }
jq -e -s 'length == 2 and all(.[]; .exit_code == 0)' "$no_monitor_out/runs.jsonl" >/dev/null
for which in old new; do
	if grep -q 'agent-ci-monitor' "$no_monitor_out/runs/keep-22/$which-1/work/CLAUDE.md"; then
		echo "$which: 見張り役のない場面の作業場所に、その役が残っています" >&2; exit 1
	fi
done
echo "PASS leader-eval: 比較する両方の指示で、見張り役のない場面を流せる"
