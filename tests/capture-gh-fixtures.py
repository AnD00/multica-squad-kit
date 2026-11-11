"""公開 GitHub の読み取りを、約束で検証して見本へ取り込む。書き込みは呼ばない。"""

import argparse
import json
import os
import runpy
import subprocess
from pathlib import Path

root = Path(__file__).resolve().parents[1]
capture = runpy.run_path(str(root / "tests/capture-cli-fixtures.py"))


def read_only(command):
    if command[:2] == ["gh", "api"] and len(command) >= 3 and not command[2].startswith("-"):
        remaining = command[3:]
        while remaining:
            flag = remaining.pop(0)
            if flag == "--paginate":
                continue
            if flag == "--jq" and remaining and remaining.pop(0) == 'with_entries(select(.key == "login"))':
                continue
            return False
        return True
    return (len(command) == 8 and command[3].isdigit() and command[:3] == ["gh", "pr", "view"] and
            command[4] == "--repo" and command[6] == "--json")


def redact(value, aliases, path=()):
    if isinstance(value, dict):
        return {key: redact(child, aliases, path + (key,)) for key, child in value.items()}
    if isinstance(value, list):
        return [redact(child, aliases, path) for child in value]
    if not isinstance(value, str):
        return value
    if path[-1:] == ("login",):
        return value if value in ("dependabot[bot]", "app/dependabot") else "fixture-user"
    if path[-1:] and path[-1] in ("body", "message", "patch", "name", "email", "description", "title", "filename", "text", "body_text", "body_html", "payload", "signature"):
        return "fixture" if value else value
    if value.startswith(("https://", "http://")):
        return "https://example.invalid/fixture"
    return capture["redact"](value, path=path, id_aliases=aliases)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sources", type=Path, required=True)
    parser.add_argument("--response-dir", type=Path)
    parser.add_argument("--output-dir", type=Path, default=root / "tests/fixtures/cli")
    args = parser.parse_args()
    commands = json.loads(args.sources.read_text())
    entries = capture["contracts"]()
    version = subprocess.check_output(["gh", "--version"], text=True).splitlines()[0]
    selected, coverage = {}, {}
    for name, entry in entries.items():
        if entry.get("capture") != "external":
            continue
        command = commands[name]
        if not read_only(command):
            raise ValueError("採取は gh の読み取りだけです")
        raw = ((args.response_dir / f"{name}.raw").read_text() if args.response_dir else
               subprocess.check_output(command, text=True))
        result = subprocess.run(["bash", "-c", 'source "$1"; squad_cli_normalize "$2" "$3"',
                                 "bash", str(root / "common/monitor/squad-cli-lib"), name, version],
                                input=raw, capture_output=True, text=True,
                                env=dict(os.environ, SQUAD_CLI_TEST_KEEP_FIELDS="1"))
        if result.returncode:
            raise ValueError(f"約束と合いません: {name}: {result.stderr}")
        selected[name], coverage[name], missing = capture["select_samples"]([json.loads(result.stdout)], entry)
        if missing:
            raise ValueError(f"見本の形がありません: {name}: {missing}")
        for record in coverage[name]:
            if "unavailable" in record:
                print(f"見本なし: {name} の {record['name']}: {record['unavailable']}")
    aliases = capture["uuid_aliases"](selected)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    for name, value in selected.items():
        (args.output_dir / f"{name}.json").write_text(json.dumps(redact(value, aliases), ensure_ascii=False, indent=2) + "\n")
    (args.output_dir / "GH-CAPTURE.json").write_text(json.dumps({"version": version, "sources": commands,
                                                              "coverage": coverage}, ensure_ascii=False, indent=2) + "\n")
    print(f"PASS GitHub 見本: {len(selected)} 項目")


if __name__ == "__main__":
    main()
