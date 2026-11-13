#!/usr/bin/env bash
# 一時的な macOS の計測。時間と起動回数は、別のジョブで取る。
# 結果は tmp/measure-tests.*/ に残し、同じ内容を CI のログにも出す。
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 - "$@" <<'PY'
import collections
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path.cwd()
TARGETS = ["tests/setup-version-test.sh", "tests/webhooks-test.sh",
           "tests/project-failure-test.sh"]
if sys.argv[1:] not in (["time"], ["count"]):
    sys.exit("usage: bash tests/measure-tests.sh time|count")
MODE = sys.argv[1]
(ROOT / "tmp").mkdir(exist_ok=True)
OUT = Path(tempfile.mkdtemp(prefix="measure-tests.", dir=ROOT / "tmp"))
ENV = dict(os.environ)
ENV.pop("SQUAD_KIT_TEST_SHARD", None)
ENV.pop("SQUAD_KIT_TEST_JOBS", None)
ENV.pop("BASH_ENV", None)


def command(*args, cwd=ROOT):
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def emit(path):
    print(f"--- {path.relative_to(OUT)} ---", flush=True)
    print(path.read_text(errors="replace"), end="", flush=True)


def measured(label, cwd, args, env, cases=False):
    """run.sh の出力は最後にまとまるので、実行中のログを直接読む。"""
    log = OUT / f"{label}.log"
    clock = OUT / f"{label}.time"
    stamps = OUT / f"{label}.lines"
    before = set((cwd / "tmp").glob("test-run.*"))
    started = time.monotonic()
    reader = None
    pending = b""
    line_count = 0
    with log.open("w") as stdout, clock.open("w") as stderr, stamps.open("w") as lines:
        print(f"MEASURE {label}: {shlex.join(args)}", flush=True)
        proc = subprocess.Popen(["/usr/bin/time", "-p", *args], cwd=cwd,
                                env=env, stdout=stdout, stderr=stderr)
        # ファイルを開いたままにし、run.sh が片付けたあとも最後の行を読む。
        while True:
            if cases and reader is None:
                for run_dir in set((cwd / "tmp").glob("test-run.*")) - before:
                    try:
                        reader = (run_dir / "0/log").open("rb")
                    except FileNotFoundError:
                        continue
                    break
            if reader is not None:
                pending += reader.read()
                while b"\n" in pending:
                    line, pending = pending.split(b"\n", 1)
                    lines.write(f"{time.monotonic() - started:.3f}\t"
                                f"{line.decode(errors='replace')}\n")
                    line_count += 1
            if proc.poll() is not None:
                break
            time.sleep(0.05)
        status = proc.wait()
        if reader is not None:
            pending += reader.read()
            if pending:
                lines.write(f"{time.monotonic() - started:.3f}\t"
                            f"{pending.decode(errors='replace')}\n")
                line_count += 1
            reader.close()
    emit(log)
    emit(clock)
    if cases:
        emit(stamps)
        if line_count == 0:
            raise RuntimeError(f"{label}: 実行中のログを採取できなかった")
    if status:
        raise RuntimeError(f"{label}: exit {status}")


def time_runs():
    cpus = int(command("getconf", "_NPROCESSORS_ONLN"))
    if cpus != 3:
        sys.exit(f"計測には 3 コアが必要です（実際は {cpus}）。time ジョブを再実行してください")
    for test in TARGETS:
        for repeat in (1, 2):
            measured(f"single-{Path(test).stem}-{repeat}", ROOT,
                     ["/bin/bash", "tests/run.sh", test],
                     dict(ENV, SQUAD_KIT_TEST_JOBS="1"), cases=True)

    # run.sh と同じ、重みの降順・名前の順で最小のシャードへ配る。
    weights = {}
    for line in (ROOT / "tests/test-weights").read_text().splitlines():
        if line.strip() and not line.lstrip().startswith("#"):
            name, seconds = line.split()
            weights[name] = int(seconds)
    totals = [0] * 4
    assignments = {}
    for test in sorted((str(p.relative_to(ROOT)) for p in ROOT.glob("tests/*-test.sh")),
                       key=lambda name: (-weights.get(name, 30), name)):
        shard = min(range(4), key=lambda n: totals[n])
        totals[shard] += weights.get(test, 30)
        assignments[test] = shard + 1
    for test in TARGETS:
        print(f"SHARD {test}: {assignments[test]}/4", flush=True)
    for shard in sorted({assignments[test] for test in TARGETS}):
        measured(f"shard-{shard}-of-4", ROOT, ["/bin/bash", "tests/run.sh"],
                 dict(ENV, SQUAD_KIT_TEST_SHARD=f"{shard}/4"))

    old = OUT / "old"
    subprocess.run(["git", "worktree", "add", "--detach", str(old), "d8c425a"],
                   cwd=ROOT, check=True)
    try:
        print(f"OLD_COMMIT {command('git', 'rev-parse', 'HEAD', cwd=old)}", flush=True)
        measured("old-setup-version", old,
                 ["/bin/bash", "tests/run.sh", TARGETS[0]],
                 dict(ENV, SQUAD_KIT_TEST_JOBS="1"), cases=True)
    finally:
        subprocess.run(["git", "worktree", "remove", "--force", str(old)],
                       cwd=ROOT, check=True)

    # 数えるジョブの wrapper は使わず、同じランナーで起動の費用を取る。
    for label, invocation in (("python3", ["python3", "-c", "pass"]),
                              ("jq", ["jq", "-n", "1"]),
                              ("bash", ["/bin/bash", "-c", ":"])):
        measured(f"startup-{label}-100", ROOT,
                 ["/bin/bash", "-c",
                  'for ((i=0; i<100; i++)); do "$@" >/dev/null; done',
                  "measure", *invocation], ENV)


def count_runs():
    tools = {name: shutil.which(name) for name in ("python3", "jq", "shasum", "git", "mktemp")}
    if not all(tools.values()):
        raise RuntimeError(f"必要なコマンドがない: {tools}")
    wrappers = OUT / "bin"
    wrappers.mkdir()
    for name, real in tools.items():
        # 引数の値は記録せず、処理を表す鍵だけを記録する。
        classify = 'key=' + shlex.quote(name) + '\n'
        if name == "python3":
            classify += '''key=python3:interpreter
for arg in "$@"; do
    case $arg in
        -c) key=python3:-c; break ;;
        -) key=python3:stdin; break ;;
        -*) ;;
        *) key="python3:${arg##*/}"; break ;;
    esac
done
'''
        elif name == "shasum":
            classify += '''key=shasum:hash
for arg in "$@"; do
    case $arg in -c|--check) key=shasum:check ;; esac
done
'''
        wrapper = wrappers / name
        wrapper.write_text('#!/bin/bash\n' + classify +
                           'printf "%s\\n" "$key" >>"$SQUAD_MEASURE_COUNTS"\n' +
                           'exec ' + shlex.quote(real) + ' "$@"\n')
        wrapper.chmod(0o755)
    for test in TARGETS:
        name = Path(test).stem
        work = OUT / name
        work.mkdir()
        for folder in ("home", "tmp"):
            (work / folder).mkdir()
        counts = work / "counts"
        counts.touch()
        env = dict(ENV, PATH=f"{wrappers}:{ENV['PATH']}", HOME=str(work / "home"),
                   TMPDIR=str(work / "tmp") + "/", BASH_ENV=str(ROOT / "tests/run-hook.sh"),
                   SQUAD_KIT_TEST_ERROR_FILE=str(work / "error"),
                   SQUAD_MEASURE_COUNTS=str(counts))
        # run.sh は python3 を実体に置き換えるため、数えるときだけ同じ隔離を直接渡す。
        log = work / "test.log"
        with log.open("w") as stdout:
            result = subprocess.run(["/bin/bash", test], cwd=ROOT, env=env,
                                    stdout=stdout, stderr=subprocess.STDOUT)
        emit(log)
        summary = OUT / f"count-{name}.tsv"
        summary.write_text("".join(f"{key}\t{count}\n" for key, count in
                                   sorted(collections.Counter(counts.read_text().splitlines()).items())))
        emit(summary)
        if result.returncode:
            raise RuntimeError(f"{test}: exit {result.returncode}")


print(f"COMMIT {command('git', 'rev-parse', 'HEAD')}", flush=True)
print(f"MODE {MODE}\nOUTPUT {OUT.relative_to(ROOT)}", flush=True)
print(f"CPUS {command('getconf', '_NPROCESSORS_ONLN')}", flush=True)
for key in ("hw.model", "machdep.cpu.brand_string"):
    print(f"{key}: {command('sysctl', '-n', key)}", flush=True)
if MODE == "time":
    time_runs()
else:
    count_runs()
PY
