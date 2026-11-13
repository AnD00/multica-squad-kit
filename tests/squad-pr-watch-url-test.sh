#!/usr/bin/env bash
# PR の URL と作業先の照合、不正な入力での停止、正規形だけでの読み・通知を確認する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
source "$root/tests/pr-watch-test-lib.sh"
export MULTICA_AGENT_ID=orchestrator
reset_fixture
python3 - "$test_dir" "$script" <<'PY'
import json, subprocess, sys
from pathlib import Path
work, script = Path(sys.argv[1]), sys.argv[2]
original = json.loads((work / 'task.json').read_text())
pr = 'https://github.com/example/repo/pull/67'

def task(url, repository='example/repo'):
    value = json.loads(json.dumps(original))
    value['metadata']['pr_url'] = url
    if repository is None:
        value['metadata'].pop('repository', None)
    else:
        value['metadata']['repository'] = repository
    (work / 'task.json').write_text(json.dumps(value))

def run(*args):
    return subprocess.run(['bash', script, *args], cwd=work, text=True, capture_output=True)

def forbidden_io():
    assert not (work / 'gh-calls.jsonl').read_text()
    assert not (work / 'posted.jsonl').read_text()
    assert not (work / 'wakeups.jsonl').read_text()

# 一覧よりも先に拒否し、元の入力を行やメンションとして出さない。
invalid = ['https://elsewhere.invalid/example/repo/pull/67',
           'https://github.com@example.invalid/example/repo/pull/67',
           'https://user:pass@github.com/example/repo/pull/67',
           'https://github.com:443/example/repo/pull/67',
           'https://github.com:/example/repo/pull/67',
           'https://github.com/example/../pull/67',
           'https://github.com/example/./pull/67',
           'https://github.com/example/repo/pull/0',
           'https://github.com/example/repo/pull/67suffix',
           'https://github.com/example/[bad]/pull/67', 42]
invalid += [pr + '#INJECTED' + chr(c) + 'mention://member/attacker' for c in (0, 9, 10, 31, 127, 133, 159)]
for url in invalid:
    task(url)
    (work / 'calls.jsonl').write_text('')
    result = run('link-check', 'test-issue')
    assert result.returncode == 0 and result.stdout.startswith('紐付け: 不正な pr_url pr: 表示しない 理由: '), result
    assert len(result.stdout.splitlines()) == 1
    assert 'INJECTED' not in result.stdout + result.stderr and 'attacker' not in result.stdout + result.stderr
    calls = [json.loads(l) for l in (work / 'calls.jsonl').read_text().splitlines()]
    assert not any(c[:2] == ['issue', 'pull-requests'] for c in calls)
    forbidden_io()
print('PASS URL: URL の形、資格情報・ポート、制御文字を一覧の読み取り前に拒み、元の値を出さない')

for repository, expected in [('example/other', 'example/other'), (None, 'なし'), ('', 'なし'),
                             ('bad\nINJECTED', '不正'), ('example/..', '不正')]:
    task(pr, repository)
    result = run('link-check', 'test-issue')
    assert result.returncode == 0 and result.stdout.strip() == f'紐付け: 作業先と違う pr: {pr} 作業先: {expected}', result
    forbidden_io()
print('PASS URL: 作業先の不一致・欠落・不正で止まり、安全な値だけを書く')

for url in ('https://github.com/other/repo/pull/67', pr + '\nINJECTED'):
    task(url)
    for args in [('ci-now', 'test-issue', 'orchestrator', 'trigger-comment'),
                 ('unlinked', 'test-issue', 'trigger-comment')]:
        result = run(*args)
        assert result.returncode == 0 and result.stdout.startswith('紐付け: '), result
        forbidden_io()
    result = run('ci-check', 'test-issue', 'orchestrator', 'monitor')
    assert result.returncode != 0 and 'PR の URL が' in result.stderr and not result.stdout
    forbidden_io()
    result = run('conflicts-check', 'test-issue')
    assert result.returncode == 0 and result.stdout.startswith('コンフリクト: 未確認 head: 不明 理由: PR の URL が'), result
    forbidden_io()
print('PASS URL: ci-now・unlinked・ci-check・conflicts-check は拒否した値で GitHub を読まず書き込まない')

# 一覧の URL にも同じ正規化と制御文字の拒否を当てる。
task(pr)
for url in ('http://GITHUB.COM/Example/Repo/pull/00067/files?diff=1#[x](mention://member/attacker)',
            pr + '\nINJECTED'):
    (work / 'pulls.json').write_text(json.dumps({'pull_requests': [{'html_url': url}]}))
    result = run('link-check', 'test-issue')
    assert result.returncode == 0 and len(result.stdout.splitlines()) == 1, result
    assert 'attacker' not in result.stdout and 'INJECTED' not in result.stdout
    assert ('紐付いている' if '\n' not in url else '未確認') in result.stdout
(work / 'pulls.json').write_text('{"pull_requests": []}')
print('PASS URL: 紐付いた一覧にも同じ検証を行い、元の値を出さない')

# 正規形だけを GitHub へ渡し、知らせにも正規形だけを残す。
task('http://GITHUB.COM/Example/Repo/pull/00067/files?split=1#[x](mention://member/attacker)')
canonical = 'https://github.com/Example/Repo/pull/67'
(work / 'expected-pr-url').write_text(canonical)
result = run('ci-now', 'test-issue', 'orchestrator', 'trigger-comment')
assert result.returncode == 0 and '失敗あり' in result.stdout, result
calls = [json.loads(l) for l in (work / 'gh-calls.jsonl').read_text().splitlines()]
assert calls and all(c[2] == canonical for c in calls)
posts = (work / 'posted.jsonl').read_text()
assert canonical in posts and 'attacker' not in posts and '00067' not in posts and '/files' not in posts
value = json.loads((work / 'task.json').read_text())
value['status'] = 'in_review'
(work / 'task.json').write_text(json.dumps(value))
value = json.loads((work / 'mergeable.json').read_text())
value['mergeable'] = 'CONFLICTING'
(work / 'mergeable.json').write_text(json.dumps(value))
for args in [('conflicts-check', 'test-issue'), ('ci-check', 'test-issue', 'orchestrator', 'monitor'),
             ('unlinked-check', 'test-issue', 'orchestrator')]:
    result = run(*args)
    assert result.returncode == 0, result
calls = [json.loads(l) for l in (work / 'gh-calls.jsonl').read_text().splitlines()]
assert all(c[2] == canonical for c in calls)
posts = (work / 'posted.jsonl').read_text()
assert 'コンフリクトを検出しました。' in posts and 'attacker' not in posts and '/files' not in posts
print('PASS URL: ci-now・ci-check・conflicts-check・unlinked-check の読み取りと知らせに正規形だけを使う')
PY

# マージ待ちに入力が変わっても GitHub は読まず、安全な知らせを 1 回書いて規則を消す。
for value in foreign invalid; do
	reset_fixture
	if [[ $value == foreign ]]; then url=https://github.com/other/repo/pull/67; else url=$'https://github.com/example/repo/pull/67\nINJECTED'; fi
	jq --arg url "$url" '.status="in_review" | .metadata.pr_url=$url' "$test_dir/task.json" >"$test_dir/changed.json"
	mv "$test_dir/changed.json" "$test_dir/task.json"
	fixture issue-wakeups | jq '[. + {id:"mine",instruction:"紐付いていない PR のマージ待ちの見張りで起きました。"}]' >"$test_dir/rules.json"
	# 規則を消せなくても、次の実行では知らせを重ねない。
	echo 'issue wakeup delete' >"$test_dir/fail"
	status=0
	(cd "$test_dir" && bash "$script" unlinked-check test-issue orchestrator monitor) >"$test_dir/output" 2>"$test_dir/error" || status=$?
	[[ $status == 1 && ! -s $test_dir/gh-calls.jsonl ]]
	rm "$test_dir/fail"
	(cd "$test_dir" && bash "$script" unlinked-check test-issue orchestrator monitor) >"$test_dir/output"
	assert_jq -s 'length == 1 and (.[0].body | startswith("PR の URL を確認できませんでした。\n紐付け: "))
		and (.[0].body | contains("mention://squad/test-squad")) and (.[0].body | contains("INJECTED") | not)' "$test_dir/posted.jsonl"
	assert_jq 'length == 0' "$test_dir/rules.json"
	[[ ! -s $test_dir/gh-calls.jsonl ]]
done
echo 'PASS URL: マージ待ちの不一致・不正は GitHub を読まず、重ねずに知らせて規則を消す'
