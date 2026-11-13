"""Check pinned Actions against reviewed GitHub advisories and write SARIF."""
import argparse
from dataclasses import dataclass
from datetime import datetime
import html
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import quote


class ScanError(Exception):
    pass


@dataclass(frozen=True)
class Reference:
    path: Path
    line: int
    repo: str
    sha: str
    version: str


@dataclass(frozen=True)
class Finding:
    rule: str
    reference: Reference
    message: str
    severity: str = 'unknown'


def require(condition, message):
    if not condition:
        raise ScanError(message)


def gh(*arguments):
    try:
        result = subprocess.run(['gh', 'api', *arguments], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired, UnicodeError) as error:
        raise ScanError('GitHub API を取得できません') from error
    require(result.returncode == 0, 'GitHub API を取得できません')
    return result.stdout


def references(directory, findings):
    require(directory.is_dir(), 'ワークフローのディレクトリがありません')
    paths = sorted([*directory.glob('*.yml'), *directory.glob('*.yaml')])
    require(paths, 'ワークフローがありません')
    pattern = re.compile(r'([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)(?:/[A-Za-z0-9_./-]+)?@([0-9a-fA-F]{40}) # v([0-9]+\.[0-9]+\.[0-9]+)')
    groups = {}
    for path in paths:
        for number, line in enumerate(path.read_text(encoding='utf-8').splitlines(), 1):
            uses = re.match(r'^\s*(?:-\s+)?uses:\s*(.*?)\s*$', line)
            if not uses or uses[1].startswith('./'):
                continue
            match = pattern.fullmatch(uses[1])
            if not match:
                reference = Reference(path, number, uses[1], '', '')
                findings.append(Finding('version-mismatch', reference, '参照を OWNER/REPO[/PATH]@<40 桁の SHA> # vX.Y.Z で指定してください'))
                continue
            repo, sha, version = match.groups()
            reference = Reference(path, number, repo.lower(), sha.lower(), version)
            groups.setdefault((reference.repo, version), []).append(reference)
    return groups


def affected(version, expression):
    """Compare a stable X.Y.Z to GitHub's comma-separated range bounds.

    Bounds may omit minor/patch and may contain SemVer prerelease/build parts.
    An unreadable bound fails the scan rather than treating it as unaffected.
    """
    current = tuple(map(int, version.split('.')))
    matches = []
    for clause in expression.split(','):
        match = re.fullmatch(r'\s*(>=|<=|>|<|=)\s*(\d+)(?:\.(\d+))?(?:\.(\d+))?(-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?\s*', clause)
        require(match, '勧告のバージョン範囲を読めません')
        operator, major, minor, patch, prerelease = match.groups()
        boundary = (int(major), int(minor or 0), int(patch or 0))
        comparison = (current > boundary) - (current < boundary)
        if comparison == 0 and prerelease:
            comparison = 1  # A stable release follows its prereleases.
        matches.append({'>=': comparison >= 0, '<=': comparison <= 0,
                        '>': comparison > 0, '<': comparison < 0, '=': comparison == 0}[operator])
    return all(matches)


def scan(directory, findings):
    groups = references(directory, findings)
    verified = {}
    for (repo, version), entries in sorted(groups.items()):
        sha = gh(f'repos/{repo}/commits/v{version}', '--jq', '.sha').strip()
        require(re.fullmatch(r'[0-9a-fA-F]{40}', sha), 'タグのコミットを読めません')
        for reference in entries:
            if reference.sha != sha.lower():
                findings.append(Finding('version-mismatch', reference, f'{repo}@v{version} のタグと固定した SHA が一致しません'))
            else:
                verified.setdefault((repo, version), []).append(reference)
    if not verified:
        return
    require(len(verified) <= 1000, '一度に照会できるアクションの数を超えています')
    packages = ','.join(f'{repo}@{version}' for repo, version in sorted(verified))
    pages = json.loads(gh('-X', 'GET', '/advisories', '-f', 'ecosystem=actions', '-f', 'type=reviewed',
                          '-f', 'is_withdrawn=false', '-f', 'affects=' + packages,
                          '-f', 'per_page=100', '--paginate', '--slurp'))
    require(isinstance(pages, list) and pages, '勧告のページを読めません')
    seen = set()
    for page in pages:
        require(isinstance(page, list), '勧告のページが配列ではありません')
        for advisory in page:
            require(isinstance(advisory, dict), '勧告がオブジェクトではありません')
            rule = advisory.get('ghsa_id')
            require(isinstance(rule, str) and re.fullmatch(r'GHSA-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}', rule), '勧告の GHSA ID を読めません')
            summary, severity = advisory.get('summary'), advisory.get('severity')
            require(isinstance(summary, str) and summary, '勧告の要約を読めません')
            require(severity in ('critical', 'high', 'medium', 'low', 'unknown'), '勧告の重大度を読めません')
            require(advisory.get('type') == 'reviewed' and 'withdrawn_at' in advisory, '勧告の審査・取り下げの状態を読めません')
            if advisory['withdrawn_at'] is not None:
                require(isinstance(advisory['withdrawn_at'], str), '勧告の取り下げの時刻を読めません')
                try:
                    datetime.fromisoformat(advisory['withdrawn_at'])
                except ValueError as failure:
                    raise ScanError('勧告の取り下げの時刻を読めません') from failure
                continue
            vulnerabilities = advisory.get('vulnerabilities')
            require(isinstance(vulnerabilities, list) and vulnerabilities, '勧告の対象を読めません')
            for vulnerability in vulnerabilities:
                require(isinstance(vulnerability, dict), '勧告の対象がオブジェクトではありません')
                package = vulnerability.get('package')
                require(isinstance(package, dict) and isinstance(package.get('ecosystem'), str) and
                        isinstance(package.get('name'), str) and package['name'], '勧告のパッケージを読めません')
                if package['ecosystem'] != 'actions':
                    continue
                repo = package['name'].lower()
                expression = vulnerability.get('vulnerable_version_range')
                require(isinstance(expression, str) and expression, '勧告のバージョン範囲を読めません')
                for (candidate, version), entries in verified.items():
                    if candidate != repo or not affected(version, expression):
                        continue
                    for reference in entries:
                        key = (rule, reference)
                        if key not in seen:
                            seen.add(key)
                            findings.append(Finding(rule, reference, f'{repo}@{version}: {summary}', severity))


def sarif(findings, error):
    rules = {}
    results = []
    for finding in findings:
        rule, reference = finding.rule, finding.reference
        if rule not in rules:
            definition = {'id': rule, 'shortDescription': {'text': '注記のバージョンと SHA の不一致' if rule == 'version-mismatch' else finding.message},
                          'defaultConfiguration': {'level': 'error'}}
            if rule != 'version-mismatch':
                definition['helpUri'] = 'https://github.com/advisories/' + rule
                definition['properties'] = {'security-severity': {'critical': '9.0', 'high': '7.0', 'medium': '4.0', 'low': '1.0', 'unknown': '0.0'}[finding.severity]}
            rules[rule] = definition
        uri = quote(Path(os.path.relpath(reference.path)).as_posix(), safe='/')
        results.append({'ruleId': rule, 'level': 'error', 'message': {'text': finding.message},
                        'locations': [{'physicalLocation': {'artifactLocation': {'uri': uri},
                                                           'region': {'startLine': reference.line}}}]})
    invocation = {'executionSuccessful': error is None}
    if error:
        invocation['toolExecutionNotifications'] = [{'level': 'error', 'message': {'text': error}}]
    return {'version': '2.1.0', '$schema': 'https://json.schemastore.org/sarif-2.1.0.json',
            'runs': [{'tool': {'driver': {'name': 'action-advisories', 'rules': list(rules.values())}},
                      'results': results, 'invocations': [invocation]}]}


def cell(value):
    return html.escape(str(value)).replace('|', '&#124;').replace('`', '&#96;').replace('\n', ' ')


def report(findings, error):
    status = f'ERROR action-advisories: {error}' if error else f'{"FAIL" if findings else "PASS"} action-advisories: 検出 {len(findings)} 件'
    rows = [status, '', '| 規則 | アクション | 場所 | 内容 |', '| --- | --- | --- | --- |']
    for finding in findings:
        reference = finding.reference
        rows.append('| ' + ' | '.join(map(cell, (finding.rule, reference.repo,
                                                f'{os.path.relpath(reference.path)}:{reference.line}', finding.message))) + ' |')
    return '\n'.join(rows) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sarif', required=True, type=Path)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    findings = []
    error = None
    try:
        scan(args.directory, findings)
    except (ScanError, OSError, ValueError, UnicodeError) as failure:
        error = str(failure)
    try:
        args.sarif.write_text(json.dumps(sarif(findings, error), ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        summary = report(findings, error)
        print(summary, end='')
        if os.environ.get('GITHUB_STEP_SUMMARY'):
            with open(os.environ['GITHUB_STEP_SUMMARY'], 'a', encoding='utf-8') as output:
                output.write(summary)
    except OSError:
        print('ERROR action-advisories: 検査の結果を書けません', file=sys.stderr)
        return 2
    return 2 if error else int(bool(findings))


if __name__ == '__main__':
    sys.exit(main())
