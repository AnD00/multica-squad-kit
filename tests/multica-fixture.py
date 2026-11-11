"""Multica の実物の見本からケースを作り、返す前に鍵を確かめる。

補助（tests/cli-stub.py）から関数 run を読み込む。スクリプトとしても使える。
"""

import json
import runpy
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
helper = runpy.run_path(str(root / "tests/cli-fixture-lib.py"))


def prototypes(entries, name):
    values = json.loads((root / f"tests/fixtures/cli/{name}.json").read_text())
    if entries[name]["shape"] == "array":
        return [item for response in values for item in response]
    return values


def keys_exist(original, candidate):
    if isinstance(candidate, dict):
        return isinstance(original, dict) and candidate.keys() <= original.keys() and all(
            keys_exist(original[key], value) for key, value in candidate.items())
    if isinstance(candidate, list):
        return isinstance(original, list) and all(
            not isinstance(value, (dict, list)) or any(keys_exist(before, value) for before in original)
            for value in candidate)
    return True


def validate(work, entries, name, value):
    entry = entries[name]
    allow_missing = (work / "allow-missing-fields").exists()
    for item in value if entry["shape"] == "array" else [value]:
        for original in prototypes(entries, name):
            try:
                assert keys_exist(original, item)
                if entry["shape"] == "array":
                    helper["assert_case_keys"](original, item, entry["items"]["fields"], allow_missing)
                else:
                    helper["assert_fixture_response"](original, item, entry, allow_missing)
                break
            except AssertionError:
                pass
        else:
            raise AssertionError(f"見本とケースの鍵が違います: {name}")


def run(work, action, name, file=None):
    work = Path(work)
    entries = json.loads((work / "contracts.json").read_text())["entries"]
    if action == "base":
        values = prototypes(entries, name)
        value = (next(value for value in values if "repository" in value["metadata"] and "pr_url" in value["metadata"])
                 if name == "issue-get" else values[0])
    else:
        text = Path(file).read_text()
        try:
            value = json.loads(text)
        except json.JSONDecodeError:
            print(text)
            return
        validate(work, entries, name, value)
    print(json.dumps(value, ensure_ascii=False))


if __name__ == "__main__":
    run(sys.argv[1], *sys.argv[2:])
