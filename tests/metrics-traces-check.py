"""Count procedure traces with synthetic snapshots and a local synthetic Git history."""

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
REPOSITORY = WORK / "trace-source"
REPOSITORY.mkdir()


def git(*arguments):
    return subprocess.run(["git", "-C", str(REPOSITORY), *arguments], check=True,
                          capture_output=True, text=True).stdout.strip()


def source(name, content):
    path = REPOSITORY / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def commit(subject):
    git("add", ".")
    git("-c", "user.name=Synthetic", "-c", "user.email=synthetic@example.invalid", "commit", "-qm", subject)
    return git("rev-parse", "HEAD")


git("init", "-q")
definition_rows = json.loads(DEFINITIONS.read_text())["procedures"]
agent_rows = [row for row in definition_rows if row["file"] == "common/agents/example.md"]
first_markers = [row["marker"] for row in agent_rows if row["id"] != "candidate"]
agent_content = "# 合成の手順\n\n" + "\n".join(first_markers) + "\n"
source("common/agents/example.md", agent_content)
source("common/skills/squad-handoff/SKILL.md", "---\nname: synthetic\ndescription: synthetic\n---\n# 親\n親の説明。\n## 子\n子の説明。\n```text\n# コード内の見出し\n```\n")
source("common/skills/squad-handoff/references/example.md", "説明\n====\n参照の説明。\n")
source("common/squad.md", "# 説明\nスクワッドの説明。\n")
source("common/autopilots.md", "# 説明\nオートパイロットの説明。\n")
source("common/agents/FORMAT", "# 範囲外\n")
source("skeleton/example.md", "# 範囲外\n")
INITIAL = commit("Add synthetic procedures (#1)")
agent_content += "合成の目印 candidate\n"
source("common/agents/example.md", agent_content)
REVISION = commit("Add candidate procedure (#2)")
source("common/agents/example.md", agent_content + "# 後から足した見出し\n未定義の説明。\n")
commit("Add a heading after the review revision (#3)")
# Neither newer commits nor uncommitted contents may affect a fixed review revision.
source("common/agents/example.md", "# 作業ツリーだけの見出し\n")


def invoke(name, snapshot=SNAPSHOT, definitions=DEFINITIONS, revision=REVISION):
    return subprocess.run([sys.executable, str(SCRIPT), "traces", str(snapshot),
        "--traces", str(definitions), "--project-key", "foo-bar", "--member-key", "m-n",
        "--repository", str(REPOSITORY), "--revision", revision,
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
assert result["input"]["revision"] == REVISION
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
assert all(row["file"] and row["section"] and row["marker"] for row in rows.values())
assert rows["candidate"]["introduced_commit"] == {"sha": REVISION, "subject": "Add candidate procedure (#2)"}
for row in rows.values():
    origin = row["introduced_commit"]
    if row["judgment"] in ("削る候補", "守る手順で残す", "判定できない") and row["id"] != "candidate":
        assert origin == {"sha": INITIAL, "subject": "Add synthetic procedures (#1)"}, row
    elif row["judgment"] in ("効いた", "手順でない"):
        assert origin is None
assert REVISION in md and "Add candidate procedure (#2)" in md
print("PASS traces: コメント・状態の前後・実行の役と状態を数え、保護の 4 分類と判定できない手順・説明を分ける")
print("PASS traces: 指定したコミットだけで見出しと目印を確認し、最初に足したコミットと件名を一覧に添える")

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


def rejected(name, value, definitions=DEFINITIONS, revision=REVISION, expected="エラー:"):
    path = save(name + ".json", value)
    output = WORK / name
    output.mkdir()
    for filename in ("traces.json", "traces.md"):
        (output / filename).write_text("previous output")
    failed = invoke(name, path, definitions, revision)
    assert failed.returncode != 0 and "エラー:" in failed.stderr, (name, failed)
    assert expected in failed.stderr, (name, failed.stderr)
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


def rejected_definition(name, mutate, expected):
    definitions = json.loads(DEFINITIONS.read_text())
    mutate(definitions)
    path = save(name + "-definitions.json", definitions)
    value = copy.deepcopy(snapshot)
    value["trace_definitions_sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
    rejected(name, value, path, expected=expected)


rejected_definition("trace-uncovered-parent", lambda value: value.update(procedures=[
    row for row in value["procedures"] if row["id"] != "skill-parent"]), "覆わない見出し")
rejected_definition("trace-uncovered-file", lambda value: value.update(procedures=[
    row for row in value["procedures"] if row["id"] != "skill-reference"]), "覆わない見出し")
rejected_definition("trace-absent-marker", lambda value: value["procedures"][0].update(marker="存在しない目印"), "ちょうど 1 回")
rejected_definition("trace-absent-section", lambda value: value["procedures"][0].update(section="存在しない節"), "一意に決まりません")
rejected_definition("trace-outside-file", lambda value: value["procedures"][0].update(file="skeleton/example.md"), "範囲のファイル")
rejected("trace-uncovered-new-heading", snapshot, revision=git("rev-parse", "HEAD"), expected="覆わない見出し")
source("common/agents/example.md", agent_content + "合成の目印 candidate\n")
duplicate = commit("Duplicate a marker (#4)")
rejected("trace-duplicate-marker", snapshot, revision=duplicate, expected="ちょうど 1 回")
source("common/agents/example.md", agent_content.replace("合成の目印 candidate\n", "")
       + "# 別の節\n合成の目印 candidate\n")
outside = commit("Move a marker to another section (#5)")
rejected("trace-marker-outside-section", snapshot, revision=outside, expected="ちょうど 1 回")
source("common/agents/example.md", agent_content + "# 合成の手順\n別の説明。\n")
ambiguous = commit("Repeat a heading (#6)")
rejected("trace-ambiguous-section", snapshot, revision=ambiguous, expected="一意に決まりません")
print("PASS traces: 覆わない親見出し・ファイル、重なる目印、別の節の目印、曖昧な節、範囲外の指定で止まる")
