#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-pr-watch-ci-handoff-test.sh で実行する。
# CLI を差し替え、実際のタスク・PR・エージェントには書き込まない。ci-check と ci-held の投稿順序・引き継ぎ後の失敗・古い head・CLI の失敗を確認する。
# 保留・知らせ済みの記録・取得の条件は tests/squad-pr-watch-ci-test.sh にある。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

source "$root/tests/pr-watch-test-lib.sh"

# 保留の判定後、最終投稿前に引き継ぎが届く順序を再現する。
# 引き継いだ役の run がまだ running でも、保留記録なしで失敗を拾う。
reset_fixture
fixture issue-runs direct | jq '. as $base | [$base + {"agent_id": "fixer", "status": "running"}]' >"$test_dir/runs.json"
late_hold=$(cd "$test_dir" && bash "$script" ci-check test-issue orchestrator monitor)
[[ $late_hold == $'/note\nCI abcdef0: 失敗あり（demo-codex-fixer-test の作業中なので保留）' ]]
check_held $'CI / test\nexternal'
jq --slurpfile base "$test_dir/comment-prototype.json" --arg body "$late_hold" '. + [$base[0] + {author_type: "agent", content: $body, test_thread: "ci-thread"}]' \
	"$test_dir/comments.json" >"$test_dir/updated.json"
mv "$test_dir/updated.json" "$test_dir/comments.json"
check_held '' next-handoff
printf '[]' >"$test_dir/runs.json"
check_ci $'/note\nCI abcdef0: 失敗は知らせ済み'
assert_jq -s 'length == 1 and (.[0].body | startswith("/note\n"))' "$test_dir/posted.jsonl"
echo 'PASS 投稿順序: 保留の最終投稿より先に取得しても失敗を拾い、遅れた保留で再通知しない'

# 引き継ぎ時はまだ CI が実行中で、その直後に失敗が確定する順序。
# run の終了前でも、起点の run と対応する引き継ぎがあれば通常の通知に進む。
for handoff in mention squad-mention review-report; do
	reset_fixture
	fixture issue-runs direct | jq '. as $base | [$base + {"id": "fixer-run", "agent_id": "fixer", "status": "running"}]' >"$test_dir/runs.json"
	fixture issue-comments agent | jq '. as $base | [$base + {"author_type": "agent", "author_id": "fixer", "source_task_id": "fixer-run", "content": "[@demo-orchestrator-test](mention://agent/orchestrator) 引き継ぎます", "test_thread": "handoff-thread"}]' >"$test_dir/comments.json"
	if [[ $handoff == review-report ]]; then
		jq '.[0].content = "/note\n確認したコミット: abcdef0123456789\nレビュー結果"' \
			"$test_dir/comments.json" >"$test_dir/updated.json"
		mv "$test_dir/updated.json" "$test_dir/comments.json"
	elif [[ $handoff == squad-mention ]]; then
		jq '.[0].content = "[@Demo](mention://squad/test-squad) 引き継ぎます"' \
			"$test_dir/comments.json" >"$test_dir/updated.json"
		mv "$test_dir/updated.json" "$test_dir/comments.json"
	fi
	cp "$test_dir/pr.json" "$test_dir/failed-pr.json"
	jq --slurpfile base "$test_dir/check-prototype.json" '.statusCheckRollup = [$base[0] + {status:"IN_PROGRESS",conclusion:null,name:"test"}]' \
		"$test_dir/pr.json" >"$test_dir/updated.json"
	mv "$test_dir/updated.json" "$test_dir/pr.json"
	check_held ''
	mv "$test_dir/failed-pr.json" "$test_dir/pr.json"
	check_ci $'/note\nCI abcdef0: 失敗をリーダーに知らせた'
	assert_jq -s 'length == 1 and (.[0].body | startswith("head: abcdef0\n"))' "$test_dir/posted.jsonl"
	check_held ''
done
echo 'PASS 引き継ぎ後の失敗: 取得時に未確定でも、引き継ぎ（スクワッドかエージェントのメンション）・レビュー報告後の run の終了前に通常の通知で拾う'

for fixture in old-run other-author no-mention new-run other-squad old-report-name; do
	reset_fixture
	fixture issue-runs direct | jq '. as $base | [$base + {"id": "fixer-run", "agent_id": "fixer", "status": "running"}]' >"$test_dir/runs.json"
	jq --slurpfile base "$test_dir/comment-prototype.json" -n --arg fixture "$fixture" '[$base[0] + {author_type: "agent", author_id: "fixer",
		source_task_id: "fixer-run", content: "[@demo-orchestrator-test](mention://agent/orchestrator) 引き継ぎます"}]
		| if $fixture == "old-run" then .[0].source_task_id = "old-fixer-run"
		  elif $fixture == "other-author" then .[0].author_id = "implementer"
		  elif $fixture == "no-mention" then .[0].content = "/note\n途中の記録"
		  elif $fixture == "other-squad" then .[0].content = "[@Demo](mention://squad/other-squad) 引き継ぎます"
		  elif $fixture == "old-report-name" then .[0].content = "/note\n\u78ba\u304b\u3081\u305f\u30b3\u30df\u30c3\u30c8: abcdef0123456789\nレビュー結果" else . end' >"$test_dir/comments.json"
	if [[ $fixture == new-run ]]; then
		jq --slurpfile base "$test_dir/run-prototype.json" '. + [$base[0] + {id: "new-fixer-run", agent_id: "fixer", status: "running"}]' \
			"$test_dir/runs.json" >"$test_dir/updated.json"
		mv "$test_dir/updated.json" "$test_dir/runs.json"
	fi
	check_ci $'/note\nCI abcdef0: 失敗あり（demo-codex-fixer-test の作業中なので保留）'
	[[ ! -s $test_dir/posted.jsonl ]]
done
echo 'PASS 引き継ぎの対応: 別の run・別の作者・別のスクワッド・途中の記録・前の行名のレビュー報告では作業中の保留を解除しない'

# 古い head の取得記録では、今の head の失敗を抑止しない。
reset_fixture
hold_fixture
check_held $'CI / test\nexternal'
jq '.headRefOid = "123456789abcdef0"' "$test_dir/pr.json" >"$test_dir/updated.json"
mv "$test_dir/updated.json" "$test_dir/pr.json"
check_held $'CI / test\nexternal' next-handoff
check_held '' third-handoff
assert_jq -s 'length == 2 and (.[1].body | contains("CI 1234567:"))' "$test_dir/posted.jsonl"
echo 'PASS ci-held: 古い head の取得記録があっても今の head の失敗は取得する'

for fixture in notified success pending cancelled no-checks merged closed done no-thread; do
	reset_fixture
	hold_fixture
	case $fixture in
	notified) jq --slurpfile base "$test_dir/comment-prototype.json" '. + [$base[0] + {author_type: "agent", content: "head: abcdef0\nCI の失敗を検出しました。\n"}]' "$test_dir/comments.json" >"$test_dir/updated.json"; mv "$test_dir/updated.json" "$test_dir/comments.json" ;;
	success | pending | cancelled | no-checks)
		case $fixture in
		success) checks='[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]' ;;
		pending) checks='[{"__typename":"StatusContext","state":"PENDING","context":"external"}]' ;;
		cancelled) checks='[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"CANCELLED"}]' ;;
		no-checks) checks='[]' ;;
		esac
		jq --slurpfile base "$test_dir/check-prototype.json" --argjson checks "$checks" '.statusCheckRollup = ($checks | map(if .__typename == "CheckRun" then $base[0] + . else . end))' "$test_dir/pr.json" >"$test_dir/updated.json"; mv "$test_dir/updated.json" "$test_dir/pr.json"
		;;
	merged | closed) jq --arg state "$(printf '%s' "$fixture" | tr '[:lower:]' '[:upper:]')" '.state = $state' "$test_dir/pr.json" >"$test_dir/updated.json"; mv "$test_dir/updated.json" "$test_dir/pr.json" ;;
	done) jq '.status_category = "done"' "$test_dir/task.json" >"$test_dir/updated.json"; mv "$test_dir/updated.json" "$test_dir/task.json" ;;
	no-thread) jq 'del(.metadata.ci_watch_thread)' "$test_dir/task.json" >"$test_dir/updated.json"; mv "$test_dir/updated.json" "$test_dir/task.json" ;;
	esac
	check_held ''
	[[ ! -s $test_dir/posted.jsonl ]]
done
echo 'PASS ci-held: 知らせ済み・失敗なし・終了済みでは何も出さない'

# CLI の失敗で通知したり、引き継ぎを受けたと答えたりしない。
for operation in runs held; do
	reset_fixture
	if [[ $operation == runs ]]; then
		printf 'issue runs test-issue' >"$test_dir/fail"
		args=(ci-check test-issue orchestrator monitor)
	else
		hold_fixture
		printf 'issue comment add' >"$test_dir/fail"
		printf 'handoff-comment' >"$test_dir/allowed-parent"
		args=(ci-held test-issue handoff-comment)
	fi
	if (cd "$test_dir" && bash "$script" "${args[@]}") >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
	[[ $(<"$test_dir/error") == 'CLI mock failure' && ! -s $test_dir/output && ! -s $test_dir/posted.jsonl ]]
	rm "$test_dir/fail"
	if [[ $operation == held ]]; then check_held $'CI / test\nexternal'; fi
done
echo 'PASS CLI 失敗: エラーを返し、受けた記録を書けなかった保留は再取得できる'

# 各実行で読んだ URL を検証し、不正な値ではチェック名も取得記録も出さない。
for invalid in absent null empty foreign control shape no-repository bad-repository; do
	reset_fixture
	case $invalid in
	absent) filter='del(.metadata.pr_url)' ;;
	null) filter='.metadata.pr_url=null' ;;
	empty) filter='.metadata.pr_url=""' ;;
	foreign) filter='.metadata.pr_url="https://github.com/other/private/pull/67"' ;;
	control) filter='.metadata.pr_url="https://github.com/example/repo/pull/67\nINJECTED"' ;;
	shape) filter='.metadata.pr_url="https://example.invalid/example/repo/pull/67"' ;;
	no-repository) filter='del(.metadata.repository)' ;;
	bad-repository) filter='.metadata.repository="example/.."' ;;
	esac
	jq "$filter" "$test_dir/task.json" >"$test_dir/updated.json"
	mv "$test_dir/updated.json" "$test_dir/task.json"
	status=0
	(cd "$test_dir" && bash "$script" ci-held test-issue handoff-comment) >"$test_dir/output" 2>"$test_dir/error" || status=$?
	[[ $status != 0 && ! -s $test_dir/output && ! -s $test_dir/posted.jsonl && ! -s $test_dir/gh-calls.jsonl ]]
	case $invalid in
	absent | null | empty) expected='metadata に pr_url がない' ;;
	foreign | no-repository | bad-repository) expected='PR の URL が作業先と違う' ;;
	*) expected='PR の URL が不正' ;;
	esac
	[[ $(<"$test_dir/error") == "$expected" ]]
done
echo 'PASS ci-held: 欠落・不一致・不正は固定の理由で失敗し、GitHub・チェック名・取得記録を出さない'

# 検証前の早期終了は、URL が不正でも成功のままにする。
for early in done cancelled absent null empty; do
	reset_fixture
	case $early in
	done | cancelled) filter=".status_category=\"$early\"" ;;
	absent) filter='del(.metadata.ci_watch_thread)' ;;
	null) filter='.metadata.ci_watch_thread=null' ;;
	empty) filter='.metadata.ci_watch_thread=""' ;;
	esac
	jq "$filter | .metadata.pr_url=\"invalid\"" "$test_dir/task.json" >"$test_dir/updated.json"
	mv "$test_dir/updated.json" "$test_dir/task.json"
	check_held ''
	[[ ! -s $test_dir/gh-calls.jsonl && ! -s $test_dir/posted.jsonl ]]
done
echo 'PASS ci-held: 終了済みと記録先なしでは検証前に何も出さず成功する'

reset_fixture
jq '.metadata.pr_url="http://GITHUB.COM/Example/Repo/pull/00067/files?view=split#ignored"' "$test_dir/task.json" >"$test_dir/updated.json"
mv "$test_dir/updated.json" "$test_dir/task.json"
printf '%s' 'https://github.com/Example/Repo/pull/67' >"$test_dir/expected-pr-url"
check_held $'CI / test\nexternal'
assert_jq -s 'length == 1 and .[0][2] == "https://github.com/Example/Repo/pull/67"' "$test_dir/gh-calls.jsonl"
assert_jq -s 'length == 1 and (.[0].body | startswith("/note\nCI abcdef0:"))' "$test_dir/posted.jsonl"
echo 'PASS ci-held: 正規形でだけ読み、従来どおりチェック名と取得記録を返す'
