#!/usr/bin/env bash
# docs/supply-chain.md のワークフローの決まりを、YAML のパーサを使わず行で読む。
# CodeQL・Dependabot の決まりは、それぞれを追加するときに広げる。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/workflow-rules.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
python3 -I - "$root/.github/workflows" "$test_dir" <<'PY'
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

workflows, scratch = map(Path, sys.argv[1:])


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def section(lines, key, indent):
    """Return the indented body of a key in the repository's block style."""
    for index, line in enumerate(lines):
        if line == ' ' * indent + key:
            result = []
            for following in lines[index + 1:]:
                if following.strip() and not following.lstrip().startswith('#'):
                    depth = len(following) - len(following.lstrip(' '))
                    if depth <= indent:
                        break
                result.append(following)
            return result
    return []


def job_names(lines):
    return re.findall(r'^  ([A-Za-z0-9_-]+):$', '\n'.join(section(lines, 'jobs:', 0)), re.M)


def check(directory):
    files = sorted([*directory.glob('*.yml'), *directory.glob('*.yaml')])
    require(files, 'ワークフローがない')
    for path in files:
        lines = path.read_text(encoding='utf-8').splitlines()
        uses = [line for line in lines if re.match(r'^\s*(?:- )?uses:', line)]
        require(uses and all(re.fullmatch(r'\s*(?:- )?uses: [A-Za-z0-9._/-]+@[0-9a-f]{40} # v[0-9]+\.[0-9]+\.[0-9]+', line) for line in uses),
                f'{path.name}: uses は完全な SHA と版の注記が必要')
        checkouts = sum('uses: actions/checkout@' in line for line in uses)
        credentials = [index for index, line in enumerate(lines) if re.match(r'^\s*persist-credentials:', line)]
        require(len(credentials) == checkouts, f'{path.name}: checkout と認証設定の数が違う')
        for index in credentials:
            value = lines[index].strip()
            reason = lines[index - 1].strip() if index else ''
            require(value == 'persist-credentials: false' or
                    (value == 'persist-credentials: true' and
                     reason.startswith('# 認証情報を残す理由:') and
                     reason.removeprefix('# 認証情報を残す理由:').strip()),
                    f'{path.name}: 認証情報を残す理由がない')
        require(not any(re.match(r'^\s*(pull_request_target|workflow_run):', line) for line in lines),
                f'{path.name}: 特権のきっかけを使っている')
        secrets = sum('secrets.' in line for line in lines)
        require(not secrets or path.name == 'private-terms.yml', f'{path.name}: 秘密の参照が専用のワークフローの外にある')
        guarded = 0
        for job in job_names(lines):
            body = section(lines, job + ':', 2)
            count = sum('secrets.' in line for line in body)
            if count:
                require('    environment: private-terms' in body, f'{path.name}: 秘密を使うジョブの Environment が違う')
                guarded += count
        require(guarded == secrets, f'{path.name}: 秘密の参照が保護されたジョブの外にある')

    lines = (directory / 'check.yml').read_text(encoding='utf-8').splitlines()
    summary = section(lines, 'checks-passed:', 2)
    require('    if: always()' in summary, 'checks-passed: always() がない')
    needs_lines = [line for line in summary if line.startswith('    needs:')]
    require(len(needs_lines) == 1, 'checks-passed: needs がないか複数ある')
    match = re.fullmatch(r'    needs: \[([A-Za-z0-9_, -]+)\]', needs_lines[0])
    require(match, 'checks-passed: needs が一覧ではない')
    needs = [name.strip() for name in match[1].split(',')]
    require(sorted(needs) == sorted(name for name in job_names(lines) if name != 'checks-passed'),
            'checks-passed: needs がほかの全ジョブと違う')
    require("          RESULTS: ${{ join(needs.*.result, ' ') }}" in summary, 'checks-passed: 結果を受け取っていない')
    script = '\n'.join(section(summary, 'run: |', 8))
    require(script.strip(), 'checks-passed: まとめの判定がない')
    cases = [('success success success', True)]
    for outcome in ('failure', 'cancelled', 'skipped'):
        for position in range(3):
            values = ['success'] * 3
            values[position] = outcome
            cases.append((' '.join(values), False))
    for results, expected in cases:
        run = subprocess.run(['bash', '-c', script], env={**os.environ, 'RESULTS': results}, capture_output=True)
        require((run.returncode == 0) == expected, f'checks-passed: まとめの判定が違う ({results})')
    require('        run: bash tests/check-content.sh --public' in section(lines, 'content:', 2),
            'content: 公開の検査を呼んでいない')

    lines = (directory / 'private-terms.yml').read_text(encoding='utf-8').splitlines()
    events = section(lines, 'on:', 0)
    names = re.findall(r'^  ([a-z_]+):', '\n'.join(events), re.M)
    require(sorted(names) == ['push', 'schedule', 'workflow_dispatch'], 'private-terms: きっかけが違う')
    require(section(events, 'push:', 2) == ['    branches: [main]'], 'private-terms: push が main だけではない')
    require(section(events, 'schedule:', 2) == ["    - cron: '17 3 * * 1'"], 'private-terms: 毎週の予定が違う')
    require(section(lines, 'permissions:', 0) == ['  contents: read'], 'private-terms: 全体の権限が違う')
    require('          FORBIDDEN_TERMS: ${{ secrets.FORBIDDEN_TERMS }}' in lines, 'private-terms: 一覧の Secret を渡していない')
    require('          SQUAD_KIT_FORBIDDEN_FILE="$PWD/tmp/forbidden.txt" bash tests/check-content.sh' in lines,
            'private-terms: 一覧を使う検査を呼んでいない')


check(workflows)
print('PASS workflow-rules: SHA と版・認証・秘密の参照と Environment・きっかけ・公開の検査を確かめた')
print('PASS workflow-rules: まとめが全ジョブを待ち、成功だけを通し、失敗・取り消し・飛ばしを拒む')


def mutate(name, filename, old, new, expected=None):
    directory = scratch / name
    shutil.copytree(workflows, directory)
    path = directory / filename
    text = path.read_text(encoding='utf-8')
    require(old in text, f'書き換える箇所がない: {name}')
    path.write_text(text.replace(old, new, 1), encoding='utf-8')
    if expected is None:
        check(directory)
        return
    try:
        check(directory)
    except AssertionError as error:
        require(expected in str(error), f'別の理由で失敗した: {name}: {error}')
    else:
        raise AssertionError(f'決まりを破る定義を通した: {name}')


pin = 'actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1'
mutate('tag', 'check.yml', pin, 'actions/checkout@v7', 'uses は')
mutate('short-sha', 'check.yml', pin, 'actions/checkout@3d3c42e # v7.0.1', 'uses は')
mutate('missing-version', 'check.yml', pin, pin.split(' #')[0], 'uses は')
mutate('other-workflow', 'release-assets.yml', pin, 'actions/checkout@main', 'uses は')
mutate('missing-credentials', 'check.yml', '          persist-credentials: false\n', '', '認証設定の数')
mutate('unjustified-credentials', 'check.yml', 'persist-credentials: false', 'persist-credentials: true', '認証情報を残す理由')
mutate('justified-credentials', 'check.yml', '          persist-credentials: false',
       '          # 認証情報を残す理由: 確かめ用の例外\n          persist-credentials: true')
mutate('empty-reason', 'check.yml', '          persist-credentials: false',
       '          # 認証情報を残す理由:\n          persist-credentials: true', '認証情報を残す理由')
mutate('missing-always', 'check.yml', '    if: always()\n', '', 'always() がない')
mutate('missing-needs', 'check.yml', 'needs: [scripts, assets, content]', 'needs: [scripts, assets]', 'needs がほかの全ジョブと違う')
mutate('extra-needs', 'check.yml', 'needs: [scripts, assets, content]', 'needs: [scripts, assets, content, other]', 'needs がほかの全ジョブと違う')
mutate('new-job', 'check.yml', '  scripts:', '  other:\n    runs-on: ubuntu-24.04\n    steps:\n      - run: true\n  scripts:', 'needs がほかの全ジョブと違う')
mutate('ignore-failure', 'check.yml', '              exit 1', '              :', 'まとめの判定が違う')
mutate('secret-outside', 'check.yml', 'name: Checks', 'name: ${{ secrets.FORBIDDEN_TERMS }}', '秘密の参照が専用のワークフローの外')
mutate('missing-environment', 'private-terms.yml', '    environment: private-terms\n', '', 'Environment が違う')
mutate('wrong-environment', 'private-terms.yml', 'environment: private-terms', 'environment: other', 'Environment が違う')
mutate('secret-global', 'private-terms.yml', 'name: Private terms', 'name: ${{ secrets.FORBIDDEN_TERMS }}', '保護されたジョブの外')
mutate('secret-unguarded-job', 'private-terms.yml', 'jobs:', 'jobs:\n  other:\n    env:\n      VALUE: ${{ secrets.FORBIDDEN_TERMS }}', 'Environment が違う')
mutate('private-pr', 'private-terms.yml', 'on:', 'on:\n  pull_request:', 'きっかけが違う')
mutate('other-branch', 'private-terms.yml', 'branches: [main]', 'branches: [other]', 'push が main だけではない')
mutate('missing-schedule', 'private-terms.yml', "  schedule:\n    - cron: '17 3 * * 1'\n", '', 'きっかけが違う')
mutate('missing-dispatch', 'private-terms.yml', '  workflow_dispatch:\n', '', 'きっかけが違う')
mutate('pr-target', 'check.yml', '  pull_request:', '  pull_request_target:', '特権のきっかけ')
mutate('workflow-run', 'release-assets.yml', '  workflow_dispatch:', '  workflow_run:', '特権のきっかけ')
mutate('non-public', 'check.yml', 'bash tests/check-content.sh --public', 'bash tests/check-content.sh', '公開の検査を呼んでいない')

extra = scratch / 'new-yaml-workflow'
shutil.copytree(workflows, extra)
(extra / 'extra.yaml').write_text('on:\n  workflow_dispatch:\njobs:\n  probe:\n    steps:\n      - uses: actions/checkout@v7\n', encoding='utf-8')
try:
    check(extra)
except AssertionError as error:
    require('extra.yaml: uses は' in str(error), f'別の理由で失敗した: {error}')
else:
    raise AssertionError('追加した .yaml の固定していない uses を通した')
print('PASS workflow-rules: 理由のある認証の例外を通し、決まりを破る写しを拒む')
PY
