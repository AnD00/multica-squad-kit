"""review-wait の CLI stub。実物の見本を元にし、出力前に鍵を検査する。"""

import json
import os
import runpy
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
fixtures = root / "tests/fixtures/cli"
work = Path(os.environ["REVIEW_WAIT_TEST_DIR"])
helper = runpy.run_path(str(root / "tests/cli-fixture-lib.py"))


def prototypes(name):
    values = json.loads((fixtures / f"{name}.json").read_text())
    if entry(name)["shape"] == "array":
        return [item for response in values for item in response]
    return values


def entry(name):
    return json.loads((work / "contracts.json").read_text())["entries"][name]


def keys_exist(original, candidate):
    if isinstance(candidate, dict):
        return isinstance(original, dict) and candidate.keys() <= original.keys() and all(
            keys_exist(original[key], value) for key, value in candidate.items())
    if isinstance(candidate, list):
        return isinstance(original, list) and all(
            not isinstance(value, (dict, list)) or any(keys_exist(before, value) for before in original)
            for value in candidate)
    return True


def emit(name, value):
    schema = entry(name)
    allow_missing = (work / "allow-missing-fields").exists()
    fields = schema["items"]["fields"] if schema["shape"] == "array" else schema["fields"]
    for item in value if schema["shape"] == "array" else [value]:
        for original in prototypes(name):
            if not keys_exist(original, item):
                continue
            try:
                helper["assert_case_keys"](original, item, fields, allow_missing)
                break
            except AssertionError:
                pass
        else:
            raise AssertionError(f"見本とケースの鍵が違います: {name}")
    print(json.dumps(value, ensure_ascii=False))


if __name__ == "__main__":
    action, name = sys.argv[1:3]
    if action == "base":
        values = prototypes(name)
        selector = sys.argv[3] if len(sys.argv) > 3 else None
        value = next(value for value in values if selector is None or
                     value.get("kind") == selector or value.get("author_type") == selector)
        print(json.dumps(value, ensure_ascii=False))
    elif action == "emit":
        text = Path(sys.argv[3]).read_text()
        try:
            value = json.loads(text)
        except json.JSONDecodeError:
            # 故障ケースの壊れた JSON は、そのまま本体へ渡す。
            print(text)
        else:
            emit(name, value)
    elif action == "posted":
        value = prototypes(name)[0]
        value["id"] = sys.argv[3]
        override = work / f"{name}-response.json"
        if override.exists():
            value = json.loads(override.read_text())
        emit(name, value)
