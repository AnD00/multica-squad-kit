"""Exercise collect through cli-stub.py, with cases derived from real CLI fixtures."""

import copy
import json
import os
from pathlib import Path
import subprocess
import sys


ROOT, WORK = map(Path, sys.argv[1:])
FIXTURES = ROOT / "tests/fixtures/cli"
SCRIPT = ROOT / "scripts/metrics.py"


def sample(name):
    return json.loads((FIXTURES / (name + ".json")).read_text())[0]


def save(work, name, value):
    (work / name).write_text(json.dumps(value))


def make_case(name):
    work = WORK / name
    work.mkdir()
    prototype = sample("metrics-issues")
    issues = []
    for index, issue_id in enumerate(("synthetic-a", "synthetic-b")):
        row = copy.deepcopy(prototype["issues"][0])
        row.update(id=issue_id, identifier="EXAMPLE-" + issue_id[-1].upper(),
                   created_at=f"2026-01-01T00:0{2-index}:00Z", title="PRIVATE-ISSUE-TITLE")
        issues.append(row)
        page = copy.deepcopy(prototype)
        page.update(issues=[row], offset=index, limit=100, total=2, has_more=index == 0)
        save(work, f"issues-{index}.json", page)
    agents = sample("metrics-agents")
    agents[0].update(id="synthetic-agent", name="example-codex-fixer-member", instructions="PRIVATE-INSTRUCTIONS")
    unrelated = copy.deepcopy(agents[0])
    unrelated.update(id="unrelated-agent", name="PRIVATE-NAME person@example.invalid")
    agents.append(unrelated)
    save(work, "agents.json", agents)
    comments = sample("metrics-comments")
    for index, actor in enumerate(("member", "agent")):
        row = copy.deepcopy(next(row for row in comments if row["author_type"] == actor))
        row.update(id="synthetic-comment-" + str(index), issue_id="synthetic-a",
                   created_at=f"2026-01-01T00:0{4-index}:00Z",
                   content="PRIVATE-CONTENT [one](mention://member/human-one) "
                           "[again](mention://member/human-one) [two](mention://member/human-two)")
        if actor == "agent":
            row["author_id"] = "unrelated-agent"
        save(work, "comments-synthetic-a-" + ("first" if index == 0 else "next") + ".json", [row])
    (work / "comments-synthetic-a-first.json.stderr").write_text(
        (FIXTURES / "metrics-comments-cursor.txt").read_text())
    save(work, "comments-synthetic-b-first.json", [])
    timeline = sample("issue-timeline")
    changed = next(row for row in timeline if row["action"] == "status_changed")
    changed["details"].update({"from": "in_progress", "to": "in_review"})
    save(work, "timeline-synthetic-a.json", timeline)
    save(work, "timeline-synthetic-b.json", [])
    runs = sample("metrics-runs")
    completed = next(row for row in runs if "usage" in row)
    running = next(row for row in runs if "usage" not in row)
    for issue_id, row in (("synthetic-a", completed), ("synthetic-b", running)):
        row.update(issue_id=issue_id, agent_id="synthetic-agent")
        save(work, f"runs-{issue_id}.json", [row])
    return work


def run_collect(work):
    return subprocess.run([sys.executable, str(SCRIPT), "collect", "--project", "synthetic-project",
                           "--output", str(work / "snapshot.json")],
                          env={**os.environ, "METRICS_TEST_WORK": str(work)},
                          capture_output=True, text=True, timeout=120)


def read(work, name):
    return json.loads((work / name).read_text())


positive = make_case("positive")
result = run_collect(positive)
assert result.returncode == 0, result.stderr
snapshot = read(positive, "snapshot.json")
assert [row["id"] for row in snapshot["issues"]] == ["synthetic-b", "synthetic-a"]
assert len(snapshot["comments"]) == 2 and len(snapshot["transitions"]) == 1
assert snapshot["transitions"][0]["to_status"] == "in_review"
assert all(row["member_mentions"] == ["human-one", "human-two"] for row in snapshot["comments"])
assert snapshot["agents"] == [{"id": "synthetic-agent", "name": "example-codex-fixer-member"}]
assert all("content" not in row for row in snapshot["comments"])
assert "PRIVATE-" not in (positive / "snapshot.json").read_text()
assert sorted(len(row["usage"]) for row in snapshot["runs"]) == [0, 1]
calls = [json.loads(line) for line in (positive / "calls").read_text().splitlines()]
issues = [args for args in calls if args[:2] == ["issue", "list"]]
assert [args[args.index("--offset") + 1] for args in issues] == ["0", "1"]
comments = [args for args in calls if args[:3] == ["issue", "comment", "list"]]
assert len(comments) == 3
assert all("--full" in args and "--compact" not in args and "--summary" not in args for args in comments)
thread_pages = [args for args in comments if args[3] == "synthetic-a"]
assert len(thread_pages) == 2
assert "--before" not in thread_pages[0] and "--before-id" in thread_pages[1]
assert ["agent", "list", "--include-archived", "--output", "json"] in calls
assert all("--activity-only" in args for args in calls if args[:2] == ["issue", "timeline"])
assert snapshot["cli_version"] == read(FIXTURES, "METRICS-CAPTURE.json")["version"]
print("PASS collect: タスクとコメントの全ページを読み、本文・指示・題名を残さず ID だけを保存する")

result = subprocess.run([sys.executable, str(SCRIPT), "count", str(positive / "snapshot.json"),
    "--cutoff", "2027-01-01T00:00:00Z", "--truncate", "2027-01-01T00:00:00Z",
    "--human", "human-one", "--project-key", "example", "--member-key", "member",
    "--output", str(positive / "result")], capture_output=True, text=True)
assert result.returncode == 0, result.stderr
counted = read(positive / "result", "metrics.json")
assert counted["totals"]["issue_count"] == 2
assert counted["totals"]["human_comments"] == 1
assert counted["totals"]["human_calls"] == 1
assert counted["totals"]["run_count"] == 2
assert counted["totals"]["roles"]["codex-fixer"]["unconfirmed_runs"] == 1
print("PASS collect: 保存した使用量と未確認の実行を count の入力として使える")

unfiltered = copy.deepcopy(snapshot)
unfiltered["agents"] = [{key: row[key] for key in ("id", "name")}
                        for row in read(positive, "agents.json")]
save(positive, "unfiltered.json", unfiltered)
result = subprocess.run([sys.executable, str(SCRIPT), "count", str(positive / "unfiltered.json"),
    "--cutoff", "2027-01-01T00:00:00Z", "--truncate", "2027-01-01T00:00:00Z",
    "--human", "human-one", "--project-key", "example", "--member-key", "member",
    "--output", str(positive / "unfiltered-result")], capture_output=True, text=True)
assert result.returncode == 0, result.stderr
before = read(positive / "unfiltered-result", "metrics.json")
for key in ("issues", "totals", "per_issue", "comparison"):
    assert counted[key] == before[key], key
print("PASS collect: 実行から参照されないエージェントを除いても、タスクごとの指標・役ごとの使用量・合計・平均は変わらない")

first = snapshot
result = run_collect(positive)
assert result.returncode == 0, result.stderr
second = read(positive, "snapshot.json")
first.pop("collected_at")
second.pop("collected_at")
assert first == second
print("PASS collect: 読んだ時刻を除く値と配列の並びを固定する")


def failure(name, file=None, remove=None, warning=None, status=None, transform=None, previous=True):
    work = make_case(name)
    if remove:
        value = read(work, file)
        target = value
        for key in remove[:-1]:
            target = target[key]
        del target[remove[-1]]
        save(work, file, value)
        (work / "allow-missing-fields").touch()
    if warning:
        (work / (file + ".stderr")).write_text(warning)
    if status is not None:
        (work / (file + ".status")).write_text(str(status))
    if transform:
        value = read(work, file)
        transform(value)
        save(work, file, value)
    # A failed collection must preserve an earlier snapshot.
    if previous:
        (work / "snapshot.json").write_text("previous snapshot")
    result = run_collect(work)
    assert result.returncode != 0 and "エラー:" in result.stderr, (name, result)
    if previous:
        assert (work / "snapshot.json").read_text() == "previous snapshot"
    else:
        assert not (work / "snapshot.json").exists()
    assert not list(work.glob("snapshot.json.*"))


failure("truncated", "timeline-synthetic-a.json", warning="Warning: timeline truncated\n")
failure("truncated-new-output", "timeline-synthetic-a.json", warning="Warning: timeline truncated\n", previous=False)
failure("cli-error", "runs-synthetic-a.json", status=1)
failure("cursor-repeat", "comments-synthetic-a-next.json", warning=(FIXTURES / "metrics-comments-cursor.txt").read_text())
print("PASS collect: 切り詰めの警告・CLI の失敗・進まないページで止まり、既存の出力を保つ")
for name, file, path in (
    ("issue-field", "issues-0.json", ("issues", 0, "created_at")),
    ("page-field", "issues-0.json", ("has_more",)),
    ("comment-field", "comments-synthetic-a-first.json", (0, "content")),
    ("timeline-field", "timeline-synthetic-a.json", (0, "details", "to")),
    ("run-field", "runs-synthetic-a.json", (0, "agent_id")),
    ("usage-field", "runs-synthetic-a.json", (0, "usage", 0, "input_tokens")),
    ("agent-field", "agents.json", (0, "name")),
):
    failure(name, file, remove=path)
failure("empty-page", "issues-0.json", transform=lambda value: value.update(issues=[]))
print("PASS collect: 各読み取りの必須欄と使用量の欠け、次があるのに空のページで止まる")

empty = make_case("empty")
page = read(empty, "issues-0.json")
page.update(issues=[], total=0, has_more=False)
save(empty, "issues-0.json", page)
result = run_collect(empty)
assert result.returncode == 0, result.stderr
empty_snapshot = read(empty, "snapshot.json")
assert empty_snapshot["issues"] == []
assert empty_snapshot["agents"] == []
assert "PRIVATE-" not in (empty / "snapshot.json").read_text()
assert "person@example.invalid" not in (empty / "snapshot.json").read_text()
print("PASS collect: タスクが 0 件ならエージェントを保存せず、無関係な名前とメールも残らない")
