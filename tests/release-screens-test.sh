#!/usr/bin/env bash
# 画面を画像にする仕組みの、出力を取るところまでを確かめる。PNG と Pillow は CI には要らない。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/release-screens-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
printf 'y\n' >"$test_dir/answer"

# 3 つの入出力が同じ端末で、端末の大きさ・TERM が決まり、問いのあとで初めて入力が届く。
python3 "$root/tests/ui-pty.py" screen "$test_dir/probe-confirm" "$test_dir/probe-after" \
	--stdin-tty "$test_dir/answer" --wait-for 'ready: ' -- python3 -c '
import os, select, sys
assert all(os.isatty(fd) for fd in (0, 1, 2))
assert len({os.ttyname(fd) for fd in (0, 1, 2)}) == 1
assert os.get_terminal_size(1) == (100, 40)
assert os.environ["TERM"] == "xterm-256color"
assert not select.select([sys.stdin], [], [], 0)[0]
print("out", flush=True)
print("err", file=sys.stderr, flush=True)
print("ready: ", end="", flush=True)
assert input() == "y"
print("done", flush=True)
'
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
assert (p / 'probe-confirm').read_bytes() == b'out\r\nerr\r\nready: '
assert (p / 'probe-after').read_bytes() == b'y\r\ndone\r\n'
PY
echo 'PASS release-screens: 同じ疑似端末で入出力を順に取り、100 桁と問いのあとの入力を確かめた'

bash "$root/tests/release-screens.sh" "$root/scripts/release.sh" "$test_dir/screens" --capture-only
python3 - "$test_dir/screens" "$root/CHANGELOG.md" <<'PY'
from pathlib import Path
import re
import sys
screens, changelog = map(Path, sys.argv[1:])
notes = changelog.read_text().split('## v1.10.0\n', 1)[1].split('\n## ', 1)[0].strip()
ansi = re.compile(rb'\x1b\[[0-9;]*m')
for scene, expected in ((1, 0), (2, 0), (3, 1), (4, 1), (5, 0)):
    assert (screens / f'{scene}-status').read_text().strip() == str(expected), scene
    before = (screens / f'{scene}-confirm.ansi').read_bytes()
    after = (screens / f'{scene}-after.ansi').read_bytes()
    assert before.endswith('公開しますか [y/N]: '.encode()), scene
    assert notes in ansi.sub(b'', before).decode().replace('\r\n', '\n'), scene
    assert after.startswith(b'y\r\n'), scene
    assert b'\x1b[' in before if scene != 5 else b'\x1b' not in before + after
    plain = ansi.sub(b'', after).decode().replace('\r\n', '\n')
    if expected == 0:
        assert 'v1.6.0 の Release を公開しました' in plain, scene
        assert ('[1/3]' if scene == 2 else '[1/5]') in plain, scene
        assert '待っています（経過 ' in plain, scene
    elif scene == 3:
        assert '【gh run watch の出力 ここから】' in plain
        assert "completed with 'failure'" in plain
    else:
        assert '【install.sh --verify の出力 ここから】' in plain
        assert 'stub: attestation failed' in plain
assert not list(screens.glob('*.png'))
PY
echo 'PASS release-screens: 5 場面の終了コード、問い、長い本文、色、成功と失敗の画面を取れた'
