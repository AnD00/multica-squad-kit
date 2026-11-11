"""pr-watch のスタブ。実物から作ったケースの鍵を、返す前に確かめる。

補助（tests/cli-stub.py）から関数 run を読み込む。スクリプトとしても使える。
"""

import json
import os
import runpy
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
helper = runpy.run_path(str(root / "tests/cli-fixture-lib.py"))


def entry(work, name):
    return json.loads((work / "contracts.json").read_text())["entries"][name]


def prototypes(work, name):
    values = json.loads((root / f"tests/fixtures/cli/{name}.json").read_text())
    if entry(work, name)["shape"] == "array":
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


def validate(work, name, value):
    schema = entry(work, name)
    allow_missing = (work / "allow-missing-fields").exists()
    for item in value if schema["shape"] == "array" else [value]:
        for original in prototypes(work, name):
            try:
                candidate = item
                if name == "gh-pr-checks":
                    # StatusContext は約束で「見本なし」。その形だけは宣言済みの鍵で確かめる。
                    checks = item.get("statusCheckRollup", [])
                    fields = schema["items"]["fields"]
                    for check in checks:
                        if check.get("__typename") == "StatusContext":
                            allowed = {field["path"] for field in fields if
                                       field["path"] == "__typename" or
                                       field.get("when") == '.__typename == "StatusContext"'}
                            assert check.keys() <= allowed, "見本なしの形に未宣言の鍵があります"
                    candidate = dict(item)
                    if "statusCheckRollup" in item:
                        candidate["statusCheckRollup"] = [check for check in checks
                                                         if check.get("__typename") != "StatusContext"]
                assert keys_exist(original, candidate), "見本にない鍵があります"
                if schema["shape"] == "array":
                    helper["assert_case_keys"](original, candidate, schema["items"]["fields"], allow_missing)
                else:
                    helper["assert_fixture_response"](original, candidate, schema, allow_missing)
                break
            except AssertionError:
                pass
        else:
            raise AssertionError(f"見本とケースの鍵が違います: {name}")


def run(work, action, name, rest=None):
    work = Path(work)
    if action == "base":
        selector = rest
        value = next(value for value in prototypes(work, name) if selector is None or
                     value.get("kind") == selector or value.get("author_type") == selector)
    else:
        text = Path(rest).read_text()
        try:
            value = json.loads(text)
        except json.JSONDecodeError:
            print(text)
            return
        validate(work, name, value)
    print(json.dumps(value, ensure_ascii=False))


if __name__ == "__main__":
    run(os.environ["PR_WATCH_TEST_DIR"], *sys.argv[1:])
