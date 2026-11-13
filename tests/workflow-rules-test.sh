#!/usr/bin/env bash
# docs/supply-chain.md のワークフローの決まりを、YAML のパーサを使わず行で読む。
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


def action_body(lines, action):
    headers = [line for line in lines if line.startswith('      - uses: ' + action + '@')]
    require(len(headers) == 1, f'codeql: {action} の手順がないか複数ある')
    return section(lines, headers[0].strip(), 6)


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

    lines = (directory / 'scan.yml').read_text(encoding='utf-8').splitlines()
    events = section(lines, 'on:', 0)
    names = re.findall(r'^  ([a-z_]+):', '\n'.join(events), re.M)
    require(sorted(names) == ['pull_request', 'push', 'schedule'], 'scan: きっかけが違う')
    require(section(events, 'push:', 2) == ['    branches: [main]'], 'scan: push が main だけではない')
    require(section(events, 'schedule:', 2) == ["    - cron: '23 4 * * 1'"], 'scan: 毎週の予定が違う')
    require(section(lines, 'permissions:', 0) == ['  contents: read'], 'scan: 全体の権限が違う')
    codeql = section(lines, 'codeql:', 2)
    require('    runs-on: ubuntu-24.04' in codeql, 'codeql: 実行場所が違う')
    require('    timeout-minutes: 15' in codeql, 'codeql: 時間の上限が違う')
    require(section(codeql, 'permissions:', 4) == ['      contents: read', '      security-events: write'],
            'codeql: 解析を登録する権限が違う')
    strategy = section(codeql, 'strategy:', 4)
    require('      fail-fast: false' in strategy, 'codeql: ほかの言語の解析を取り消す')
    require(section(strategy, 'matrix:', 6) == ['        language: [actions, python]'], 'codeql: 対象の言語が違う')
    init = action_body(codeql, 'github/codeql-action/init')
    require('          languages: ${{ matrix.language }}' in init, 'codeql: 言語を初期化に渡していない')
    require('          build-mode: none' in init, 'codeql: ビルドのモードが違う')
    analyze = action_body(codeql, 'github/codeql-action/analyze')
    require('          category: /language:${{ matrix.language }}' in analyze, 'codeql: 解析の分類が言語別ではない')

    advisories = section(lines, 'action-advisories:', 2)
    require('    runs-on: ubuntu-24.04' in advisories, 'action-advisories: 実行場所が違う')
    require('    timeout-minutes: 5' in advisories, 'action-advisories: 時間の上限が違う')
    require(section(advisories, 'permissions:', 4) == ['      contents: read', '      security-events: write'],
            'action-advisories: 解析を登録する権限が違う')
    require(not any(line.startswith('    if:') for line in codeql + advisories), 'scan: 解析のジョブを条件で飛ばす')
    require('          GH_TOKEN: ${{ github.token }}' in advisories, 'action-advisories: API のトークンを渡していない')
    require('        run: python3 -I tests/check-action-advisories.py --sarif action-advisories.sarif .github/workflows' in advisories,
            'action-advisories: 勧告の検査を呼んでいない')
    upload = section(advisories, '- if: always()', 6)
    require(any(line.startswith('        uses: github/codeql-action/upload-sarif@') for line in upload),
            'action-advisories: SARIF の登録が always() ではない')
    require(section(upload, 'with:', 8) == ['          sarif_file: action-advisories.sarif', '          category: action-advisories'],
            'action-advisories: SARIF のファイルか分類が違う')

    dependabot = directory.parent / 'dependabot.yml'
    require(dependabot.is_file(), 'dependabot: 設定がない')
    lines = dependabot.read_text(encoding='utf-8').splitlines()
    require('version: 2' in lines, 'dependabot: 設定の版が違う')
    updates = section(lines, 'updates:', 0)
    require([line for line in updates if line.startswith('  - package-ecosystem:')] == ['  - package-ecosystem: github-actions'],
            'dependabot: 対象が github-actions ではない')
    require('    directory: /' in updates, 'dependabot: 対象のディレクトリが違う')
    require(section(updates, 'schedule:', 4) == ['      interval: weekly'], 'dependabot: 更新が毎週ではない')
    require(section(updates, 'cooldown:', 4) == ['      default-days: 7'], 'dependabot: 更新を 7 日待たない')
    groups = section(updates, 'groups:', 4)
    require(section(groups, 'actions:', 6) == ["        patterns: ['*']"], 'dependabot: 更新を 1 つにまとめていない')


check(workflows)
print('PASS workflow-rules: SHA と版・認証・秘密の参照と Environment・きっかけ・公開の検査を確かめた')
print('PASS workflow-rules: まとめが全ジョブを待ち、成功だけを通し、失敗・取り消し・飛ばしを拒む')
print('PASS workflow-rules: CodeQL の言語・きっかけ・権限と、Dependabot の週次・待機・まとめを確かめた')
print('PASS workflow-rules: 勧告の検査も同じきっかけで流し、失敗しても SARIF を登録する')


def copy_configuration(name):
    directory = scratch / name / 'workflows'
    shutil.copytree(workflows, directory)
    shutil.copyfile(workflows.parent / 'dependabot.yml', directory.parent / 'dependabot.yml')
    return directory


def mutate(name, filename, old, new, expected=None):
    directory = copy_configuration(name)
    path = directory.parent / filename if filename == 'dependabot.yml' else directory / filename
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

mutate('scan-missing-pr', 'scan.yml', '  pull_request:\n', '', 'scan: きっかけが違う')
mutate('scan-missing-schedule', 'scan.yml', "  schedule:\n    - cron: '23 4 * * 1'\n", '', 'scan: きっかけが違う')
mutate('scan-other-branch', 'scan.yml', 'branches: [main]', 'branches: [other]', 'scan: push が main だけではない')
mutate('scan-daily', 'scan.yml', "cron: '23 4 * * 1'", "cron: '23 4 * * *'", 'scan: 毎週の予定が違う')
mutate('scan-global-write', 'scan.yml', '  contents: read', '  contents: write', 'scan: 全体の権限が違う')
mutate('codeql-runner', 'scan.yml', 'runs-on: ubuntu-24.04', 'runs-on: ubuntu-latest', 'codeql: 実行場所が違う')
mutate('codeql-timeout', 'scan.yml', 'timeout-minutes: 15', 'timeout-minutes: 30', 'codeql: 時間の上限が違う')
mutate('codeql-permissions', 'scan.yml', 'security-events: write', 'security-events: read', 'codeql: 解析を登録する権限が違う')
mutate('codeql-fail-fast', 'scan.yml', 'fail-fast: false', 'fail-fast: true', 'codeql: ほかの言語の解析を取り消す')
mutate('codeql-languages', 'scan.yml', 'language: [actions, python]', 'language: [python]', 'codeql: 対象の言語が違う')
mutate('codeql-init-language', 'scan.yml', 'languages: ${{ matrix.language }}', 'languages: python', 'codeql: 言語を初期化に渡していない')
mutate('codeql-build', 'scan.yml', 'build-mode: none', 'build-mode: manual', 'codeql: ビルドのモードが違う')
mutate('codeql-analyze', 'scan.yml', 'uses: github/codeql-action/analyze@', 'uses: github/codeql-action/init@', '手順がないか複数ある')
mutate('codeql-category', 'scan.yml', 'category: /language:${{ matrix.language }}', 'category: codeql', 'codeql: 解析の分類が言語別ではない')
mutate('codeql-tag', 'scan.yml', 'github/codeql-action/init@33d7b85da1a04171e211befe2c739303b9a4c066 # v4.39.3',
       'github/codeql-action/init@v4', 'uses は')
mutate('scan-credentials', 'scan.yml', '          persist-credentials: false\n', '', '認証設定の数')
mutate('dependabot-version', 'dependabot.yml', 'version: 2', 'version: 1', 'dependabot: 設定の版が違う')
mutate('dependabot-ecosystem', 'dependabot.yml', 'package-ecosystem: github-actions', 'package-ecosystem: npm', 'dependabot: 対象が github-actions ではない')
mutate('dependabot-directory', 'dependabot.yml', 'directory: /', 'directory: /other', 'dependabot: 対象のディレクトリが違う')
mutate('dependabot-schedule', 'dependabot.yml', 'interval: weekly', 'interval: daily', 'dependabot: 更新が毎週ではない')
mutate('dependabot-cooldown', 'dependabot.yml', 'default-days: 7', 'default-days: 0', 'dependabot: 更新を 7 日待たない')
mutate('dependabot-groups', 'dependabot.yml', "patterns: ['*']", "patterns: ['actions/checkout']", 'dependabot: 更新を 1 つにまとめていない')

mutate('advisories-missing', 'scan.yml', '  action-advisories:', '  other-advisories:', 'action-advisories: 実行場所が違う')
mutate('advisories-runner', 'scan.yml', '  action-advisories:\n    runs-on: ubuntu-24.04',
       '  action-advisories:\n    runs-on: ubuntu-latest', 'action-advisories: 実行場所が違う')
mutate('advisories-timeout', 'scan.yml', 'timeout-minutes: 5', 'timeout-minutes: 6', 'action-advisories: 時間の上限が違う')
mutate('advisories-permissions', 'scan.yml', 'timeout-minutes: 5\n    permissions:\n      contents: read\n      security-events: write',
       'timeout-minutes: 5\n    permissions:\n      contents: read\n      security-events: read', 'action-advisories: 解析を登録する権限が違う')
mutate('advisories-conditional', 'scan.yml', '  action-advisories:', '  action-advisories:\n    if: false', 'scan: 解析のジョブを条件で飛ばす')
mutate('advisories-token', 'scan.yml', '          GH_TOKEN: ${{ github.token }}\n', '', 'action-advisories: API のトークンを渡していない')
mutate('advisories-command', 'scan.yml', 'tests/check-action-advisories.py --sarif', 'tests/check-action-advisories.py --other', 'action-advisories: 勧告の検査を呼んでいない')
mutate('advisories-always', 'scan.yml', '      - if: always()', '      - if: success()', 'action-advisories: SARIF の登録が always() ではない')
mutate('advisories-sarif', 'scan.yml', 'sarif_file: action-advisories.sarif', 'sarif_file: other.sarif', 'action-advisories: SARIF のファイルか分類が違う')
mutate('advisories-category', 'scan.yml', 'category: action-advisories', 'category: other', 'action-advisories: SARIF のファイルか分類が違う')

extra = copy_configuration('new-yaml-workflow')
(extra / 'extra.yaml').write_text('on:\n  workflow_dispatch:\njobs:\n  probe:\n    steps:\n      - uses: actions/checkout@v7\n', encoding='utf-8')
try:
    check(extra)
except AssertionError as error:
    require('extra.yaml: uses は' in str(error), f'別の理由で失敗した: {error}')
else:
    raise AssertionError('追加した .yaml の固定していない uses を通した')
print('PASS workflow-rules: 理由のある認証の例外を通し、決まりを破る写しを拒む')
PY
