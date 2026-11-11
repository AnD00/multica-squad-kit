"""使用量の実物の見本に、ケースの値だけを重ねて CLI の応答を作る。"""

import copy
import json
import runpy
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
name, path = sys.argv[1:3]
fixtures = root / "tests/fixtures/cli"
original = json.loads((fixtures / f"{name}.json").read_text())[0]


def overlay(before, after, location=()):
    if isinstance(before, dict) and isinstance(after, dict):
        if location == ("rateLimitsByLimitId",):
            # 枠の名前は出力の値で決まる。中の欄は、実物の枠からのみ作る。
            prototype = next(iter(before.values()))
            return {key: overlay(prototype, value, location + (key,)) for key, value in after.items()}
        if not after.keys() <= before.keys():
            raise AssertionError(f"見本にない鍵です: {name}: {location}")
        result = copy.deepcopy(before)
        for key, value in after.items():
            prior = before[key]
            if key == "secondary" and prior is None and isinstance(value, dict):
                # null 以外の secondary は「見本なし」。同じ型の primary を元にする。
                prior = before["primary"]
            result[key] = overlay(prior, value, location + (key,))
        return result
    return after


text = Path(path).read_text().strip()
decoder = json.JSONDecoder()
while text:
    try:
        value, end = decoder.raw_decode(text)
    except ValueError:
        print(text)
        break
    if name == "codex-rate-limits":
        if value.get("id") == 2 and isinstance(value.get("result"), dict):
            value["result"] = overlay(original, value["result"])
    else:
        value = overlay(original, value)
    print(json.dumps(value, ensure_ascii=False, separators=(",", ":")))
    text = text[end:].lstrip()
