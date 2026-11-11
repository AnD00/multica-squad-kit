"""見本を元にしたケースの鍵を確かめる。見張りのテストからも使う。"""

import json
import subprocess


def matches(value, expression):
    result = subprocess.run(["jq", "-e", expression], input=json.dumps(value),
                            capture_output=True, text=True)
    if result.returncode not in (0, 1, 4):
        raise ValueError("約束の条件が不正です")
    return result.returncode == 0


def assert_case_keys(original, candidate, fields, allow_required_deletion=False, skip=()):
    rules = {tuple(field["path"].split(".")): field for field in fields}

    def walk(before, after, path):
        if path in skip:
            return
        if isinstance(before, dict) and isinstance(after, dict):
            extra = after.keys() - before.keys()
            if extra:
                raise AssertionError(f"見本にない鍵です: {'.'.join(path)} {sorted(extra)}")
            for key in before.keys() - after.keys():
                field = rules.get(path + (key,))
                optional = field is not None and (
                    field["class"] == "optional" or
                    field["class"] == "conditional" and not matches(candidate, field["when"]))
                negative = allow_required_deletion and field is not None
                if not optional and not negative:
                    raise AssertionError(f"消せない鍵です: {'.'.join(path + (key,))}")
            for key in before.keys() & after.keys():
                walk(before[key], after[key], path + (key,))
        elif isinstance(before, list) and isinstance(after, list):
            for index, value in enumerate(after):
                if isinstance(value, (dict, list)):
                    if not before:
                        raise AssertionError("空の見本から要素の鍵を作れません")
                    walk(before[min(index, len(before) - 1)], value, path)

    walk(original, candidate, ())


def assert_fixture_response(original, candidate, entry, allow_required_deletion=False):
    def items(before, after, fields):
        for value in after:
            if not before:
                raise AssertionError("空の見本から要素を作れません")
            for original in before:
                try:
                    assert_case_keys(original, value, fields, allow_required_deletion)
                    break
                except AssertionError:
                    pass
            else:
                raise AssertionError("見本に合う要素の形がありません")

    if entry["shape"] == "array":
        items(original, candidate, entry["items"]["fields"])
    else:
        item_path = tuple(entry.get("items", {}).get("path", []))
        assert_case_keys(original, candidate, entry.get("fields", []), allow_required_deletion,
                         (item_path,) if "items" in entry else ())
        if "items" in entry:
            before, after = original, candidate
            for key in item_path:
                if key not in after:
                    return
                before, after = before[key], after[key]
            items(before, after, entry["items"]["fields"])
