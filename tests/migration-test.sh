#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/migration-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
python3 - "$root" "$test_dir" <<'PY'
import importlib.util
import json
import os
from pathlib import Path
import pty
import select
import shutil
import subprocess
import sys
import time

kit, work = map(Path, sys.argv[1:])
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('migration', kit / 'lib/migrate.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
fixtures = kit / 'tests/fixtures/legacy'
fingerprints = json.loads((kit / 'common/migration/fingerprints.json').read_text())

def fixture(name):
    home = work / name
    (home / 'bin').mkdir(parents=True)
    for monitor in fingerprints['monitors']:
        shutil.copyfile(fixtures / (monitor + '.txt'), home / 'bin' / monitor)
    value = str(home / "allowed repos' file")
    shell = home / 'template/shell/project-a'
    shell.mkdir(parents=True)
    for name in ('.zshenv', 'env.sh'):
        content = (fixtures / (name + '.txt')).read_text().replace('{{ALLOWED_REPOS_FILE}}', value.replace("'", "'\\''"))
        (shell / name).write_text(content)
    return home, value


def run(home, answer=None):
    report = home / 'report.json'
    command = [sys.executable, str(kit / 'lib/migrate.py'), str(kit), str(home), str(report), 'project-a']
    if answer is None:
        result = subprocess.run(command, input=b'yes\n', capture_output=True, timeout=10)
        assert result.returncode == 0, result.stderr.decode()
        return result.stderr.decode(), report
    master, slave = pty.openpty()
    process = subprocess.Popen(command, stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)
    output, sent = b'', False
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if select.select([master], [], [], 0.1)[0]:
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            if not chunk:
                break
            output += chunk
            if b'(\xe6\x97\xa2\xe5\xae\x9a no)' in output and not sent:
                os.write(master, (answer + '\n').encode())
                sent = True
        if process.poll() is not None:
            break
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
        raise AssertionError('migration did not finish: ' + output.decode())
    os.close(master)
    assert process.returncode == 0, output.decode()
    return output.decode(), report


home, value = fixture('accept')
before = {str(p.relative_to(home)): p.read_bytes() for p in home.rglob('*') if p.is_file()}
assert len(module.inspect(kit, home, 'project-a')[0]) == 9
output, report = run(home, 'yes')
backups = list((home / 'backups/initial-migration').iterdir())
assert len(backups) == 1
for name, data in before.items():
    assert (backups[0] / name).read_bytes() == data
for monitor in fingerprints['monitors']:
    assert (home / 'bin' / monitor).read_bytes() == (kit / 'common/monitor' / monitor).read_bytes()
for name in ('.zshenv', 'env.sh'):
    expected = (kit / 'common/shell' / name).read_text().replace('{{ALLOWED_REPOS_FILE}}', value.replace("'", "'\\''"))
    assert (home / 'template/shell/project-a' / name).read_text() == expected
    assert fingerprints['shell_variable'] not in expected
assert json.loads(report.read_text())['retained'] == []
assert str(backups[0]) in output
print('PASS migration: 最終配布物の印なし9ファイルを確認後にバックアップし、原本と旧値を入れたひな形に一致させる')

output, report = run(home, 'yes')
assert '引き継ぎますか' not in output
assert len(list((home / 'backups/initial-migration').iterdir())) == 1
print('PASS migration: 引き継いだ2回目は質問せず、バックアップを増やさない')

for mode in ('decline', 'no-terminal'):
    home, value = fixture(mode)
    before = {str(p.relative_to(home)): p.read_bytes() for p in home.rglob('*') if p.is_file()}
    output, report = run(home, 'no' if mode == 'decline' else None)
    assert len(json.loads(report.read_text())['retained']) == 9
    for name, data in before.items():
        assert (home / name).read_bytes() == data
    assert not (home / 'backups').exists()
    result = subprocess.run([sys.executable, str(kit / 'lib/migrate.py'), '--report', str(report)], capture_output=True, check=True)
    assert '退避してから流し直し' in result.stderr.decode()
print('PASS migration: 拒否と端末なしは変更せず、最後の一覧と対処を出す')

home, _ = fixture('edited')
for path in list((home / 'bin').iterdir()) + list((home / 'template/shell/project-a').iterdir()):
    with path.open('ab') as output:
        output.write(b'\n# personal edit\n')
before = {str(p.relative_to(home)): p.read_bytes() for p in home.rglob('*') if p.is_file()}
output, report = run(home, 'yes')
assert '引き継ぎますか' not in output
assert len(json.loads(report.read_text())['retained']) == 9
for name, data in before.items():
    assert (home / name).read_bytes() == data
print('PASS migration: 手直しした9ファイルは候補にせず、保持して一覧に出す')
PY
