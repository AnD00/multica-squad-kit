"""疑似端末を使って、標準出力と標準エラー出力ごとの色の判定を確かめる補助。

使い方: ui-pty.py <out|err|both|none> <標準出力の保存先> <標準エラー出力の保存先> -- <コマンド...>
最初の引数で、疑似端末につなぐ出力を選ぶ。選ばなかった出力はパイプにつなぐ。
受け取った内容は、そのまま保存先のファイルに書く。環境変数は呼び出し元のものを渡す。
"""
import errno
import os
import pty
import select
import subprocess
import sys
import time

mode, out_path, err_path = sys.argv[1:4]
assert sys.argv[4] == "--"
command = sys.argv[5:]
assert mode in ("out", "err", "both", "none")


def attach(use_tty):
    if use_tty:
        master, slave = pty.openpty()
        return master, slave
    return None, subprocess.PIPE


out_master, out_target = attach(mode in ("out", "both"))
err_master, err_target = attach(mode in ("err", "both"))
proc = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=out_target, stderr=err_target)
for master, target in ((out_master, out_target), (err_master, err_target)):
    if master is not None:
        os.close(target)

sources = {}
if out_master is not None:
    sources[out_master] = out_path
else:
    sources[proc.stdout.fileno()] = out_path
if err_master is not None:
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
        else:
            del sources[fd]
proc.wait(timeout=30)
for path, data in captured.items():
    with open(path, "wb") as handle:
        handle.write(data)
