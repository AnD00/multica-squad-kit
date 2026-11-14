"""リーダーの評価の補助。場面の読み取り、スタブの CLI、1 回の実行、採点、集計を持つ。

run.sh が `python3 -I` で呼ぶ。サブコマンド:
  scene <scene.md>                      場面を JSON にして出す（形が不正なら 1 で終わる）
  stub <名前> <引数...>                 スタブの CLI。bin の中の shim が呼ぶ
  run-one --out DIR --scene ID --which old|new --n N ...
                                        1 回の実行。結果を DIR/result.json に書く
  run-all --out DIR --scene-ids A,B --versions old,new --runs N --jobs N ...
                                        場面と回の全部を、並列数 jobs で流す
  summary <runs.jsonl> <summary.md>     場面ごとの表を書く
"""
import fcntl
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

SCORER_MARK = "[leader-eval-scorer]"
SCORER_MODEL = "claude-opus-5-5"
SCORER_EFFORT = "high"
KINDS = ("記録", "採点")
HEADINGS = ("## 元の出来事", "## 入力", "## 合格の基準")
UUID = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")

# 成功を返して中身を記録する書き込み。cli.json に同じ前方一致があれば、そちらを先に使う。
WRITE_PREFIXES = [
    "multica issue comment add",
    "multica issue status",
    "multica issue assign",
    "multica issue update",
    "multica issue create",
    "multica issue label add",
    "multica issue label remove",
    "multica issue metadata set",
    "multica issue cancel-task",
    "multica issue rerun",
    "multica issue wakeup create",
    "multica issue wakeup update",
    "multica issue wakeup disable",
    "multica issue wakeup delete",
    "multica issue wakeup trigger",
    "multica issue wakeup checkin",
]
FILE_FLAGS = ("--content-file", "--description-file")
VALUE_FLAGS = ("--content", "--description")


class SceneError(Exception):
    pass


def parse_scene(path):
    text = Path(path).read_text(encoding="utf-8")
    sections = {}
    current = None
    for line in text.splitlines():
        if line.startswith("## "):
            current = line.strip()
            sections.setdefault(current, [])
        elif current is not None:
            sections[current].append(line)
    head = {}
    for line in text.splitlines():
        m = re.match(r"^- (場面の ID|型): (.+)$", line)
        if m:
            head[m.group(1)] = m.group(2).strip()
        if line.startswith("## "):
            break
    for key in ("場面の ID", "型"):
        if key not in head:
            raise SceneError(f"{path}: 先頭に `- {key}: …` がありません")
    for heading in HEADINGS:
        if heading not in sections or not "\n".join(sections[heading]).strip():
            raise SceneError(f"{path}: 見出し {heading} がないか、中身が空です")
    criteria = []
    for line in sections["## 合格の基準"]:
        m = re.match(r"^(\d+)\. \[(記録|採点)\] (.+)$", line)
        if not m:
            if line.strip():
                raise SceneError(f"{path}: 合格の基準の行が `N. [記録|採点] …` の形ではありません: {line}")
            continue
        n, kind, body = int(m.group(1)), m.group(2), m.group(3)
        predicate = None
        pm = re.search(r"`判定: (.+)`\s*$", body)
        if kind == "記録":
            if not pm:
                raise SceneError(f"{path}: [記録] の基準 {n} に `判定: …` がありません")
            predicate = pm.group(1)
            try:
                parse_predicate(predicate)
            except SceneError as e:
                raise SceneError(f"{path}: 基準 {n}: {e}")
            body = body[: pm.start()].strip()
        elif pm:
            raise SceneError(f"{path}: [採点] の基準 {n} に `判定:` は付けません")
        criteria.append({"n": n, "kind": kind, "text": body, "predicate": predicate})
    if not criteria:
        raise SceneError(f"{path}: 合格の基準が 1 つもありません")
    if [c["n"] for c in criteria] != list(range(1, len(criteria) + 1)):
        raise SceneError(f"{path}: 合格の基準の番号が 1 から続いていません")
    return {
        "id": head["場面の ID"],
        "type": head["型"],
        "event": "\n".join(sections["## 元の出来事"]).strip(),
        "input": "\n".join(sections["## 入力"]).strip(),
        "criteria": criteria,
    }


def parse_predicate(text):
    """`called: RE && not-called: RE && before: RE => RE && posted: RE && not-posted: RE`。"""
    terms = []
    for part in text.split(" && "):
        m = re.match(r"^(called|not-called|before|posted|not-posted): (.+)$", part.strip())
        if not m:
            raise SceneError(f"判定の項目が読めません: {part}")
        op, arg = m.group(1), m.group(2)
        if op == "before":
            pair = arg.split(" => ")
            if len(pair) != 2:
                raise SceneError(f"before は `A => B` の形です: {arg}")
            args = pair
        else:
            args = [arg]
        for a in args:
            try:
                re.compile(a)
            except re.error as e:
                raise SceneError(f"正規表現が不正です（{a}）: {e}")
        terms.append((op, args))
    return terms


def check_record(predicate, calls):
    """記録から判定する。返り値は (合否, 理由)。"""
    # 呼んだことの確認には、実行できた記録だけを使う。呼ばなかったことの確認には拒否も含める。
    lines = [c["command"] for c in calls if c.get("kind") != "denied"]
    attempted = [c["command"] for c in calls]
    bodies = [b for c in calls for b in c.get("bodies", [])]

    def first(rx):
        for i, line in enumerate(lines):
            if re.search(rx, line):
                return i
        return None

    for op, args in parse_predicate(predicate):
        if op == "called" and first(args[0]) is None:
            return False, f"呼んでいない: {args[0]}"
        if op == "not-called":
            for line in attempted:
                if re.search(args[0], line):
                    return False, f"呼んでいる（拒否も含む）: {line}"
        if op == "before":
            a, b = first(args[0]), first(args[1])
            if a is None:
                return False, f"呼んでいない: {args[0]}"
            if b is not None and b < a:
                return False, f"{args[1]} が {args[0]} より先にある"
        if op == "posted" and not any(re.search(args[0], b, re.M) for b in bodies):
            return False, f"投稿した文に当たらない: {args[0]}"
        if op == "not-posted" and any(re.search(args[0], b, re.M) for b in bodies):
            return False, f"投稿した文に当たる: {args[0]}"
    return True, "記録が基準を満たす"


# ---- スタブ ----

def command_line(name, argv):
    return " ".join([name] + argv)


def match_command(table, line):
    best, best_len = None, -1
    for entry in table:
        m = entry["match"]
        if line == m or line.startswith(m + " "):
            if len(m) > best_len:
                best, best_len = entry, len(m)
    return best


def stub(name, argv):
    cli_path = os.environ["LEADER_EVAL_CLI"]
    calls_path = os.environ["LEADER_EVAL_CALLS"]
    table = json.loads(Path(cli_path).read_text(encoding="utf-8")).get("commands", [])
    line = command_line(name, argv)
    bodies = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in FILE_FLAGS and i + 1 < len(argv):
            p = Path(argv[i + 1])
            bodies.append(p.read_text(encoding="utf-8") if p.is_file() else "")
            i += 2
            continue
        if a in VALUE_FLAGS and i + 1 < len(argv):
            bodies.append(argv[i + 1])
            i += 2
            continue
        i += 1
    entry = match_command(table, line)
    if entry is not None:
        kind, code = "read", int(entry.get("exit", 0))
        out = entry.get("stdout", "")
        err = entry.get("stderr", "")
        if not isinstance(out, str):
            out = json.dumps(out, ensure_ascii=False, indent=2)
        if any(line == p or line.startswith(p + " ") for p in WRITE_PREFIXES):
            kind = "write"
    elif any(line == p or line.startswith(p + " ") for p in WRITE_PREFIXES):
        kind, code, err = "write", 0, ""
        out = json.dumps({"id": "comment-new"}) if "--output json" in line else "ok"
    else:
        kind, code, out = "unmatched", 1, ""
        err = f"leader-eval stub: 見本のない呼び出しです: {line}"
    record = {"command": line, "kind": kind, "exit": code}
    if bodies:
        record["bodies"] = bodies
    with open(calls_path, "a", encoding="utf-8") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        f.write(json.dumps(record, ensure_ascii=False) + "\n")
    if out:
        sys.stdout.write(out if out.endswith("\n") else out + "\n")
    if err:
        sys.stderr.write(err if err.endswith("\n") else err + "\n")
    return code


# ---- 1 回の実行 ----

SHIMS = ["multica", "gh", "squad-preflight", "squad-pr-link", "squad-pr-watch", "squad-review-wait",
         "squad-dispatch-pick", "squad-usage-read", "squad-review-next", "squad-usage-wait"]
# 使える道具は、スタブのコマンドの Bash と、作業ディレクトリの中の読み書きに、次の 2 つを足したものにする。
# - エージェントは `cmd; echo "exit=$?"` や `cmd | head` のようにコマンドをつなぐ。dontAsk では、つないだ
#   部分が許可に無いと全体が拒否されるので、読むだけの標準のコマンドも許可する（書き込みや通信はできない）
# - コメントの一時ファイルの片付けのため、`rm` は `.md` のファイルと、tmp/ と ./ の下だけ許可する。
#   Claude Code の許可の書き方では、絶対パスを除けない。作業ディレクトリは使い捨てなので、この幅で足りるとする
SHELL_READERS = ["echo", "printf", "cat", "ls", "head", "tail", "wc", "grep", "jq", "sort", "pwd", "which", "test"]
ALLOWED_TOOLS = ["Bash(multica *)", "Bash(gh *)", "Bash(squad-*)", "Bash(rm *.md)", "Bash(rm -f *.md)", "Bash(rm tmp/*)", "Bash(rm -f tmp/*)", "Bash(rm ./*)", "Bash(rm -f ./*)",
                 *[f"Bash({c} *)" for c in SHELL_READERS], "Bash(pwd)",
                 "Read(./**)", "Edit(./**)"]  # Edit の規則は Write も覆う
BUILTIN_TOOLS = "Bash Read Write Edit"


def build_workdir(instr_dir, run_dir, runtime):
    work = run_dir / "work"
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True)
    if runtime == "claude":
        shutil.copy(instr_dir / "instructions.md", work / "CLAUDE.md")
        skills = work / ".claude" / "skills"
    else:
        shutil.copy(instr_dir / "instructions.md", work / "AGENTS.md")
        skills = work / ".codex" / "skills"
    skills.mkdir(parents=True)
    shutil.copytree(instr_dir / "skills" / "squad-handoff", skills / "squad-handoff")
    (work / "tmp").mkdir()
    bin_dir = run_dir / "bin"
    bin_dir.mkdir(exist_ok=True)
    for name in SHIMS:
        shim = bin_dir / name
        shim.write_text(
            "#!/bin/sh\n"
            f'exec python3 -I -B "{Path(__file__).resolve()}" stub "{name}" "$@"\n'
        )
        shim.chmod(0o755)
    return work, bin_dir


# Multica の実行は、シェルの起動で本物の gh と squad- の見張りの置き場（関所）を PATH の先頭に足す。
# それではスタブより先に本物が呼ばれ、評価の呼び出しが本物の GitHub やタスクへ届くので、
# 評価の実行ではその仕組みを外し、スタブの置き場だけを先頭に置く
# 利用者のシェルの設定（`alias rm='rm -i'` など）も読み込まれないよう、ZDOTDIR は空のディレクトリにする
GATE_ENV = ["BASH_ENV", "CLAUDE_ENV_FILE", "SQUAD_KIT_ALLOWED_REPOS"]


def stub_env(bin_dir):
    env = {k: v for k, v in os.environ.items() if k not in GATE_ENV}
    zdotdir = Path(bin_dir).parent / "zdotdir"
    zdotdir.mkdir(exist_ok=True)
    env["ZDOTDIR"] = str(zdotdir)
    keep = [d for d in env.get("PATH", "").split(":")
            if d and not any(Path(d, n).exists() for n in ("squad-preflight", "squad-pr-link"))]
    env["PATH"] = ":".join([str(bin_dir)] + keep)
    return env


def run_command(cmd, cwd, env, timeout, stdin_text=None):
    try:
        p = subprocess.run(cmd, cwd=cwd, env=env, input=stdin_text, capture_output=True, text=True,
                           timeout=timeout)
    except subprocess.TimeoutExpired:
        return 124, "", f"時間切れ（{timeout} 秒）"
    return p.returncode, p.stdout, p.stderr


def agent_command(runtime, model, thinking, prompt):
    if runtime == "claude":
        return ["claude", "-p", prompt, "--model", model, "--effort", thinking,
                "--setting-sources", "project", "--tools", *BUILTIN_TOOLS.split(),
                "--allowedTools", *ALLOWED_TOOLS, "--permission-mode", "dontAsk",
                "--no-session-persistence", "--strict-mcp-config", "--output-format", "json"]
    return ["codex", "exec", "--skip-git-repo-check", "--sandbox", "workspace-write", "-m", model,
            "-c", f'model_reasoning_effort="{thinking}"', prompt]


def posted_comments(calls):
    return [b for c in calls if c["command"].startswith("multica issue comment add") for b in c.get("bodies", [])]


def scorer_prompt(scene, criterion, calls, response):
    commands = "\n".join(f"- {c['command']}（{c['kind']}、終了コード {c['exit']}）" for c in calls) or "（なし）"
    comments = "\n\n".join(f"--- 投稿 {i + 1} ---\n{b}" for i, b in enumerate(posted_comments(calls))) or "（なし）"
    return (
        f"{SCORER_MARK}\n"
        "あなたは採点の役です。エージェントの 1 回の実行が、次の合格の基準 1 項目を満たすかだけを判定してください。"
        "ファイルは変えず、コマンドも流さないでください。基準にない観点は見ません。\n\n"
        f"## 合格の基準\n{criterion['text']}\n\n"
        f"## エージェントに渡した入力\n{scene['input']}\n\n"
        f"## エージェントが呼んだコマンド\n{commands}\n\n"
        f"## エージェントが投稿したコメント\n{comments}\n\n"
        f"## エージェントの最後の返答\n{response}\n\n"
        '合否と理由を、次の形の JSON だけで返してください。{"pass": true か false, "reason": "1〜2 文"}\n'
    )


def parse_agent_output(text):
    """Claude の JSON の最終結果から、返答とスタブに届かなかった拒否を取り出す。"""
    data = json.loads(text)
    if not isinstance(data, dict) or data.get("type") != "result":
        raise ValueError("type が result ではありません")
    response, denials = data.get("result", ""), data.get("permission_denials")
    if not isinstance(response, str) or not isinstance(denials, list):
        raise ValueError("result または permission_denials の形が違います")
    calls = []
    for denial in denials:
        if not isinstance(denial, dict) or not isinstance(denial.get("tool_input"), dict):
            raise ValueError("拒否された道具の入力が読めません")
        name, tool_input = denial.get("tool_name"), denial["tool_input"]
        if not isinstance(name, str) or (name == "Bash" and not isinstance(tool_input.get("command"), str)):
            raise ValueError("拒否された道具の名前またはコマンドが読めません")
        command = tool_input["command"] if name == "Bash" else f"{name} {json.dumps(tool_input, ensure_ascii=False)}"
        calls.append({**denial, "command": command, "kind": "denied", "exit": None})
    return response, denials, calls, bool(data.get("is_error"))


def parse_score(text):
    for m in re.finditer(r"\{[^{}]*\}", text, re.S):
        try:
            data = json.loads(m.group(0))
        except ValueError:
            continue
        if isinstance(data.get("pass"), bool):
            return data["pass"], str(data.get("reason", ""))
    return None


def run_one(args):
    run_dir = Path(args["out"])
    run_dir.mkdir(parents=True, exist_ok=True)
    scene = parse_scene(Path(args["scenes"]) / args["scene"] / "scene.md")
    instr_dir = Path(args["instructions"]) / args["which"]
    settings = json.loads((Path(args["scenes"]) / args["scene"] / "cli.json").read_text())
    if settings.get("ci_monitor", True) is False:
        instr_dir = instr_dir / "scenes" / args["scene"]
    meta = json.loads((instr_dir / "meta.json").read_text(encoding="utf-8"))
    work, bin_dir = build_workdir(instr_dir, run_dir, args["runtime"])
    calls_path = run_dir / "calls.jsonl"
    calls_path.write_text("")
    env = stub_env(bin_dir)
    env["LEADER_EVAL_CLI"] = str(Path(args["scenes"]) / args["scene"] / "cli.json")
    env["LEADER_EVAL_CALLS"] = str(calls_path)
    env["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] = "1"
    timeout = int(args["timeout"])
    result = {"scene": scene["id"], "type": scene["type"], "which": args["which"], "n": int(args["n"]), "runtime": args["runtime"],
              "model": meta["model"], "thinking_level": meta["thinking_level"]}
    started = time.monotonic()
    code, out, err = run_command(
        agent_command(args["runtime"], meta["model"], meta["thinking_level"], scene["input"]),
        work, env, timeout)
    result.update({"exit_code": code, "duration_ms": round((time.monotonic() - started) * 1000)})
    (run_dir / "agent-output.txt").write_text(out)
    calls = [json.loads(line) for line in calls_path.read_text().splitlines() if line.strip()]
    response = out
    if args["runtime"] == "claude":
        try:
            response, denials, denied_calls, is_error = parse_agent_output(out)
            calls.extend(denied_calls)
            result["permission_denials"] = denials
            if denials or is_error:
                result["error"] = f"道具の呼び出しが {len(denials)} 件拒否されたか、実行が失敗した"
        except (ValueError, TypeError) as e:
            response = ""
            result["error"] = f"実行の JSON が読めなかった: {e}"
    (run_dir / "response.txt").write_text(response)
    result.update({"calls": calls, "comments": posted_comments(calls), "response": response.strip()})
    if code != 0:
        result["error"] = f"実行が終了コード {code} で終わった: {err.strip()[:300]}"
    scorer_env = dict(os.environ)
    graded = []
    for c in scene["criteria"]:
        if c["kind"] == "記録":
            ok, reason = check_record(c["predicate"], calls)
        elif "error" in result:
            ok, reason = False, "実行が失敗したので採点しない"
        else:
            scode, sout, serr = run_command(
                ["claude", "-p", scorer_prompt(scene, c, calls, result["response"]), "--model", SCORER_MODEL,
                 "--effort", SCORER_EFFORT, "--setting-sources", "", "--tools", "",
                 "--no-session-persistence", "--strict-mcp-config", "--output-format", "text"],
                str(run_dir), scorer_env, timeout)
            parsed = parse_score(sout) if scode == 0 else None
            if parsed is None:
                ok, reason = False, f"採点の応答が読めなかった（終了コード {scode}）: {(sout or serr).strip()[:200]}"
                result.setdefault("scorer_errors", []).append(c["n"])
            else:
                ok, reason = parsed
        graded.append({"n": c["n"], "kind": c["kind"], "pass": ok, "reason": reason})
    result["criteria"] = graded
    result["pass"] = "error" not in result and all(g["pass"] for g in graded)
    (run_dir / "result.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    return 0


# ---- 集計 ----

def summary(runs_path, out_path):
    runs = [json.loads(l) for l in Path(runs_path).read_text(encoding="utf-8").splitlines() if l.strip()]
    scenes = {}
    for r in runs:
        s = scenes.setdefault(r["scene"], {"type": r.get("type", ""), "old": [], "new": []})
        s[r["which"]].append(r)
    rows = ["| 場面 | 型 | 今のリーダー | 新しいリーダー | 落ちた基準 |", "| --- | --- | --- | --- | --- |"]

    def cell(items):
        return f"{sum(1 for r in items if r['pass'])}/{len(items)}" if items else "-"

    for sid in sorted(scenes):
        s = scenes[sid]
        # 落ちた基準は新しいリーダーのもの。新しい側を流していない記録（今のリーダーだけ）は、今のリーダーのものを出す
        failed = sorted({g["n"] for r in (s["new"] or s["old"]) for g in r["criteria"] if not g["pass"]})
        rows.append(f"| {sid} | {s['type']} | {cell(s['old'])} | {cell(s['new'])} | "
                    f"{', '.join(map(str, failed)) if failed else '-'} |")
    Path(out_path).write_text("\n".join(rows) + "\n", encoding="utf-8")


def run_all(args):
    from concurrent.futures import ThreadPoolExecutor

    out = Path(args["out"])
    jobs = []
    for sid in args["scene-ids"].split(","):
        for which in args["versions"].split(","):
            for n in range(1, int(args["runs"]) + 1):
                jobs.append((sid, which, n))

    def one(job):
        sid, which, n = job
        opts = dict(args, scene=sid, which=which, n=str(n), out=str(out / "runs" / sid / f"{which}-{n}"))
        run_one(opts)
        verdict = json.loads((Path(opts["out"]) / "result.json").read_text())["pass"]
        print(f"{sid} {which} #{n}: {'合格' if verdict else '不合格'}", file=sys.stderr, flush=True)

    with ThreadPoolExecutor(max_workers=max(1, int(args["jobs"]))) as pool:
        list(pool.map(one, jobs))
    with open(out / "runs.jsonl", "w", encoding="utf-8") as f:
        for sid, which, n in jobs:
            result = (out / "runs" / sid / f"{which}-{n}" / "result.json").read_text()
            f.write(json.dumps(json.loads(result), ensure_ascii=False) + "\n")
    return 0


def parse_options(argv):
    opts = {}
    it = iter(argv)
    for k in it:
        opts[k.lstrip("-")] = next(it)
    return opts


def main(argv):
    cmd = argv[0] if argv else ""
    if cmd == "scene":
        try:
            print(json.dumps(parse_scene(argv[1]), ensure_ascii=False))
        except SceneError as e:
            print(e, file=sys.stderr)
            return 1
        return 0
    if cmd == "stub":
        return stub(argv[1], argv[2:])
    if cmd == "run-one":
        return run_one(parse_options(argv[1:]))
    if cmd == "run-all":
        return run_all(parse_options(argv[1:]))
    if cmd == "summary":
        summary(argv[1], argv[2])
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
