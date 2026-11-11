"""モデルを呼ばず使用量を採取する。保存済みの実応答は --response-dir でも渡せる。"""

import argparse
import json
import re
import runpy
import selectors
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
capture = runpy.run_path(str(ROOT / "tests/capture-cli-fixtures.py"))


def codex_response():
    process = subprocess.Popen(["codex", "app-server"], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    try:
        requests = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
                "clientInfo": {"name": "squad-usage-check", "version": "1.0.0"}}},
            {"jsonrpc": "2.0", "method": "initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read"},
        ]
        for request in requests:
            process.stdin.write(json.dumps(request) + "\n")
        process.stdin.flush()
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            # TextIO の先読みを避けるため、通知も含め 1 バイトずつ読む。
            line = bytearray()
            while selector.select(30):
                char = process.stdout.buffer.read1(1)
                if not char:
                    break
                line.extend(char)
                if char == b"\n":
                    value = json.loads(line)
                    line.clear()
                    if value.get("id") == 2:
                        return value["result"]
        raise ValueError("Codex の使用量の応答がなかった")
    finally:
        process.stdin.close()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def redact_usage(value, name, aliases=None):
    if aliases is None:
        aliases = capture["uuid_aliases"](value)
    result = capture["redact"](value, id_aliases=aliases)

    def private_strings(item):
        if isinstance(item, dict):
            return {key: ("fixture" if key in ("accountId", "id", "title", "description")
                          and isinstance(child, str) and not child.startswith("fixture-id-")
                          else private_strings(child))
                    for key, child in item.items()}
        if isinstance(item, list):
            return [private_strings(child) for child in item]
        return item

    result = private_strings(result)
    if name == "claude-usage":
        # 使用率とリセットの行は表示そのものを残す。診断・提案・パスは自由文として置換する。
        pattern = r"Current (?:session|week \([^)]+\)): [0-9]+% used(?: · resets .+)?"
        result["result"] = "\n".join(
            line if re.fullmatch(pattern, line) else ("fixture" if line else "")
            for line in value["result"].split("\n"))
        result["result"] = capture["UUID"].sub(lambda match: aliases[match.group()], result["result"])
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--response-dir", type=Path)
    parser.add_argument("--output-dir", type=Path, default=ROOT / "tests/fixtures/cli")
    args = parser.parse_args()
    versions = {name: subprocess.check_output([name, "--version"], text=True).splitlines()[0]
                for name in ("codex", "claude")}
    if args.response_dir:
        values = {name: json.loads((args.response_dir / f"{name}.json").read_text())
                  for name in ("codex-rate-limits", "claude-usage")}
    else:
        values = {"codex-rate-limits": codex_response(), "claude-usage": capture["command_json"](
            ["claude", "-p", "/usage", "--output-format", "json"])}
    entry = capture["contracts"]()["codex-rate-limits"]
    result = subprocess.run(["bash", "-c", 'source "$1"; squad_cli_normalize codex-rate-limits "$2"',
                             "bash", str(ROOT / "common/monitor/squad-cli-lib"), versions["codex"]],
                            input=json.dumps(values["codex-rate-limits"]), capture_output=True, text=True)
    if result.returncode:
        raise ValueError(result.stderr)
    selected, coverage, absent = capture["select_samples"]([values["codex-rate-limits"]], entry)
    if absent:
        raise ValueError(f"見本の形がありません: {absent}")
    claude = values["claude-usage"]
    if claude.get("is_error") is not False or not isinstance(claude.get("result"), str):
        raise ValueError("Claude の使用量の表示を取れなかった")
    values["codex-rate-limits"] = selected[0]
    args.output_dir.mkdir(parents=True, exist_ok=True)
    aliases = capture["uuid_aliases"](values)
    for name, value in values.items():
        (args.output_dir / f"{name}.json").write_text(
            json.dumps([redact_usage(value, name, aliases)], ensure_ascii=False, indent=2) + "\n")
    (args.output_dir / "USAGE-CAPTURE.json").write_text(json.dumps({
        "versions": versions,
        "sources": {"codex-rate-limits": "codex app-server: account/rateLimits/read の result",
                    "claude-usage": "claude -p /usage --output-format json"},
        "coverage": {"codex-rate-limits": coverage, "claude-usage": [{"name": "display", "count": 1}]},
    }, ensure_ascii=False, indent=2) + "\n")
    for record in coverage:
        if "unavailable" in record:
            print(f"見本なし: {record['name']}（0 件）: {record['unavailable']}")


if __name__ == "__main__":
    main()
