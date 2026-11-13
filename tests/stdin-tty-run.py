"""標準入力にファイルをつなぎ、制御端末の有無を選んでコマンドを流す補助。`curl ... | bash` のように、標準入力がパイプで、端末は /dev/tty から開く流れを確認する。

使い方: stdin-tty-run.py <tty|notty> <標準入力のファイル> <答えのファイル> <標準出力の保存先> <標準エラー出力の保存先> -- <コマンド...>
tty は、新しい疑似端末を制御端末にして流し、答えのファイルの中身を端末へ送る（コマンドが /dev/tty から読む）。
notty は、制御端末のない新しいセッションで流す（/dev/tty を開けない）。
標準入力・標準出力・標準エラー出力はどちらもファイルにつなぎ、端末にはつながない。環境変数は呼び出し元のものを渡す。
コマンドの終了コードで終わる（シグナルで終わったときは 128 + シグナル）。
"""
import os
import pty
import sys

mode, stdin_path, answers_path, out_path, err_path = sys.argv[1:6]
assert sys.argv[6] == "--"
command = sys.argv[7:]
assert mode in ("tty", "notty")


def redirect():
    for fd, path, flags in (
        (0, stdin_path, os.O_RDONLY),
        (1, out_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC),
        (2, err_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC),
    ):
        opened = os.open(path, flags, 0o644)
        os.dup2(opened, fd)
        os.close(opened)


if mode == "tty":
    pid, master = pty.fork()
    if pid == 0:
        # 疑似端末の端末側（子の標準入力）を閉じると、制御端末が外れて /dev/tty を開けなくなる環境があるので、別の番号に残す。
        os.dup2(0, 9)
        redirect()
        os.execvp(command[0], command)
    # 疑似端末の入力の行の保持に任せ、コマンドが読み始める前に答えを送る。
    with open(answers_path, "rb") as handle:
        os.write(master, handle.read())
    # 端末の出力（答えの打ち返し）を読み捨てて、コマンドが終わるまで待つ。読まないと、終わるときに端末の出力が捌けず止まる環境がある。
    while True:
        try:
            if not os.read(master, 4096):
                break
        except OSError:
            break
else:
    pid = os.fork()
    if pid == 0:
        os.setsid()
        redirect()
        os.execvp(command[0], command)
_, status = os.waitpid(pid, 0)
if os.WIFSIGNALED(status):
    sys.exit(128 + os.WTERMSIG(status))
sys.exit(os.WEXITSTATUS(status))
