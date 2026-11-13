#!/usr/bin/env python3
"""Collect Multica records, then count workflow metrics from a saved snapshot.

Snapshot v1 has collected_at, cli_version, project_id and the arrays issues,
comments, transitions, runs and agents. See tests/fixtures/metrics/snapshot.json
for a synthetic example of the contract used by the collector.
"""

import argparse
from datetime import datetime, timezone
from decimal import Decimal, ROUND_HALF_UP
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


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


def cli(arguments, cursor=False, version=False):
    """Only the comment paginator may emit the documented cursor on stderr."""
    command = ["multica", *arguments]
    if not version:
        command += ["--output", "json"]
    result = subprocess.run(command, capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise ValueError(f"Multica の読み取りに失敗しました: {' '.join(arguments[:3])}")
    next_page = None
    for line in result.stderr.splitlines():
        if not line.strip():
            continue
        match = re.fullmatch(r"Next thread cursor: --before (\S+) --before-id (\S+)", line)
        if not cursor or not match or next_page is not None:
            raise ValueError(f"Multica の警告で読み取りを止めました: {line}")
        timestamp(match[1])
        next_page = (match[1], match[2])
    if version:
        lines = result.stdout.splitlines()
        if not lines or not lines[0].startswith("multica "):
            raise ValueError("CLI のバージョンを読めません")
        return lines[0]
    return json.loads(result.stdout), next_page


def records(value):
    if not isinstance(value, list) or any(not isinstance(row, dict) for row in value):
        raise ValueError("CLI の記録はオブジェクトの配列にしてください")
    return value


def fields(row, names, nullable=()):
    selected = {name: row[name] for name in names}
    for name, value in selected.items():
        if name in nullable and value is None:
            continue
        if not isinstance(value, str) or not value:
            raise ValueError(f"必須の文字列の欄がありません: {name}")
    return selected


def ordered(rows):
    return sorted(rows, key=lambda row: (timestamp(row["created_at"]), row["id"]))


def read_trace_definitions(path):
    """Keep the exact input digest so later judgments can verify their definitions."""
    raw = path.read_bytes()
    definitions = json.loads(raw)
    if not isinstance(definitions, dict) or definitions.get("schema_version") != 1:
        raise ValueError("対応していない跡の定義のバージョンです")
    procedures = records(definitions["procedures"])
    ids = set()
    for procedure in procedures:
        trace_id = fields(procedure, ("id",))["id"]
        if trace_id in ids:
            raise ValueError("跡の定義の ID が重複しています")
        ids.add(trace_id)
        trace = procedure["trace"]
        if trace is None:
            continue
        if not isinstance(trace, dict) or trace.get("kind") not in ("comment", "transition", "run"):
            raise ValueError("跡の形は comment・transition・run にしてください")
    return definitions, hashlib.sha256(raw).hexdigest()


def comment_trace_patterns(definitions):
    patterns = []
    for procedure in definitions["procedures"]:
        trace = procedure["trace"]
        if trace is None or trace["kind"] != "comment":
            continue
        if not isinstance(trace["pattern"], str):
            raise ValueError("コメントの跡の pattern は文字列にしてください")
        author_type = fields(trace, ("author_type",))["author_type"] if "author_type" in trace else None
        try:
            pattern = re.compile(trace["pattern"])
        except re.error as error:
            raise ValueError(f"コメントの跡の正規表現が不正です: {procedure['id']}") from error
        patterns.append((procedure["id"], pattern, author_type))
    return sorted(patterns, key=lambda item: item[0])


def collect(project, traces_path=None):
    patterns = None
    if traces_path is not None:
        definitions, definitions_sha256 = read_trace_definitions(traces_path)
        patterns = comment_trace_patterns(definitions)
    snapshot = {"schema_version": 1, "project_id": project,
                "collected_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
                "cli_version": cli(["version"], version=True),
                "issues": [], "comments": [], "transitions": [], "runs": [], "agents": []}
    if patterns is not None:
        snapshot["trace_definitions_sha256"] = definitions_sha256
    offset = 0
    while True:
        page, _ = cli(["issue", "list", "--project", project, "--limit", "100",
                       "--offset", str(offset), "--sort", "created_at", "--direction", "asc"])
        rows = records(page["issues"])
        if (type(page["has_more"]) is not bool or type(page["offset"]) is not int
                or page["offset"] != offset or type(page["limit"]) is not int
                or page["limit"] <= 0 or type(page["total"]) is not int or page["total"] < 0):
            raise ValueError("タスクのページの情報が不正です")
        snapshot["issues"].extend(fields(row, ("id", "identifier", "created_at", "status")) for row in rows)
        if not page["has_more"]:
            break
        if not rows:
            raise ValueError("次のページがあるのにタスクが空です")
        offset += len(rows)
    snapshot["issues"] = ordered(snapshot["issues"])
    if len({row["id"] for row in snapshot["issues"]}) != len(snapshot["issues"]):
        raise ValueError("タスクのページが重複しています")
    for issue in snapshot["issues"]:
        issue_id = issue["id"]
        before = None
        seen_cursors = set()
        while True:
            arguments = ["issue", "comment", "list", issue_id, "--recent", "100", "--full"]
            if before:
                arguments += ["--before", before[0], "--before-id", before[1]]
            comments, next_page = cli(arguments, cursor=True)
            for row in records(comments):
                comment = fields(row, ("id", "issue_id", "author_type", "author_id", "created_at"))
                content = row["content"]
                if not isinstance(content, str) or comment["issue_id"] != issue_id:
                    raise ValueError("コメントの本文の型かタスクが不正です")
                comment["member_mentions"] = sorted(set(re.findall(
                    r"mention://member/([A-Za-z0-9_-]+)", content)))
                if patterns is not None:
                    comment["trace_matches"] = [trace_id for trace_id, pattern, author_type in patterns
                                                if (author_type is None or author_type == comment["author_type"])
                                                and pattern.search(content)]
                snapshot["comments"].append(comment)
            if next_page is None:
                break
            if not comments or next_page in seen_cursors:
                raise ValueError("コメントのページが進みません")
            seen_cursors.add(next_page)
            before = next_page
        timeline, _ = cli(["issue", "timeline", issue_id, "--activity-only"])
        for row in ordered(records(timeline)):
            activity = fields(row, ("id", "type", "action", "created_at"))
            if activity["type"] != "activity":
                raise ValueError("状態の変化に活動以外の記録があります")
            if activity["action"] == "status_changed":
                change = fields(row["details"], ("from", "to"))
                snapshot["transitions"].append({"id": activity["id"], "issue_id": issue_id,
                    "created_at": activity["created_at"],
                    "from_status": change["from"], "to_status": change["to"]})
        runs, _ = cli(["issue", "runs", issue_id])
        for row in records(runs):
            run = fields(row, ("id", "issue_id", "agent_id", "status", "created_at",
                               "started_at", "completed_at"), nullable=("started_at", "completed_at"))
            if run["issue_id"] != issue_id:
                raise ValueError("実行のタスクが一致しません")
            # CLI 0.7.0 omits usage on runs without a usage record (captured fixture).
            usage = row["usage"] if "usage" in row else []
            run["usage"] = []
            for item in records(usage):
                normalized = fields(item, ("provider", "model"))
                normalized.update({field: item[field] for field in TOKEN_FIELDS})
                run["usage"].append(normalized)
            add_usage(empty_role(), run["usage"])
            run["usage"].sort(key=lambda item: (item["provider"], item["model"],
                                               *(item[field] for field in TOKEN_FIELDS)))
            snapshot["runs"].append(run)
    agent_ids = {run["agent_id"] for run in snapshot["runs"]}
    agents, _ = cli(["agent", "list", "--include-archived"])
    snapshot["agents"] = sorted((fields(row, ("id", "name")) for row in records(agents)
                                 if row["id"] in agent_ids), key=lambda row: row["id"])
    for name in ("comments", "runs"):
        snapshot[name] = ordered(snapshot[name])
    snapshot["transitions"] = [{key: value for key, value in row.items() if key != "id"}
                               for row in ordered(snapshot["transitions"])]
    validate_snapshot(snapshot)
    return snapshot


def write_snapshot(path, snapshot):
    """Publish only a fully read and validated snapshot; keep an older file on failure."""
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                         prefix=path.name + ".", delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(json.dumps(snapshot, ensure_ascii=False, sort_keys=True, indent=2) + "\n")
        os.replace(temporary, path)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


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


PROTECTIONS = ("secrets", "write_scope", "gate", "irreversible")


def trace_procedures(definitions):
    # Validate the same comment definitions that collect used, without reading bodies.
    comment_trace_patterns(definitions)
    for procedure in definitions["procedures"]:
        fields(procedure, ("file", "section", "marker"))
        protection = procedure.get("protection")
        not_procedure = procedure.get("not_procedure", False)
        if protection is not None and protection not in PROTECTIONS:
            raise ValueError("守る手順の分類は secrets・write_scope・gate・irreversible にしてください")
        if type(not_procedure) is not bool:
            raise ValueError("not_procedure は真偽値にしてください")
        trace = procedure["trace"]
        if not_procedure and (trace is not None or protection is not None):
            raise ValueError("手順でない節に跡や守る手順の分類を付けないでください")
        if trace is not None and trace["kind"] == "transition":
            fields(trace, ("from_status", "to_status"))
        if trace is not None and trace["kind"] == "run":
            fields(trace, ("role", "status"))
            if trace["role"] not in ROLES and trace["role"] != "その他":
                raise ValueError("実行の跡の role が役の名前と一致しません")
    return sorted(definitions["procedures"], key=lambda row: row["id"])


def traces(snapshot, raw, definitions, definitions_sha256, args):
    validate_snapshot(snapshot)
    if snapshot.get("trace_definitions_sha256") != definitions_sha256:
        raise ValueError("スナップショットと跡の定義の SHA-256 が一致しません")
    procedures = trace_procedures(definitions)
    comment_ids = {row["id"] for row in procedures
                   if row["trace"] is not None and row["trace"]["kind"] == "comment"}
    for comment in snapshot["comments"]:
        matches = comment["trace_matches"]
        if (not isinstance(matches, list) or any(not isinstance(item, str) for item in matches)
                or len(set(matches)) != len(matches) or not set(matches).issubset(comment_ids)):
            raise ValueError("コメントの trace_matches が跡の定義と一致しません")
    cutoff = timestamp(snapshot["collected_at"])
    selected = sorted((issue for issue in snapshot["issues"]
                       if timestamp(issue["created_at"]) <= cutoff),
                      key=lambda row: (-timestamp(row["created_at"]), row["id"]))[:20]
    issue_ids = {issue["id"] for issue in selected}
    groups = {name: [row for row in snapshot[name] if row["issue_id"] in issue_ids]
              for name in ("comments", "transitions", "runs")}
    agents = {row["id"]: row["name"] for row in snapshot["agents"]}
    rows = []
    for procedure in procedures:
        trace = procedure["trace"]
        count = None
        if trace is not None:
            if trace["kind"] == "comment":
                count = sum(procedure["id"] in row["trace_matches"] for row in groups["comments"])
            elif trace["kind"] == "transition":
                count = sum(row["from_status"] == trace["from_status"]
                            and row["to_status"] == trace["to_status"] for row in groups["transitions"])
            else:
                count = sum(role_name(agents[row["agent_id"]], args.project_key, args.member_key) == trace["role"]
                            and row["status"] == trace["status"] for row in groups["runs"])
        protection = procedure.get("protection")
        if procedure.get("not_procedure", False):
            judgment = "手順でない"
        elif protection is not None:
            judgment = "守る手順で残す"
        elif trace is None:
            judgment = "判定できない"
        else:
            judgment = "効いた" if count else "削る候補"
        rows.append({**{key: procedure[key] for key in ("id", "file", "section", "marker", "trace")},
                     "protection": protection, "count": count, "judgment": judgment})
    return {"schema_version": 1,
            "input": {"snapshot_sha256": hashlib.sha256(raw).hexdigest(),
                      "trace_definitions_sha256": definitions_sha256,
                      "collected_at": snapshot["collected_at"], "project_id": snapshot["project_id"],
                      "project_key": args.project_key, "member_key": args.member_key},
            "issues": selected, "procedures": rows}


def traces_markdown(result):
    lines = ["# 手順の見直し", "", "## 入力", ""]
    lines += table(("入力", "値"), result["input"].items())
    lines += ["## 対象のタスク", "", f"対象のタスク: {len(result['issues'])} 件", ""]
    lines += table(("タスク", "ID", "作られた時刻"),
                   ((row["identifier"], row["id"], row["created_at"]) for row in result["issues"]))
    lines += ["## 判定の一覧", ""]
    lines += table(("ID", "ファイル", "節", "目印", "跡", "20 件での回数", "判定", "守る手順の分類"),
                   ((row["id"], row["file"], row["section"], row["marker"],
                     json.dumps(row["trace"], ensure_ascii=False, sort_keys=True),
                     row["count"], row["judgment"], row["protection"]) for row in result["procedures"]))
    return "\n".join(lines)


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
    collector = subparsers.add_parser("collect", help="Multica の記録をスナップショットに残す")
    collector.add_argument("--project", required=True)
    collector.add_argument("--output", type=Path, required=True)
    collector.add_argument("--traces", type=Path, help="コメントの跡の定義 JSON")
    counter = subparsers.add_parser("count", help="保存したスナップショットから数える")
    counter.add_argument("snapshot", type=Path)
    for flag in ("cutoff", "truncate", "project-key", "member-key"):
        counter.add_argument("--" + flag, required=True)
    counter.add_argument("--human", action="append", required=True, help="複数の人間はこの引数を繰り返す")
    counter.add_argument("--from", dest="from_time")
    counter.add_argument("--compare", type=Path)
    counter.add_argument("--output", type=Path, required=True, help="結果のディレクトリ")
    reviewer = subparsers.add_parser("traces", help="保存した跡の件数と手順の判定を一覧にする")
    reviewer.add_argument("snapshot", type=Path)
    reviewer.add_argument("--traces", type=Path, required=True)
    reviewer.add_argument("--project-key", required=True)
    reviewer.add_argument("--member-key", required=True)
    reviewer.add_argument("--output", type=Path, required=True, help="結果のディレクトリ")
    args = parser.parse_args()
    try:
        if args.command == "collect":
            write_snapshot(args.output, collect(args.project, args.traces))
            return
        raw = args.snapshot.read_bytes()
        if args.command == "traces":
            definitions, digest = read_trace_definitions(args.traces)
            result = traces(json.loads(raw), raw, definitions, digest, args)
            rendered = traces_markdown(result)
            args.output.mkdir(parents=True, exist_ok=True)
            write_snapshot(args.output / "traces.json", result)
            (args.output / "traces.md").write_text(rendered, encoding="utf-8")
            return
        plan = json.loads(args.compare.read_bytes()) if args.compare else None
        result = count(json.loads(raw), raw, args, plan)
        rendered = markdown(result)
        args.output.mkdir(parents=True, exist_ok=True)
        (args.output / "metrics.json").write_text(
            json.dumps(result, ensure_ascii=False, sort_keys=True, indent=2) + "\n", encoding="utf-8")
        (args.output / "metrics.md").write_text(rendered, encoding="utf-8")
    except (OSError, ValueError, KeyError, TypeError, ArithmeticError, subprocess.TimeoutExpired) as error:
        parser.exit(1, f"エラー: 数えられません: {error}\n")


if __name__ == "__main__":
    main()
