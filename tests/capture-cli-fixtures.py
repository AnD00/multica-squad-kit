"""実物の CLI 応答を、欄の約束が求める形ごとに選んで匿名化する。

各 JSON ファイルは CLI 応答の配列。配列を返す CLI なら二重配列になる。
書き込みを自動では実行しない。応答は --write-samples のディレクトリに
<読み取りの名前>.json として用意する。生の応答は公開先に保存しない。
"""

import argparse
import copy
import json
import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]



def command_json(command):
    result = subprocess.run(command, check=True, capture_output=True, text=True)
    return json.loads(result.stdout)


def contracts():
    return command_json([
        "bash", "-c", 'source "$1"; squad_cli_contracts', "bash",
        str(ROOT / "common/monitor/squad-cli-lib"),
    ])["entries"]


def target_items(response, entry):
    if entry["shape"] == "array":
        if not isinstance(response, list):
            raise ValueError("配列でない応答です")
        return response
    if not isinstance(response, dict):
        raise ValueError("オブジェクトでない応答です")
    if "items" not in entry:
        return [response]
    items = response
    for key in entry["items"]["path"]:
        items = items[key]
    if not isinstance(items, list):
        raise ValueError("items.path の値が配列ではありません")
    return items


def matches(value, expression):
    result = subprocess.run(
        ["jq", "-e", expression], input=json.dumps(value),
        capture_output=True, text=True,
    )
    if result.returncode not in (0, 1, 4):
        raise ValueError(f"見本の条件が不正です: {expression}")
    return result.returncode == 0


def select_samples(responses, entry):
    """条件に合う実物を選ぶ。鍵を追加・削除して形を作らない。"""
    selected = []
    coverage = []
    missing = []
    for sample in entry["samples"]:
        found = None
        count = 0
        for response in responses:
            for item in target_items(response, entry):
                if matches(item, sample["where"]):
                    count += 1
                    if found is None:
                        found = item if entry["shape"] == "array" else response
        record = {"name": sample["name"], "count": count}
        if found is None:
            if "unavailable" in sample:
                record["unavailable"] = sample["unavailable"]
            else:
                missing.append(sample["name"])
        elif found not in selected:
            selected.append(copy.deepcopy(found))
        coverage.append(record)
    if entry["shape"] == "array":
        selected = [selected] if selected else []
    return selected, coverage, missing


def redact(value, reading="", path=(), person=False):
    """指定された個人の値・自由文・作業パスだけを、鍵・型を保って置き換える。"""
    if isinstance(value, dict):
        person = person or "email" in value or "user_id" in value
        return {k: redact(v, reading, path + (k,), person) for k, v in value.items()}
    if isinstance(value, list):
        return [redact(item, reading, path, person) for item in value]
    if not isinstance(value, str) or value == "":
        return value
    key = path[-1] if path else ""
    if key == "email":
        return "fixture@example.invalid"
    if key in {"avatar_url", "avatarUrl"}:
        return "https://example.invalid/avatar"
    if (key == "name" and person) or key in {
        "created_by_name", "filter_actor_name", "member_name", "owner_name",
    }:
        return "Fixture Person"
    if key in {"work_dir", "relative_work_dir", "working_dir", "cwd"}:
        return "fixture/workdir"
    if key in {
        "content", "description", "instructions", "instruction", "output", "summary",
        "trigger_summary", "handoff_note", "error", "title", "filename", "conversation_starters",
    } or any(part in {"mcp_config", "custom_args", "source_context"} for part in path):
        return "fixture"
    # 自由文以外でも、値がメールアドレスなら個人の値として置き換える。
    return re.sub(r"[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}", "fixture@example.invalid", value)


def capture(issue_ids, entries, write_samples):
    responses = {name: [] for name in entries}
    issues = [command_json(["multica", "issue", "get", issue, "--output", "json"])
              for issue in issue_ids]
    agents = set()
    for name, entry in entries.items():
        if entry.get("capture") == "response-file":
            if write_samples is not None:
                path = write_samples / f"{name}.json"
                if path.exists():
                    responses[name].append(json.loads(path.read_text()))
            continue
        tokens = entry["command"]
        if "{agent}" in tokens:
            contexts = [{"agent": agent} for agent in sorted(agents)]
        elif "{pr}" in tokens:
            urls = {issue["metadata"]["pr_url"] for issue in issues
                    if issue["metadata"].get("pr_url")}
            contexts = [{"pr": url} for url in sorted(urls)]
        elif "{issue}" in tokens or "{query}" in tokens:
            contexts = [{"issue": issue["id"], "query": issue["identifier"]}
                        for issue in issues]
        else:
            contexts = [{}]
        for context in contexts:
            if name == "issue-get":
                response = next(issue for issue in issues if issue["id"] == context["issue"])
            else:
                response = command_json([token.format(**context) for token in tokens])
            responses[name].append(response)
            if name == "issue-runs":
                agents.update(run["agent_id"] for run in response if run.get("agent_id"))
    return responses


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("issues", nargs="+")
    parser.add_argument("--write-samples", type=Path)
    parser.add_argument("--output-dir", type=Path, default=ROOT / "tests/fixtures/cli")
    args = parser.parse_args()
    entries = contracts()
    responses = capture(args.issues, entries, args.write_samples)
    fixtures = {}
    coverage = {}
    missing = []
    for name, entry in entries.items():
        selected, coverage[name], absent = select_samples(responses[name], entry)
        fixtures[name] = redact(selected, name)
        missing.extend(f"{name}: {shape}" for shape in absent)
        for record in coverage[name]:
            if "unavailable" in record:
                print(f"見本なし: {name} の {record['name']}（0 件）: {record['unavailable']}")
    if missing:
        for shape in missing:
            print(f"見本の形がありません: {shape}", file=sys.stderr)
        return 1
    versions = []
    for command in (["multica", "version"], ["gh", "--version"]):
        result = subprocess.run(command, check=True, capture_output=True, text=True)
        versions.append(result.stdout.splitlines()[0])
    args.output_dir.mkdir(parents=True, exist_ok=True)
    for name, fixture in fixtures.items():
        (args.output_dir / f"{name}.json").write_text(
            json.dumps(fixture, ensure_ascii=False, indent=2) + "\n")
    (args.output_dir / "VERSION").write_text("\n".join(versions) + "\n")
    (args.output_dir / "CAPTURE.json").write_text(
        json.dumps(coverage, ensure_ascii=False, indent=2) + "\n")
    count = sum(bool(value) for value in fixtures.values())
    print(f"見本の出力: {len(fixtures)} 項目（採取 {count}、見本なし {len(fixtures) - count}）")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        # CLI の標準出力・標準エラーには自由文が入り得るので、そのまま出さない。
        print(f"見本の採取に失敗しました: {type(error).__name__}", file=sys.stderr)
        sys.exit(1)
