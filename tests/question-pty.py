"""セットアップの質問に、画面の問いごとに答えを送り、端末の出力をそのまま保存する補助。

使い方: question-pty.py <保存先> <答えのファイル> [--size <桁> <行>] [--resize-on <文字列> <桁> <行>]... -- <コマンド...>
入力・標準出力・標準エラー出力を 1 つの疑似端末（既定は 100 桁・40 行、TERM=xterm-256color）につなぐ。--size で最初の大きさを変える。
答えのファイルの 1 行を、問いの印が画面に出て、出力が止まってから 1 行ずつ送る。人が既定値を見てから打つ順にそろえるため、
印の直後には送らない。問いの印は、質問の入力行の「›」、拡張の質問の行末「Enter）: 」、最後の確認の「yes/no）」である。
再入力の問いにも次の行を送る。
--resize-on は、その文字列が出たときに大きさを変えて SIGWINCH を送る。繰り返し指定できる。
流したコマンドの終了コードを返す。30 秒で終わらなければ止めて失敗にする。
"""
import errno
import fcntl
import os
import pty
import re
import select
import signal
import struct
import subprocess
import sys
import termios
import time

output_path, answers_path = sys.argv[1:3]
rest = sys.argv[3:]
resize_events = []
size = (100, 40)
while rest[0] != "--":
    if rest[0] == "--size":
        size = (int(rest[1]), int(rest[2]))
        rest = rest[3:]
    elif rest[0] == "--resize-on":
        resize_events.append((rest[1].encode(), int(rest[2]), int(rest[3])))
        rest = rest[4:]
    else:
        raise ValueError(f"使えない指定: {rest[0]}")
command = rest[1:]
with open(answers_path, "rb") as handle:
    answers = handle.read().splitlines(keepends=True)
PROMPT = re.compile("›|Enter）: |yes/no） ".encode())

master, slave = pty.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", size[1], size[0], 0, 0))
proc = subprocess.Popen(
    command, stdin=slave, stdout=slave, stderr=slave,
    env={**os.environ, "TERM": "xterm-256color"}, start_new_session=True,
)
os.close(slave)
captured = bytearray()
sent = 0
seen_prompts = 0
scanned = 0
status = None
deadline = time.monotonic() + 30
try:
    while True:
        if time.monotonic() >= deadline:
            raise TimeoutError("疑似端末の質問が 30 秒で終わりませんでした")
        ready, _, _ = select.select([master], [], [], 0.15)
        if not ready:
            # 出力が止まった。印が出ていて答えが残っていれば、1 行だけ送る。
            if sent < seen_prompts and sent < len(answers):
                os.write(master, answers[sent])
                sent += 1
            continue
        try:
            data = os.read(master, 4096)
        except OSError as error:
            if error.errno != errno.EIO:
                raise
            data = b""
        if not data:
            break
        captured.extend(data)
        for event in list(resize_events):
            marker, columns, rows = event
            if marker in captured:
                fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))
                try:
                    os.kill(proc.pid, signal.SIGWINCH)
                except ProcessLookupError:
                    pass
                resize_events.remove(event)
        # 印は、読み取りの切れ目をまたいでも 1 回だけ数える。
        found = [match.end() for match in PROMPT.finditer(bytes(captured[scanned:]))]
        if found:
            seen_prompts += len(found)
            scanned += found[-1]
    status = proc.wait(timeout=max(0.1, deadline - time.monotonic()))
finally:
    if status is None:
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
    with open(output_path, "wb") as handle:
        handle.write(captured)
sys.exit(status if status >= 0 else 128 - status)
