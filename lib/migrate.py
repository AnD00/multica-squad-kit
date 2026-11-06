"""Adopt only unchanged files from the last unmanaged distribution."""
import datetime
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import sys
import tempfile

MARKERS = (b'# multica-template-managed', b'# multica-squad-kit-managed')


def shell_value(data, variable):
    try:
        text = data.decode('utf-8')
        if text.endswith('\n'):
            text = text[:-1]
        if '\n' in text or '\r' in text:
            return None
        parts = shlex.split(text)
        if len(parts) != 2 or parts[0] != 'export' or not parts[1].startswith(variable + '='):
            return None
        value = parts[1][len(variable) + 1:]
        canonical = "export " + variable + "='" + value.replace("'", "'\\''") + "'"
        return value if text == canonical else None
    except (ValueError, UnicodeError):
        return None


def inspect(kit, home, project_id):
    definitions = json.loads((kit / 'common/migration/fingerprints.json').read_text())
    paths = [(home / 'bin' / name, name) for name in definitions['monitors']]
    shell_root = home / 'template/shell'
    if project_id and shell_root.is_dir() and not shell_root.is_symlink():
        directory = shell_root / project_id
        paths.extend((directory / name, 'shell') for name in ('.zshenv', 'env.sh'))
    candidates, retained = [], []
    for path, kind in paths:
        if not path.exists() and not path.is_symlink():
            continue
        if path.is_symlink() or path.parent.is_symlink() or not path.is_file():
            retained.append(str(path))
            continue
        data = path.read_bytes()
        if any(marker in data.splitlines() for marker in MARKERS):
            continue
        value = shell_value(data, definitions['shell_variable']) if kind == 'shell' else None
        matches = value is not None if kind == 'shell' else hashlib.sha256(data).hexdigest() == definitions['monitors'][kind]
        if matches:
            candidates.append((path, kind, value, data))
        else:
            retained.append(str(path))
    return candidates, retained


def report(path):
    data = json.loads(path.read_text())
    if data['retained']:
        print('保持した管理印のないファイル（中身を確かめ、退避してから流し直してください）:', file=sys.stderr)
        for name in data['retained']:
            print('  ' + name, file=sys.stderr)


def migrate(kit, home, report_path, project_id):
    candidates, retained = inspect(kit, home, project_id)
    print('管理印のない既存ファイルの確認:', file=sys.stderr)
    for path, *_ in candidates:
        print('  引き継ぎ候補: ' + str(path), file=sys.stderr)
    for name in retained:
        print('  一致しないため保持: ' + name, file=sys.stderr)
    state = {'retained': retained + [str(p) for p, *_ in candidates]}
    report_path.write_text(json.dumps(state))
    if not candidates:
        return
    print('候補をバックアップして管理対象へ引き継ぎますか [yes/no] (既定 no): ', end='', file=sys.stderr, flush=True)
    answer = sys.stdin.readline().strip() if sys.stdin.isatty() else ''
    if answer != 'yes':
        print('引き継ぎません。候補は保持します。', file=sys.stderr)
        return
    # Recheck after the human has answered. Never replace a file edited meanwhile.
    for path, _, _, data in candidates:
        if path.is_symlink() or path.parent.is_symlink() or path.read_bytes() != data:
            raise ValueError('確認中にファイルが変わりました。流し直してください。')
    backup_root = home / 'backups/initial-migration'
    backup_root.mkdir(parents=True, exist_ok=True)
    backup = Path(tempfile.mkdtemp(prefix=datetime.datetime.now().strftime('%Y%m%d-%H%M%S-'), dir=backup_root))
    for path, *_ in candidates:
        destination = backup / path.relative_to(home)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, destination)
    print('移行前のバックアップ: ' + str(backup), file=sys.stderr)
    for path, kind, value, _ in candidates:
        if kind == 'shell':
            source = (kit / 'common/shell' / path.name).read_text()
            content = source.replace('{{ALLOWED_REPOS_FILE}}', value.replace("'", "'\\''")).encode()
        else:
            content = (kit / 'common/monitor' / kind).read_bytes()
        descriptor, temporary = tempfile.mkstemp(prefix='.migration-', dir=path.parent)
        try:
            with os.fdopen(descriptor, 'wb') as output:
                output.write(content)
            os.chmod(temporary, 0o600 if kind == 'shell' else 0o755)
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        state['retained'].remove(str(path))
        report_path.write_text(json.dumps(state))
        print('管理対象へ引き継ぎました: ' + str(path), file=sys.stderr)


if __name__ == '__main__':
    os.umask(0o077)
    try:
        if sys.argv[1] == '--report':
            report(Path(sys.argv[2]))
        else:
            migrate(*(Path(p) for p in sys.argv[1:4]), sys.argv[4])
    except (OSError, ValueError) as error:
        print('初回移行: ' + str(error), file=sys.stderr)
        sys.exit(1)
