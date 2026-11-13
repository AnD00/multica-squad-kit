"""疑似端末を使って、標準出力と標準エラー出力ごとの色の判定を確かめる補助。

使い方: ui-pty.py <out|err|both|none|screen> <最初の保存先> <次の保存先> [--stdin <入力のファイル> | --stdin-tty <入力のファイル>] [--wait-for <問い>] -- <コマンド...>
最初の引数で、疑似端末につなぐ出力を選ぶ。選ばなかった出力はパイプにつなぐ。
--stdin は入力のファイルを標準入力につなぐ（端末ではない）。--stdin-tty は標準入力を疑似端末につなぎ、
ファイルの中身を送ったあとに入力の終わり（Ctrl-D）を送る。標準入力が端末かの判定を通したいときに使う。
screen は入出力を 1 つの疑似端末につなぐ。--stdin-tty <入力> --wait-for <問い> を指定し、問いを待ってから答えを送る。
100 桁・40 行、TERM=xterm-256color で流し、最初の保存先に問いまで、次の保存先に答え以降を保存する。
screen だけは、流したコマンドの終了コードを返す。
--merge-output は both の 2 つの出力を同じ端末につなぎ、最初の保存先へまとめる。
--resize-on <文字列> <桁> <行> は、その文字列が出たときに大きさを変え、SIGWINCH を送る。繰り返し指定できる。
受け取った内容は、そのまま保存先のファイルに書く。環境変数は呼び出し元のものを渡す。
"""
import errno
import fcntl
import os
import pty
import select
import subprocess
import struct
import sys
import signal
import termios
import time

mode, out_path, err_path = sys.argv[1:4]
rest = sys.argv[4:]
stdin_path = None
stdin_tty = False
prompt = None
merge_output = False
resize_events = []
while rest[0] != "--":
    if rest[0] in ("--stdin", "--stdin-tty"):
        stdin_tty = rest[0] == "--stdin-tty"
        stdin_path = rest[1]
        rest = rest[2:]
    elif rest[0] == "--wait-for":
        prompt = rest[1].encode()
        rest = rest[2:]
    elif rest[0] == "--merge-output":
        merge_output = True
        rest = rest[1:]
    elif rest[0] == "--resize-on":
        columns, rows = int(rest[2]), int(rest[3])
        assert columns > 0 and rows > 0
        resize_events.append((rest[1].encode(), columns, rows))
        rest = rest[4:]
    else:
        raise ValueError(f"使えない指定: {rest[0]}")
assert rest[0] == "--"
command = rest[1:]
assert mode in ("out", "err", "both", "none", "screen")
assert not merge_output or mode == "both"


def open_terminal():
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 100, 0, 0))
    return master, slave


resize_seen = bytearray()


def resize_on_output(data, terminals, pid):
    resize_seen.extend(data)
    for event in list(resize_events):
        marker, columns, rows = event
        if marker not in resize_seen:
            continue
        for fd in set(fd for fd in terminals if fd is not None):
            fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))
        try:
            os.kill(pid, signal.SIGWINCH)
        except ProcessLookupError:
            pass
        resize_events.remove(event)


def capture_screen():
    assert stdin_tty and prompt
    with open(stdin_path, "rb") as handle:
        answer = handle.read()
    master, slave = open_terminal()
    proc = subprocess.Popen(
        command, stdin=slave, stdout=slave, stderr=slave,
        env={**os.environ, "TERM": "xterm-256color"}, start_new_session=True,
    )
    os.close(slave)
    before = bytearray()
    after = bytearray()
    answered = False
    finished = False
    deadline = time.monotonic() + 30
    try:
        while True:
            if time.monotonic() >= deadline:
                raise TimeoutError("疑似端末の出力の取得が 30 秒で終わりませんでした")
            ready, _, _ = select.select([master], [], [], 0.1)
            if not ready:
                continue
            try:
                data = os.read(master, 4096)
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                data = b""
            if not data:
                break
            (after if answered else before).extend(data)
            resize_on_output(data, [master], proc.pid)
            if not answered and prompt in before:
                os.write(master, answer)
                answered = True
        status = proc.wait(timeout=max(0.1, deadline - time.monotonic()))
        if not answered:
            raise RuntimeError("疑似端末で問いが見つかりませんでした")
        finished = True
        return status if status >= 0 else 128 - status
    finally:
        if not finished:
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
        os.close(master)
        with open(out_path, "wb") as handle:
            handle.write(before)
        with open(err_path, "wb") as handle:
            handle.write(after)


if mode == "screen":
    # 子の終了コードはそのまま返す。取れなかったとき（時間切れ、問いが出ない）は、子の終了コードと分けて 125 を返す。
    try:
        sys.exit(capture_screen())
    except Exception as error:
        print(f"疑似端末の出力を取れませんでした: {error}", file=sys.stderr)
        sys.exit(125)


def attach(use_tty):
    if use_tty:
        master, slave = open_terminal()
        return master, slave
    return None, subprocess.PIPE


out_master, out_target = attach(mode in ("out", "both"))
err_master, err_target = attach(mode in ("err", "both"))
if merge_output:
    os.close(err_master)
    os.close(err_target)
    err_master, err_target = out_master, out_target
stdin_master = None
if stdin_tty:
    stdin_master, stdin_file = open_terminal()
else:
    stdin_file = open(stdin_path, "rb") if stdin_path else subprocess.DEVNULL
proc = subprocess.Popen(command, stdin=stdin_file, stdout=out_target, stderr=err_target)
if stdin_tty:
    # 端末の入力の行の保持に任せ、コマンドが読み始める前に中身と入力の終わりを送る。
    with open(stdin_path, "rb") as handle:
        os.write(stdin_master, handle.read() + b"\x04")
    os.close(stdin_file)
for target in {target for master, target in ((out_master, out_target), (err_master, err_target)) if master is not None}:
    os.close(target)

sources = {}
if out_master is not None:
    sources[out_master] = out_path
else:
    sources[proc.stdout.fileno()] = out_path
if merge_output:
    pass
elif err_master is not None:
    sources[err_master] = err_path
else:
    sources[proc.stderr.fileno()] = err_path
captured = {out_path: b"", err_path: b""}
deadline = time.time() + 30
while sources and time.time() < deadline:
    ready, _, _ = select.select(list(sources), [], [], 1)
    for fd in ready:
        try:
            data = os.read(fd, 4096)
        except OSError as error:
            # Linux は、端末の相手が閉じると EIO を返す。macOS は空の読み取りを返す。
            if error.errno != errno.EIO:
                raise
            data = b""
        if data:
            captured[sources[fd]] += data
            resize_on_output(data, [out_master, err_master, stdin_master], proc.pid)
        else:
            del sources[fd]
proc.wait(timeout=30)
if stdin_master is not None:
    os.close(stdin_master)
for path, data in captured.items():
    with open(path, "wb") as handle:
        handle.write(data)
