"""見本を元にしたケースの鍵を確認する。見張りのテストからも使う。"""

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
    def object_case(before, after, schema):
        child = schema.get("items")
        path = tuple(child["path"]) if child else None
        mapping = schema.get("values")
        map_path = tuple(mapping["path"]) if mapping else None
        assert_case_keys(before, after, schema.get("fields", []), allow_required_deletion,
                         tuple(p for p in (path, map_path) if p))
        if mapping:
            originals, values = before, after
            for key in map_path:
                if not isinstance(values, dict) or key not in values:
                    break
                originals, values = originals[key], values[key]
            else:
                if isinstance(values, dict):
                    items(list(originals.values()), list(values.values()), mapping)
        if child:
            for key in path:
                if not isinstance(after, dict) or key not in after:
                    return
                before, after = before[key], after[key]
            items(before, after, child)

    def items(before, after, schema):
        for value in after:
            for original in before:
                try:
                    object_case(original, value, schema)
                    break
                except AssertionError:
                    pass
            else:
                raise AssertionError("見本に合う要素の形がありません")

    if entry["shape"] == "array":
        items(original, candidate, entry["items"])
    else:
        object_case(original, candidate, entry)
