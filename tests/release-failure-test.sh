#!/usr/bin/env bash
# すでにあるタグと Release の不整合、各手順の失敗・流し直し、中断と片付けを確認する。
# 承認・拒否と再開は release-test.sh、確認で止まるケースは release-check-test.sh、公開前の確認と画面は release-display-test.sh。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/tests/release-assertions.sh"

# 手元だけにタグがある: 公開されていないと出し、消すコマンドを添えて止まる。
make_case tag-local-only
git -C "$work" tag -a v1.6.0 -m v1.6.0
expect_stop_keep 'origin にはありません'
grep -qF 'git tag -d v1.6.0' "$case_dir/err"

# origin だけにタグがある: 取ってくるコマンドを添えて止まり、タグを手元に持ち込まない。
make_case tag-origin-only
tag_here
git -C "$work" tag -d v1.6.0 >/dev/null
expect_stop_keep '手元にはありません'
grep -qF 'git fetch origin tag v1.6.0' "$case_dir/err"
[[ -z $(git -C "$work" tag) ]]

# 手元と origin のタグが違う
make_case tag-differs
tag_here
git -C "$work" tag -d v1.6.0 >/dev/null
git -C "$work" tag -a v1.6.0 -m 'another tag'
[[ $(git -C "$work" rev-parse v1.6.0) != "$(git -C "$bare" rev-parse v1.6.0)" ]]
expect_stop_keep 'タグが違います'

# 注釈付きでないタグ（origin にも同じものがあっても止まる）
make_case tag-lightweight
git -C "$work" tag v1.6.0
git -C "$work" push -q origin refs/tags/v1.6.0
expect_stop_keep '注釈付きではありません'

# タグのない Release: 下書きでも公開済みでも止まる。
make_case release-without-tag
add_release true
expect_stop_keep 'Release があります'
grep -qF "$draft_url" "$case_dir/err"
grep -qxF "$draft_note" "$case_dir/err"
no_tag
make_case release-without-tag-published
add_release false
expect_stop_keep 'Release があります'
no_tag
! grep -qF '→ ' "$case_dir/err"

# 同じタグの Release が 2 つある
make_case release-twice
tag_here
add_release true
add_release false
expect_stop_keep 'Release が GitHub に 2 件あります'

# Release の一覧を読めない: 理由を出して止まる。タグがあっても、ないときも。
make_case list-fails
GH_LIST_FAIL=1 expect_stop 'GitHub から読めません'
grep -qF 'Bad credentials' "$case_dir/err"
make_case list-fails-with-tag
tag_here
GH_LIST_FAIL=1 expect_stop_keep 'GitHub から読めません'

# 6〜8 は、タグが指すコミットで検証する。main がそのあとで直っていても、タグの中身が悪ければ止まる。
make_case tag-commit-version
printf 'v1.5.9\n' >"$work/VERSION"
commit_work 'Other version'
tag_here
printf 'v1.6.0\n' >"$work/VERSION"
commit_work 'Back to the version'
expect_stop_keep 'タグが指すコミットの VERSION'
make_case tag-commit-empty-section
printf '# 変更の記録\n\n## v1.6.0\n\n## v1.5.0\n\n古いバージョンの本文。\n' >"$work/CHANGELOG.md"
commit_work 'Empty section'
tag_here
changelog_default >"$work/CHANGELOG.md"
commit_work 'Fill the section'
expect_stop_keep '節が空です'

# 公開済みのときも、タグが指すコミットで 6〜8 を検証してから 0 で終わる。悪ければ、端末でなくても 1 で止まる。
make_case published-tag-commit-version
printf 'v1.5.9\n' >"$work/VERSION"
commit_work 'Other version'
tag_here
printf 'v1.6.0\n' >"$work/VERSION"
commit_work 'Back to the version'
add_release false
expect_stop_keep 'タグが指すコミットの VERSION'
! grep -qF 'すでに出してあります' "$case_dir/out"
before=$(snapshot)
run_release_notty
[[ $rc == 1 ]]
[[ $(snapshot) == "$before" ]]
grep -qF 'タグが指すコミットの VERSION' "$case_dir/err"
make_case published-tag-commit-changelog-top
printf '# 変更の記録\n\n## v1.5.0\n\n古いバージョンの本文。\n' >"$work/CHANGELOG.md"
commit_work 'Other top version'
tag_here
changelog_default >"$work/CHANGELOG.md"
commit_work 'Fix the changelog'
add_release false
expect_stop_keep 'CHANGELOG.md の先頭のバージョン'
! grep -qF 'すでに出してあります' "$case_dir/out"
make_case published-tag-commit-empty-section
printf '# 変更の記録\n\n## v1.6.0\n\n## v1.5.0\n\n古いバージョンの本文。\n' >"$work/CHANGELOG.md"
commit_work 'Empty section'
tag_here
changelog_default >"$work/CHANGELOG.md"
commit_work 'Fill the section'
add_release false
expect_stop_keep '節が空です'
! grep -qF 'すでに出してあります' "$case_dir/out"
before=$(snapshot)
run_release_notty
[[ $rc == 1 ]]
[[ $(snapshot) == "$before" ]]
grep -qF '節が空です' "$case_dir/err"
# main が先に進んでいても、タグの中身が正しければ、公開済みとして 0 で終わる。
make_case published-after-main-moves
tag_here
add_release false
printf '# 変更の記録\n' >"$work/CHANGELOG.md"
commit_work 'Main moves on'
before=$(snapshot)
run_release_notty
[[ $rc == 0 ]]
no_write
[[ $(snapshot) == "$before" ]]
grep -qF 'すでに出してあります' "$case_dir/out"

# push が失敗する: 手元のタグが消え、Release を作らずに 1 で終わる。
make_case push-fails
printf '#!/bin/sh\nexit 1\n' >"$bare/hooks/pre-receive"
chmod +x "$bare/hooks/pre-receive"
run_release "$test_dir/answer-y"
[[ $rc == 1 ]]
no_tag
no_write
grep -qF 'push に失敗しました' "$case_dir/err"
grep -qF '手元のタグを消したので、流し直せます' "$case_dir/err"
expect_command_output 'git push origin refs/tags/v1.6.0' "$GH_STATE/git-push.log"
grep -qxF '  ✖ タグを作って push する' "$case_dir/out"

# 下書きの作成が失敗する: タグは残り、1 で終わる。流し直すと、タグを変えずに下書きの作成から続ける。
make_case release-fails
GH_CREATE_FAIL=1 run_release "$test_dir/answer-y"
[[ $rc == 1 ]]
[[ $(git -C "$bare" cat-file -t v1.6.0) == tag && $(git -C "$work" cat-file -t v1.6.0) == tag ]]
log_has '^release create'
log_lacks '^workflow run'
grep -qF 'タグは push しましたが、下書きの Release の作成に失敗しました。同じコマンドを流し直すと、下書きの作成から続けます。' "$case_dir/err"
tag_sha=$(git -C "$work" rev-parse v1.6.0)
before=$(snapshot)
rm -f "$case_dir/gh.log"
run_release "$test_dir/answer-y"
[[ $rc == 0 ]]
[[ $(snapshot) == "$before" && $(git -C "$bare" rev-parse v1.6.0) == "$tag_sha" ]]
[[ $(log_count '^release create') == 1 ]]
[[ $(<"$case_dir/gh.notes") == "$notes_expected" ]]
expect_steps 2
[[ $(draft_flag) == false ]]
# タグがあるときの失敗は、タグを push したとは言わず、同じコマンドで流し直せると出す。
make_case release-fails-tag-exists
tag_here
tag_sha=$(git -C "$work" rev-parse v1.6.0)
GH_CREATE_FAIL=1 run_release "$test_dir/answer-y"
[[ $rc == 1 ]]
[[ $(git -C "$work" rev-parse v1.6.0) == "$tag_sha" ]]
grep -qF '下書きの Release の作成に失敗しました。同じコマンドを流し直すと、下書きの作成から続けます。' "$case_dir/err"
! grep -qF 'タグは push しましたが' "$case_dir/err"

# ワークフローを起こせない: 下書きが残り、1 で終わる。流し直すと、下書きの作成を飛ばして、配布物を作らせ直す。
make_case workflow-fails
GH_WORKFLOW_FAIL=1 run_release "$test_dir/answer-y"
[[ $rc == 1 ]]
grep -qF '発行のワークフローを起こせませんでした' "$case_dir/err"
printf 'intentional workflow failure\n' >"$case_dir/workflow-expected"
expect_command_output 'gh workflow run release-assets.yml --repo example/kit --ref v1.6.0' "$case_dir/workflow-expected"
grep -qxF '  ✖ 発行のワークフローに配布物を作らせ、終わるまで待つ' "$case_dir/out"
log_lacks '^run list'
log_lacks '^release edit'
[[ $(draft_flag) == true ]]
rm -f "$case_dir/gh.log"
run_release "$test_dir/answer-y"
[[ $rc == 0 ]]
log_lacks '^release create'
[[ $(log_count '^workflow run') == 1 ]]
expect_steps 3
[[ $(draft_flag) == false ]]

# 起こした実行が、一覧に出るまで間がある: 決まった回数のうちは読み直して、見つかれば続ける。
make_case runs-delayed
GH_RUNS_DELAY=3 GH_WATCH_DELAY=2 RELEASE_RUN_FIND_INTERVAL=1 RELEASE_WATCH_TICK_INTERVAL=1 run_release "$test_dir/answer-y"
[[ $rc == 0 ]]
[[ $(log_count '^run list') == 4 ]]
[[ $(draft_flag) == false ]]
python3 - "$case_dir/out" <<'PY'
from pathlib import Path
import re
import sys
output = Path(sys.argv[1]).read_text()
def seconds(text):
    parts = [int(n) for n in re.findall(r'\d+', text)]
    return parts[0] if len(parts) == 1 else parts[0] * 60 + parts[1]
ticks = re.findall(r'^  … 発行のワークフローに配布物を作らせ、終わるまで待つ  (\S+)$', output, re.M)
assert ticks
elapsed = seconds(re.search(r'^  ✔ 発行のワークフローに配布物を作らせ、終わるまで待つ  (\S+)$', output, re.M)[1])
assert elapsed >= 5  # 実行の一覧を探す 3 秒と、見張りの 2 秒を含む。
assert all(3 <= seconds(tick) <= elapsed for tick in ticks)
PY
no_leftover
# 実行が見つからない: 決まった回数（10 回）で止まり、watch も release edit も呼ばない。
make_case runs-not-found
GH_RUNS_MODE=none run_release "$test_dir/answer-y"
[[ $rc == 1 ]]
[[ $(log_count '^run list') == 10 ]]
grep -qF '一覧に見つかりません' "$case_dir/err"
log_lacks '^run watch'
log_lacks '^release edit'
[[ $(draft_flag) == true ]]
# 条件に合う実行が 2 つ: どれか決められないので止まる。
make_case runs-duplicate
GH_RUNS_MODE=dup run_release "$test_dir/answer-y"
[[ $rc == 1 ]]
grep -qF 'どれか決められません' "$case_dir/err"
log_lacks '^run watch'
log_lacks '^release edit'
# 実行の一覧を読めない
make_case runs-list-fails
GH_RUNS_MODE=fail run_release "$test_dir/answer-y"
[[ $rc == 1 ]]
grep -qF '実行の一覧を読めません' "$case_dir/err"
log_lacks '^release edit'
# 実行が失敗する: 実行の URL を出し、検証も release edit もしない。配布物がないので、流し直すと配布物を作らせ直す。
make_case workflow-run-fails
GH_WATCH_FAIL=1 run_release "$test_dir/answer-y"
[[ $rc == 1 ]]
grep -qF "発行のワークフローが失敗しました: $run_url" "$case_dir/err"
python3 - "$case_dir/err" <<'PY'
from pathlib import Path
import sys
output = Path(sys.argv[1]).read_text()
start = output.index('$ gh run watch 4242 --repo example/kit --exit-status\n')
assert start < output.index('JOBS\n') < output.index("X Run Release assets (4242) completed with 'failure'")
assert output.index("X Run Release assets (4242) completed with 'failure'") < output.index('intentional run failure\n') < output.index('エラー:')
PY
# 失敗した手順は ✖ になり、灰の値に実行の URL が付く。
grep -qxF "  ✖ 発行のワークフローに配布物を作らせ、終わるまで待つ  $run_url" "$case_dir/out"
no_download
log_lacks '^release edit'
[[ $(draft_flag) == true ]]
rm -f "$case_dir/gh.log"
run_release "$test_dir/answer-y"
[[ $rc == 0 ]]
log_lacks '^release create'
[[ $(draft_flag) == false ]]

# 中断すると、裏で待つ見張りも止まり、一時の置き場が残らない。
# このケースだけ見張りを長く待たせ、実際の PID が消えることを確認する。
make_case workflow-interrupt
tag_here
add_release true
export RELEASE_TEST_ORIGINAL_GH="$test_dir/bin/gh-original"
mv "$test_dir/bin/gh" "$RELEASE_TEST_ORIGINAL_GH"
cat >"$test_dir/bin/gh" <<'STUB'
#!/bin/bash
if [[ ${1:-} == run && ${2:-} == watch ]]; then
	printf '%s %s\n' "$$" "$PPID" >"$GH_STATE/watch-process"
	exec sleep 30
fi
exec "$RELEASE_TEST_ORIGINAL_GH" "$@"
STUB
chmod +x "$test_dir/bin/gh"
(
	for ((attempt=0; attempt<200; attempt++)); do
		if [[ -s $GH_STATE/watch-process ]]; then
			read -r watch_process release_process <"$GH_STATE/watch-process"
			kill -TERM "$release_process"
			exit 0
		fi
		sleep 0.1
	done
	exit 1
) &
interrupter=$!
run_release "$test_dir/answer-y"
interrupt_status=0
wait "$interrupter" || interrupt_status=$?
mv "$RELEASE_TEST_ORIGINAL_GH" "$test_dir/bin/gh"
[[ $interrupt_status == 0 && $rc == 143 ]]
read -r watch_process release_process <"$GH_STATE/watch-process"
! kill -0 "$watch_process" 2>/dev/null
[[ $(draft_flag) == true ]]
log_lacks '^release edit'
no_leftover

echo 'PASS release 後半: タグと Release の不整合、各手順の失敗・流し直し、中断と片付けを確認した'
