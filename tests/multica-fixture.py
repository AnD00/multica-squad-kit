"""Multica の実物の見本からケースを作り、返す前に鍵を確かめる。"""

import json
import runpy
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
work = Path(sys.argv[1])
helper = runpy.run_path(str(root / "tests/cli-fixture-lib.py"))
entries = json.loads((work / "contracts.json").read_text())["entries"]


def prototypes(name):
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


def validate(name, value):
    entry = entries[name]
    for item in value if entry["shape"] == "array" else [value]:
        for original in prototypes(name):
            try:
                assert keys_exist(original, item)
                if entry["shape"] == "array":
                    helper["assert_case_keys"](original, item, entry["items"]["fields"],
                                               (work / "allow-missing-fields").exists())
                else:
                    helper["assert_fixture_response"](original, item, entry,
                                                       (work / "allow-missing-fields").exists())
                break
            except AssertionError:
                pass
        else:
            raise AssertionError(f"見本とケースの鍵が違います: {name}")


action, name = sys.argv[2:4]
if action == "base":
    values = prototypes(name)
    value = (next(value for value in values if "repository" in value["metadata"] and "pr_url" in value["metadata"])
             if name == "issue-get" else values[0])
else:
    text = Path(sys.argv[4]).read_text()
    try:
        value = json.loads(text)
    except json.JSONDecodeError:
        print(text)
        sys.exit(0)
    validate(name, value)
print(json.dumps(value, ensure_ascii=False))
