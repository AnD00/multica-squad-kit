"""GitHub の見本にケースの値を重ねる。未宣言の鍵を足さず、省略可能な鍵は補わない。"""

import copy
import json
import runpy
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
work = Path(sys.argv[1])
action, name = sys.argv[2:4]
entry = json.loads((work / "contracts.json").read_text())["entries"][name]
helper = runpy.run_path(str(root / "tests/cli-fixture-lib.py"))
responses = json.loads((root / f"tests/fixtures/cli/{name}.json").read_text())

# 「見本なし」とした形だけ、公式 REST API の Status の宣言済みの欄を使う。
if not responses and name == "gh-statuses" and any("unavailable" in item for item in entry["samples"]):
    responses = [[{"id": 1, "context": "fixture", "state": "success"}]]


def overlay(before, after, schema, path=()):
    if isinstance(after, dict):
        if not isinstance(before, dict) or not after.keys() <= before.keys():
            raise AssertionError(f"見本にない鍵です: {name}: {path}")
        result = copy.deepcopy(before)
        for field in schema.get("fields", []):
            parts = tuple(field["path"].split("."))
            if field["class"] == "optional" and parts[:-1] == path and parts[-1] not in after:
                result.pop(parts[-1], None)
        for key, value in after.items():
            result[key] = overlay(before[key], value, schema, path + (key,))
        return result
    if isinstance(after, list):
        child = schema.get("items")
        if not isinstance(before, list):
            raise AssertionError(f"見本の配列ではありません: {name}")
        item_schema = child if child and tuple(child["path"]) == path else schema
        result = []
        for value in after:
            for original in before:
                try:
                    result.append(overlay(original, value, item_schema, ()))
                    break
                except AssertionError:
                    pass
            else:
                raise AssertionError(f"見本に合う要素がありません: {name}: {path}")
        return result
    return after


if action == "base":
    value = responses[0][0] if entry["shape"] == "array" else responses[0]
    print(json.dumps(value, ensure_ascii=False))
else:
    text = Path(sys.argv[4]).read_text().strip()
    decoder = json.JSONDecoder()
    while text:
        try:
            value, end = decoder.raw_decode(text)
        except json.JSONDecodeError:
            print(text)
            break
        if action != "raw":
            original = responses[0]
            # 配列の根にも items の約束を渡す。
            schema = entry if entry["shape"] != "array" else {"items": entry["items"]}
            value = overlay(original, value, schema)
            helper["assert_fixture_response"](original, value, entry)
        print(json.dumps(value, ensure_ascii=False))
        text = text[end:].lstrip()
