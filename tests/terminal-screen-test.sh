#!/usr/bin/env bash
# 端末の読み取りと ui-pty.py の指定を、Pillow なしで確認する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/terminal-screen.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
python3 - "$root/tests/ansi-to-png.py" "$test_dir" <<'PY'
import importlib.util
from pathlib import Path
import subprocess
import sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('ansi_to_png', sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
def text(value):
    return module.plain_text(module.terminal_lines(value))
assert text('○ push\r\n○ draft\r\n\x1b[2A\r\x1b[2K✔ push\r\n\x1b[2K✖ draft') == '✔ push\n✖ draft'
assert text('ABCD\rxy') == 'xyCD'
assert text('abcd\r\nstale\r\n\x1b[1A\r\x1b[Jnext') == 'abcd\nnext'
assert text('界\rx') == 'x'
assert text('界\r\nx\x1b[1AQ') == ' Q\nx'
assert text('界\r\nx\x1b[1A\x1b[J') == ''
assert text('a界\r字') == '字'
assert text('x' * 100 + '\r\nZ') == 'x' * 100 + '\nZ'
assert text('x' * 99 + '界') == 'x' * 99 + '\n界'
history = '\r\n'.join(f'line{i}' for i in range(1, 46))
screen = text(history + '\x1b[999A\r\x1b[2KTOP').splitlines()
assert screen[:6] == ['line1', 'line2', 'line3', 'line4', 'line5', 'TOP']
assert len(screen) == 45 and screen[-1] == 'line45'
terminal = module.Terminal()
terminal.feed('old\r\x1b[')
terminal.feed('2K\x1b[1;38;5;28mnew', final=True)
assert module.plain_text(terminal.lines()) == 'new'
assert all(g.bold and g.color == (0, 135, 0) for g in terminal.lines()[0])
p = Path(sys.argv[2])
(p/'cleared').write_text(history + '\x1b[999A\r\x1b[JTOP')
r = subprocess.run([sys.executable,sys.argv[1],str(p/'cleared'),'--text','--last-lines','40'],capture_output=True,text=True)
assert r.returncode == 0 and r.stdout.splitlines() == ['TOP'] + [''] * 39, (r.stdout, r.stderr)
(p/'before').write_bytes(b'header\r\nready: ')
(p/'after').write_bytes(b'y\r\nold\r\n\x1b[1A\r\x1b[2Knew\r\n')
r = subprocess.run([sys.executable,sys.argv[1],str(p/'after'),'--before',str(p/'before'),'--text'],capture_output=True,text=True)
assert r.returncode == 0 and r.stdout == 'ready: y\nnew\n', (r.stdout, r.stderr)
r = subprocess.run([sys.executable,sys.argv[1],str(p/'after'),str(p/'plain'),'--text'],capture_output=True)
assert r.returncode == 0 and (p/'plain').read_text() == 'y\nnew\n'
assert 'PIL' not in sys.modules
PY
echo 'PASS terminal-screen: 行の更新・消去、40 行の境目、全角の半分の消去、前後の出力と文字の保存を確認した'

printf 'y\n' >"$test_dir/answer"
python3 "$root/tests/ui-pty.py" screen "$test_dir/before" "$test_dir/after" \
	--stdin-tty "$test_dir/answer" --wait-for 'ready: ' --resize-on 'resize-here' 72 18 -- python3 -c '
import os,signal,sys,time
assert os.get_terminal_size(1) == (100,40)
resized=[]
signal.signal(signal.SIGWINCH,lambda *_: resized.append(True))
print("resize-here",flush=True)
deadline=time.monotonic()+5
while not resized and time.monotonic()<deadline: time.sleep(0.01)
assert resized and os.get_terminal_size(1)==(72,18)
print("ready: ",end="",flush=True)
assert input()=="y"
os.write(1,b"old\r\n")
os.write(2,b"\x1b[1A\r\x1b[2Knew\r\n")
'
python3 "$root/tests/ansi-to-png.py" "$test_dir/after" --before "$test_dir/before" --text >"$test_dir/plain"
printf 'ready: y\nnew\n' >"$test_dir/expected"
cmp "$test_dir/plain" "$test_dir/expected"
python3 "$root/tests/ui-pty.py" both "$test_dir/out" "$test_dir/err" --merge-output -- python3 -c '
import os,sys
assert os.get_terminal_size(1)==os.get_terminal_size(2)==(100,40)
assert os.ttyname(1)==os.ttyname(2)
print("out",flush=True)
print("err",file=sys.stderr,flush=True)
'
printf 'out\r\nerr\r\n' >"$test_dir/expected"
cmp "$test_dir/out" "$test_dir/expected"
[[ ! -s $test_dir/err ]]
echo 'PASS terminal-screen: 2 つの出力を同じ端末へつなぎ、指定した出力でリサイズして SIGWINCH を送った'
