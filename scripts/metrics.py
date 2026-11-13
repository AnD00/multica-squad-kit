#!/usr/bin/env python3
"""Count workflow metrics from a normalized snapshot; never contact Multica.

Snapshot v1 has collected_at, cli_version, project_id and the arrays issues,
comments, transitions, runs and agents. See tests/fixtures/metrics/snapshot.json
for a synthetic example of the contract used by the collector.
"""

import argparse
from datetime import datetime, timezone
from decimal import Decimal, ROUND_HALF_UP
import hashlib
import json
from pathlib import Path
import re
import sys


TOKEN_FIELDS = ("input_tokens", "cache_write_tokens", "cache_read_tokens", "output_tokens")
METRIC_FIELDS = ("human_comments", "human_calls", "run_seconds", "run_count",
                 "fixer_runs", "in_review_transitions")
# Names are the roles shipped in common/agents (FORMAT is not a role).
ROLES = frozenset((
    "ci-monitor", "claude-fixer", "claude-implementer", "claude-principal",
    "code-reviewer", "codex-fixer", "codex-implementer", "codex-principal",
    "dependabot-merger", "designer", "orchestrator", "performance-reviewer",
    "planner", "qa", "security-reviewer", "usage-monitor", "ux-reviewer",
))


def timestamp(value):
    """Parse RFC3339 without losing fractional seconds or using floats."""
    match = re.fullmatch(
        r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?(Z|[+-]\d{2}:\d{2})", value)
    if not match:
        raise ValueError("時刻はタイムゾーン付きの RFC3339 にしてください")
    base, fraction, offset = match.groups()
    instant = datetime.fromisoformat(base + ("+00:00" if offset == "Z" else offset))
    delta = instant.astimezone(timezone.utc) - datetime(1970, 1, 1, tzinfo=timezone.utc)
    return Decimal(delta.days * 86400 + delta.seconds) + Decimal(fraction or "0")


def one_decimal(numerator, denominator=1):
    if not denominator:
        return None
    return str((Decimal(numerator) / Decimal(denominator)).quantize(
        Decimal("0.1"), rounding=ROUND_HALF_UP))


def empty_metrics():
    return dict.fromkeys(METRIC_FIELDS, 0)


def empty_role():
    return {"run_count": 0, "confirmed_runs": 0, "unconfirmed_runs": 0,
            "agent_names": [], "tokens": None}


def add_usage(role, usage):
    role["run_count"] += 1
    if not usage:
        role["unconfirmed_runs"] += 1
        return
    role["confirmed_runs"] += 1
    if role["tokens"] is None:
        role["tokens"] = dict.fromkeys((*TOKEN_FIELDS, "total_tokens"), 0)
    for row in usage:
        for field in TOKEN_FIELDS:
            value = row[field]
            if type(value) is not int or value < 0:
                raise ValueError("使用量は 0 以上の整数にしてください")
            role["tokens"][field] += value
            role["tokens"]["total_tokens"] += value


def role_name(name, project_key, member_key):
    prefix, suffix = project_key + "-", "-" + member_key
    if name.startswith(prefix) and name.endswith(suffix):
        role = name[len(prefix):-len(suffix)]
        if role in ROLES:
            return role
    return "その他"


def validate_snapshot(snapshot):
    if snapshot["schema_version"] != 1:
        raise ValueError("対応していないスナップショットのバージョンです")
    timestamp(snapshot["collected_at"])
    for field in ("cli_version", "project_id"):
        if not isinstance(snapshot[field], str) or not snapshot[field]:
            raise ValueError(f"{field} がありません")
    fields = {
        "issues": ("id", "identifier", "created_at", "status"),
        "comments": ("id", "issue_id", "author_type", "author_id", "created_at", "member_mentions"),
        "transitions": ("issue_id", "from_status", "to_status", "created_at"),
        "runs": ("id", "issue_id", "agent_id", "status", "created_at", "started_at", "completed_at", "usage"),
        "agents": ("id", "name"),
    }
    for group, required in fields.items():
        if not isinstance(snapshot[group], list):
            raise ValueError(f"{group} は配列にしてください")
        ids = set()
        for row in snapshot[group]:
            for field in required:
                if field not in row:
                    raise ValueError(f"{group} に {field} がありません")
            if "id" in required:
                if row["id"] in ids:
                    raise ValueError(f"{group} の ID が重複しています")
                ids.add(row["id"])
            for field in ("created_at", "started_at", "completed_at"):
                if field in row and row[field] is not None:
                    timestamp(row[field])
            if group == "comments" and not isinstance(row["member_mentions"], list):
                raise ValueError("member_mentions は配列にしてください")
            if group == "runs":
                if not isinstance(row["usage"], list):
                    raise ValueError("usage は配列にしてください（未確認は空の配列）")
                # Check even excluded runs, so malformed input cannot be hidden by a cutoff.
                add_usage(empty_role(), row["usage"])
    issue_ids = {row["id"] for row in snapshot["issues"]}
    agent_ids = {row["id"] for row in snapshot["agents"]}
    for group in ("comments", "transitions", "runs"):
        for row in snapshot[group]:
            if row["issue_id"] not in issue_ids:
                raise ValueError(f"{group} のタスクがスナップショットにありません")
            if group == "runs" and row["agent_id"] not in agent_ids:
                raise ValueError("実行のエージェントがスナップショットにありません")


def with_minutes(metrics):
    return {**metrics, "run_minutes": one_decimal(metrics["run_seconds"], 60)}


def average_roles(roles, count):
    return {
        name: {
            **{field: one_decimal(role[field], count)
               for field in ("run_count", "confirmed_runs", "unconfirmed_runs")},
            "tokens": ({field: one_decimal(value, count)
                        for field, value in role["tokens"].items()}
                       if role["tokens"] is not None else None),
        }
        for name, role in sorted(roles.items())
    }


def comparison(plan, totals):
    result = {"metrics": {}, "roles": {}}
    for field, expected in sorted(plan["metrics"].items()):
        if field not in (*METRIC_FIELDS, "issue_count") or type(expected) is not int or expected < 0:
            raise ValueError("比較する指標は整数の合計にしてください（実行時間は run_seconds）")
        actual = totals[field]
        result["metrics"][field] = {"plan": expected, "actual": actual,
                                    "difference": actual - expected}
    for name, expected in sorted(plan["roles"].items()):
        role = totals["roles"].get(name, empty_role())
        tokens = role["tokens"]
        actual = tokens["total_tokens"] if tokens is not None else None
        prior = expected["total_tokens"]
        if prior is not None and (type(prior) is not int or prior < 0):
            raise ValueError("比較するトークン数は 0 以上の整数か null にしてください")
        result["roles"][name] = {
            "plan": prior, "actual": actual,
            "difference": actual - prior if actual is not None and prior is not None else None,
            "unconfirmed_runs": role["unconfirmed_runs"],
        }
    # Include newly observed roles, too: they did not have a row in the plan.
    for name, role in sorted(totals["roles"].items()):
        if name not in result["roles"]:
            result["roles"][name] = {
                "plan": None,
                "actual": role["tokens"]["total_tokens"] if role["tokens"] is not None else None,
                "difference": None, "unconfirmed_runs": role["unconfirmed_runs"],
            }
    return result


def count(snapshot, raw, args, plan):
    validate_snapshot(snapshot)
    cutoff, truncate = timestamp(args.cutoff), timestamp(args.truncate)
    start = timestamp(args.from_time) if args.from_time else None
    if start is not None and start >= cutoff:
        raise ValueError("--from は --cutoff より前にしてください")
    agents = {row["id"]: row["name"] for row in snapshot["agents"]}
    selected = sorted((issue for issue in snapshot["issues"]
                       if timestamp(issue["created_at"]) < cutoff
                       and (start is None or timestamp(issue["created_at"]) >= start)),
                      key=lambda issue: (timestamp(issue["created_at"]), issue["id"]))
    issues = {issue["id"]: {"id": issue["id"], "identifier": issue["identifier"],
                            **empty_metrics(), "roles": {}} for issue in selected}
    humans = set(args.human)
    for comment in snapshot["comments"]:
        issue = issues.get(comment["issue_id"])
        if issue is None or timestamp(comment["created_at"]) >= cutoff:
            continue
        if comment["author_type"] == "member":
            issue["human_comments"] += 1
        elif comment["author_type"] == "agent" and humans.intersection(comment["member_mentions"]):
            issue["human_calls"] += 1
    for transition in snapshot["transitions"]:
        issue = issues.get(transition["issue_id"])
        if (issue is not None and timestamp(transition["created_at"]) < cutoff
                and transition["to_status"] == "in_review"
                and transition["from_status"] != "in_review"):
            issue["in_review_transitions"] += 1
    for run in snapshot["runs"]:
        issue = issues.get(run["issue_id"])
        if issue is None or timestamp(run["created_at"]) >= cutoff or run["started_at"] is None:
            continue
        begin = timestamp(run["started_at"])
        end = min(timestamp(run["completed_at"]), truncate) if run["completed_at"] else truncate
        issue["run_count"] += 1
        issue["run_seconds"] += int(max(Decimal(0), end - begin))
        name = agents[run["agent_id"]]
        role = role_name(name, args.project_key, args.member_key)
        if role in ("claude-fixer", "codex-fixer"):
            issue["fixer_runs"] += 1
        usage = issue["roles"].setdefault(role, empty_role())
        add_usage(usage, run["usage"])
        if role == "その他" and name not in usage["agent_names"]:
            usage["agent_names"].append(name)

    totals = {"issue_count": len(issues), **empty_metrics(), "roles": {}}
    for issue in issues.values():
        for field in METRIC_FIELDS:
            totals[field] += issue[field]
        for name, role in issue["roles"].items():
            role["agent_names"].sort()
            total_role = totals["roles"].setdefault(name, empty_role())
            for field in ("run_count", "confirmed_runs", "unconfirmed_runs"):
                total_role[field] += role[field]
            total_role["agent_names"] = sorted(set(total_role["agent_names"] + role["agent_names"]))
            if role["tokens"] is not None:
                if total_role["tokens"] is None:
                    total_role["tokens"] = dict.fromkeys((*TOKEN_FIELDS, "total_tokens"), 0)
                for field, value in role["tokens"].items():
                    total_role["tokens"][field] += value
    return {
        "schema_version": 1,
        "input": {"cutoff": args.cutoff, "truncate": args.truncate, "from": args.from_time,
                  "human": sorted(humans), "project_key": args.project_key, "member_key": args.member_key,
                  "project_id": snapshot["project_id"], "snapshot_sha256": hashlib.sha256(raw).hexdigest(),
                  "collected_at": snapshot["collected_at"], "cli_version": snapshot["cli_version"],
                  "compare": plan},
        "issues": [with_minutes(issue) for issue in issues.values()],
        "totals": with_minutes(totals),
        "per_issue": {**{field: one_decimal(totals[field], len(issues)) for field in METRIC_FIELDS},
                      "run_minutes": one_decimal(totals["run_seconds"], len(issues) * 60),
                      "roles": average_roles(totals["roles"], len(issues))},
        "comparison": comparison(plan, totals) if plan is not None else None,
    }


def cell(value):
    if value is None:
        return "未確認"
    return str(value).replace("\\", "\\\\").replace("|", "\\|").replace("\n", "<br>").replace("\r", "")


def table(headers, rows):
    return ["| " + " | ".join(map(cell, headers)) + " |",
            "| " + " | ".join("---" for _ in headers) + " |",
            *("| " + " | ".join(map(cell, row)) + " |" for row in rows), ""]


def markdown(result):
    lines = ["# 作業の指標", "", "## 入力", ""]
    lines += table(("入力", "値"), ((key, json.dumps(value, ensure_ascii=False, sort_keys=True))
                                   for key, value in result["input"].items()))
    columns = ("human_comments", "human_calls", "run_seconds", "run_minutes", "run_count",
               "fixer_runs", "in_review_transitions")
    headers = ("タスク", "人間のコメント", "人間の呼び出し", "実行秒", "実行分", "実行回数", "差し戻し", "in_review")
    lines += ["## タスクごと・合計・1 タスクあたり", "", f"対象のタスク: {result['totals']['issue_count']} 件", ""]
    lines += table(headers, [(issue["identifier"], *(issue[key] for key in columns)) for issue in result["issues"]]
                   + [(label, *(result[group][key] for key in columns))
                      for label, group in (("合計", "totals"), ("1 タスクあたり", "per_issue"))])
    lines += ["## 役ごとのトークン数", "", "トークンは確認できた実行の合計。未確認の実行は加算せず、別の件数に示す。", ""]
    rows = []
    for label, roles in [(issue["identifier"], issue["roles"]) for issue in result["issues"]] + [
            ("合計", result["totals"]["roles"]), ("1 タスクあたり", result["per_issue"]["roles"])]:
        for name, role in sorted(roles.items()):
            rows.append((label, name, ", ".join(role.get("agent_names", [])), role["run_count"],
                         role["confirmed_runs"], role["unconfirmed_runs"],
                         *((role["tokens"] or {}).get(field) for field in (*TOKEN_FIELDS, "total_tokens"))))
    lines += table(("タスク", "役", "その他のエージェント", "実行", "確認済み", "未確認",
                    "入力", "キャッシュ作成", "キャッシュ読み出し", "出力", "合計"), rows)
    lines += ["## 計画の表との差", ""]
    if result["comparison"] is None:
        lines += ["比較の入力なし。", ""]
    else:
        lines += ["差は今回の値から計画の値を引いた値。差の理由は、数えた人が結果のコメントに記す。", ""]
        lines += table(("指標", "計画", "今回", "差"),
                       ((name, row["plan"], row["actual"], row["difference"])
                        for name, row in result["comparison"]["metrics"].items()))
        lines += table(("役", "計画のトークン合計", "今回の確認済み合計", "差", "未確認の実行"),
                       ((name, row["plan"], row["actual"], row["difference"], row["unconfirmed_runs"])
                        for name, row in result["comparison"]["roles"].items()))
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    counter = subparsers.add_parser("count", help="保存したスナップショットから数える")
    counter.add_argument("snapshot", type=Path)
    for flag in ("cutoff", "truncate", "project-key", "member-key"):
        counter.add_argument("--" + flag, required=True)
    counter.add_argument("--human", action="append", required=True, help="複数の人間はこの引数を繰り返す")
    counter.add_argument("--from", dest="from_time")
    counter.add_argument("--compare", type=Path)
    counter.add_argument("--output", type=Path, required=True, help="結果のディレクトリ")
    args = parser.parse_args()
    try:
        raw = args.snapshot.read_bytes()
        plan = json.loads(args.compare.read_bytes()) if args.compare else None
        result = count(json.loads(raw), raw, args, plan)
        rendered = markdown(result)
        args.output.mkdir(parents=True, exist_ok=True)
        (args.output / "metrics.json").write_text(
            json.dumps(result, ensure_ascii=False, sort_keys=True, indent=2) + "\n", encoding="utf-8")
        (args.output / "metrics.md").write_text(rendered, encoding="utf-8")
    except (OSError, ValueError, KeyError, TypeError, ArithmeticError) as error:
        parser.exit(1, f"エラー: 数えられません: {error}\n")


if __name__ == "__main__":
    main()
