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
UUID = re.compile(r'[\da-f]{8}-[\da-f]{4}-[\da-f]{4}-[\da-f]{4}-[\da-f]{12}', re.I)


def uuid_aliases(value):
    """全見本で共通の対応表を作り、ID の同一性と文字列の比較順を保つ。"""
    ids = set()

    def collect(item):
        if isinstance(item, dict):
            for child in item.values():
                collect(child)
        elif isinstance(item, list):
            for child in item:
                collect(child)
        elif isinstance(item, str):
            ids.update(UUID.findall(item))

    collect(value)
    width = max(6, len(str(len(ids))))
    return {value: f'fixture-id-{index:0{width}d}'
            for index, value in enumerate(sorted(ids), 1)}


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
            items = [response] if sample.get("scope") == "response" else target_items(response, entry)
            for item in items:
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


def redact(value, reading="", path=(), person=False, id_aliases=None):
    """個人の値・自由文・作業パス・UUID を、鍵・型を保って置き換える。"""
    if id_aliases is None:
        id_aliases = uuid_aliases(value)
    if isinstance(value, dict):
        person = person or "email" in value or "user_id" in value
        return {k: redact(v, reading, path + (k,), person, id_aliases)
                for k, v in value.items()}
    if isinstance(value, list):
        return [redact(item, reading, path, person, id_aliases) for item in value]
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
    value = re.sub(r"[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}", "fixture@example.invalid", value)
    return UUID.sub(lambda match: id_aliases[match.group()], value)


def capture(issue_ids, entries, write_samples, read_samples=None):
    responses = {name: [] for name in entries}
    issues = [command_json(["multica", "issue", "get", issue, "--output", "json"])
              for issue in issue_ids]
    agents = set()
    squads = set()
    for name, entry in entries.items():
        if entry.get("capture") == "external":
            if read_samples is not None:
                path = read_samples / f"{name}.json"
                if path.exists():
                    responses[name].extend(json.loads(path.read_text()))
            continue
        if entry.get("capture") == "response-file":
            if write_samples is not None:
                path = write_samples / f"{name}.json"
                if path.exists():
                    responses[name].append(json.loads(path.read_text()))
            continue
        tokens = entry["command"]
        if "{agent}" in tokens:
            contexts = [{"agent": agent} for agent in sorted(agents)]
        elif "{squad}" in tokens:
            contexts = [{"squad": squad} for squad in sorted(squads)]
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
            elif name == "squad-list":
                squads.update(squad["id"] for squad in response)
    return responses


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("issues", nargs="+")
    parser.add_argument("--write-samples", type=Path)
    parser.add_argument("--read-samples", type=Path)
    parser.add_argument("--output-dir", type=Path, default=ROOT / "tests/fixtures/cli")
    args = parser.parse_args()
    entries = contracts()
    responses = capture(args.issues, entries, args.write_samples, args.read_samples)
    fixtures = {}
    coverage = {}
    missing = []
    for name, entry in entries.items():
        selected, coverage[name], absent = select_samples(responses[name], entry)
        fixtures[name] = selected
        missing.extend(f"{name}: {shape}" for shape in absent)
        for record in coverage[name]:
            if "unavailable" in record:
                print(f"見本なし: {name} の {record['name']}（0 件）: {record['unavailable']}")
    if missing:
        for shape in missing:
            print(f"見本の形がありません: {shape}", file=sys.stderr)
        return 1
    aliases = uuid_aliases(fixtures)
    fixtures = {name: redact(value, name, id_aliases=aliases)
                for name, value in fixtures.items()}
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
