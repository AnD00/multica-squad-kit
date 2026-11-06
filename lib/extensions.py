"""Validate additive project extensions and materialize their combined templates."""
import json
import re
import shutil
import sys
from pathlib import Path


def fail(message):
    raise ValueError(message)


def fields(text):
    if not text.startswith('---\n') or '\n---\n' not in text:
        fail('front matter がありません')
    front, body = text[4:].split('\n---\n', 1)
    result = {}
    for line in front.splitlines():
        if ': ' not in line:
            fail('front matter は一行の値にしてください')
        key, value = line.split(': ', 1)
        if key in result:
            fail('front matter のキーが重複しています')
        result[key] = value
    return result, body


def key(value):
    return bool(re.fullmatch(r'[a-z]+(?:-[a-z]+)*', value))


def materialize(kit, extension, target):
    if any(p.is_symlink() for p in extension.rglob('*')):
        fail('拡張にシンボリックリンクがあります')
    if (extension / 'kit-version').read_text().strip() != (kit / 'VERSION').read_text().strip():
        fail('拡張が求める原本の版と、流している版が違います')
    allowed = {'kit-version', 'agents', 'additions.json', 'instructions', 'autopilots.md', 'monitor', 'skills', 'link-repositories.json'}
    if any(p.name not in allowed for p in extension.iterdir()):
        fail('未知の拡張の項目です')
    links_path = extension / 'link-repositories.json'
    links = json.loads(links_path.read_text()) if links_path.exists() else []
    if not isinstance(links, list) or any(
        not isinstance(repo, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9_.-]+', repo)
        or repo.split('/')[1] in ('.', '..') for repo in links
    ):
        fail('link-repositories.json は OWNER/REPO の配列にしてください')
    for name in ('common', 'skeleton'):
        shutil.copytree(kit / name, target / name)
    (target / 'extension-link-repositories.json').write_text(json.dumps(list(dict.fromkeys(repo.lower() for repo in links))))
    extra_roles = []
    for p in sorted((extension / 'agents').glob('*.md')):
        if not key(p.stem) or (kit / 'common/agents' / p.name).exists():
            fail('原本の役は置き換えられません')
        text = p.read_text()
        # Common templates also allow conditional front matter; validate at rendering.
        if '{{project_key}}-' + p.stem + '-{{member_key}}' not in text:
            fail('拡張の役の名前が規則と違います')
        shutil.copy2(p, target / 'common/agents' / p.name)
        extra_roles.append(p.stem)
    (target / 'extension-roles').write_text(' '.join(extra_roles))
    additions_path = extension / 'additions.json'
    additions = json.loads(additions_path.read_text()) if additions_path.exists() else {}
    if not isinstance(additions, dict):
        fail('additions.json はオブジェクトにしてください')
    mcp = {}
    for role, patch in additions.items():
        p = target / 'common/agents' / (role + '.md')
        if not key(role) or not p.is_file() or not isinstance(patch, dict):
            fail('追記する役がありません')
        if set(patch) - {'skills', 'mcp_config', 'max_concurrent_tasks', 'instructions_file'}:
            fail('追記で原本の指示やモデルを置き換えることはできません')
        text = p.read_text()
        # Edit individual scalar lines without interpreting conditional blocks.
        if 'skills' in patch:
            skills = patch['skills']
            if not isinstance(skills, list) or any(not isinstance(s, str) or not key(s) for s in skills):
                fail('追加スキルの名前が不正です')
            text, count = re.subn(r'^skills: (.*)$', lambda m: 'skills: ' + ', '.join(dict.fromkeys(m[1].split(', ') + skills)), text, flags=re.M)
            if count != 1:
                fail('追記先の skills は一行にしてください')
        if 'max_concurrent_tasks' in patch:
            limit = patch['max_concurrent_tasks']
            if type(limit) is not int or not 1 <= limit <= 50:
                fail('同時実行の上限が不正です')
            if re.search(r'^max_concurrent_tasks: ', text, flags=re.M):
                text = re.sub(r'^max_concurrent_tasks: .*$', f'max_concurrent_tasks: {limit}', text, flags=re.M)
            else:
                text = text.replace('\n---\n', f'\nmax_concurrent_tasks: {limit}\n---\n', 1)
        if 'mcp_config' in patch:
            if not isinstance(patch['mcp_config'], dict):
                fail('MCP の設定はオブジェクトにしてください')
            mcp[role] = patch['mcp_config']
        if 'instructions_file' in patch:
            name = patch['instructions_file']
            if not isinstance(name, str):
                fail('追記のファイル名が不正です')
            instruction = extension / name
            if not instruction.resolve().is_relative_to((extension / 'instructions').resolve()) or not instruction.is_file():
                fail('追記は instructions の下のファイルにしてください')
            text += '\n' + instruction.read_text() + '\n'
        p.write_text(text)
    (target / 'extension-mcp.json').write_text(json.dumps(mcp))
    if (extension / 'autopilots.md').exists():
        p = target / 'common/autopilots.md'
        p.write_text(p.read_text() + '\n' + (extension / 'autopilots.md').read_text())
    for p in (extension / 'monitor').glob('*'):
        if not re.fullmatch(r'squad-[a-z]+(?:-[a-z]+)*', p.name) or not p.is_file() or (kit / 'common/monitor' / p.name).exists():
            fail('原本の見張りは置き換えられません')
        if '# multica-squad-kit-managed' not in p.read_text().splitlines():
            fail('拡張の見張りに管理の印がありません')
        shutil.copy2(p, target / 'common/monitor' / p.name)
    for p in (extension / 'skills').glob('*'):
        if not key(p.name) or p.name.startswith('squad-') or not p.is_dir():
            fail('プロジェクトのスキルの置き場所が不正です')
        front, _ = fields((p / 'SKILL.md').read_text())
        if front.get('name') != p.name:
            fail('プロジェクトのスキル名が置き場所と違います')
        destination = target / 'skeleton/.agents/skills' / p.name
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(p, destination)
    (target / 'extension-skills').write_text('\n'.join(p.name for p in (extension / 'skills').glob('*')))


if __name__ == '__main__':
    try:
        materialize(*(Path(p).resolve() for p in sys.argv[1:]))
    except (OSError, ValueError, TypeError) as error:
        print(f'拡張: {error}', file=sys.stderr)
        sys.exit(1)
