"""Count procedure traces using synthetic snapshots, with no CLI or repository reads."""

import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys


ROOT, WORK = map(Path, sys.argv[1:])
SCRIPT = ROOT / "scripts/metrics.py"
FIXTURES = ROOT / "tests/fixtures/metrics"
DEFINITIONS = FIXTURES / "trace-procedures.json"
SNAPSHOT = FIXTURES / "trace-snapshot.json"


def invoke(name, snapshot=SNAPSHOT, definitions=DEFINITIONS):
    return subprocess.run([sys.executable, str(SCRIPT), "traces", str(snapshot),
        "--traces", str(definitions), "--project-key", "foo-bar", "--member-key", "m-n",
        "--output", str(WORK / name)], capture_output=True, text=True, timeout=30)


def save(name, value):
    path = WORK / name
    path.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
    return path


assert invoke("trace-first").returncode == 0
assert invoke("trace-second").returncode == 0
for name in ("traces.json", "traces.md"):
    assert (WORK / "trace-first" / name).read_bytes() == (WORK / "trace-second" / name).read_bytes()
result = json.loads((WORK / "trace-first/traces.json").read_text())
assert result["input"]["snapshot_sha256"] == hashlib.sha256(SNAPSHOT.read_bytes()).hexdigest()
assert result["input"]["trace_definitions_sha256"] == hashlib.sha256(DEFINITIONS.read_bytes()).hexdigest()
rows = {row["id"]: row for row in result["procedures"]}
assert list(rows) == sorted(rows)
assert [row["id"] for row in result["issues"]] == [f"task-{i:02}" for i in reversed(range(19))] + ["a-tie"]
assert (rows["tie-in"]["count"], rows["older-out"]["count"], rows["future-out"]["count"]) == (1, 0, 0)
print("PASS traces: 同じ入力から JSON・Markdown が一致し、新しい 20 件を同時刻の ID 順も含めて選ぶ")

for name, expected in (("comment-hit", 2), ("transition-hit", 2), ("run-hit", 1), ("other-run", 1)):
    assert (rows[name]["count"], rows[name]["judgment"]) == (expected, "効いた"), rows[name]
assert (rows["candidate"]["count"], rows["candidate"]["judgment"]) == (0, "削る候補")
for name, protection, count in (("guard-secrets", "secrets", 0), ("guard-scope", "write_scope", None),
                                 ("guard-gate", "gate", 1), ("guard-irreversible", "irreversible", 0)):
    assert (rows[name]["count"], rows[name]["judgment"], rows[name]["protection"]) == (count, "守る手順で残す", protection)
assert (rows["undecidable"]["count"], rows["undecidable"]["judgment"]) == (None, "判定できない")
assert (rows["explanation"]["count"], rows["explanation"]["judgment"]) == (None, "手順でない")
md = (WORK / "trace-first/traces.md").read_text()
assert "| 2 | 効いた |" in md and "守る手順で残す" in md and "判定できない" in md and "手順でない" in md
assert all(row["file"] == "common/agents/example.md" and row["section"] and row["marker"] for row in rows.values())
print("PASS traces: コメント・状態の前後・実行の役と状態を数え、保護の 4 分類と判定できない手順・説明を分ける")

snapshot = json.loads(SNAPSHOT.read_text())
reordered = copy.deepcopy(snapshot)
for group in ("issues", "comments", "transitions", "runs", "agents"):
    reordered[group].reverse()
path = save("trace-reordered.json", reordered)
assert invoke("trace-reordered", path).returncode == 0
changed = json.loads((WORK / "trace-reordered/traces.json").read_text())
assert changed["issues"] == result["issues"] and changed["procedures"] == result["procedures"]
small = copy.deepcopy(snapshot)
small["issues"] = [row for row in small["issues"] if row["id"] == "task-00"]
for group in ("comments", "transitions", "runs"):
    small[group] = [row for row in small[group] if row["issue_id"] == "task-00"]
assert invoke("trace-small", save("trace-small.json", small)).returncode == 0
assert len(json.loads((WORK / "trace-small/traces.json").read_text())["issues"]) == 1
print("PASS traces: 記録の配列の順に依存せず、20 件未満でも存在するタスクだけを使う")


def rejected(name, value, definitions=DEFINITIONS):
    path = save(name + ".json", value)
    output = WORK / name
    output.mkdir()
    for filename in ("traces.json", "traces.md"):
        (output / filename).write_text("previous output")
    failed = invoke(name, path, definitions)
    assert failed.returncode != 0 and "エラー:" in failed.stderr, (name, failed)
    for filename in ("traces.json", "traces.md"):
        assert (output / filename).read_text() == "previous output"


missing = copy.deepcopy(snapshot)
del missing["trace_definitions_sha256"]
rejected("trace-missing-hash", missing)
different = copy.deepcopy(snapshot)
different["trace_definitions_sha256"] = "0" * 64
rejected("trace-wrong-hash", different)
for name, matches in (("trace-unknown-id", ["unknown"]), ("trace-duplicate-id", ["comment-hit", "comment-hit"]),
                      ("trace-wrong-type", "comment-hit")):
    invalid = copy.deepcopy(snapshot)
    invalid["comments"][0]["trace_matches"] = matches
    rejected(name, invalid)
missing = copy.deepcopy(snapshot)
del missing["comments"][0]["trace_matches"]
rejected("trace-missing-matches", missing)
definitions = json.loads(DEFINITIONS.read_text())
definitions["procedures"][0]["protection"] = "unknown"
path = save("trace-invalid-definition.json", definitions)
invalid = copy.deepcopy(snapshot)
invalid["trace_definitions_sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
rejected("trace-invalid-protection", invalid, path)
print("PASS traces: 定義の SHA-256 不一致・一致 ID の欠落や不正・不明な保護の分類で止まり、出力を保つ")
