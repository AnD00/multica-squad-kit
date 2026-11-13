#!/usr/bin/env bash
# scripts/release.sh の動きのうち、すでにあるタグと Release の状態、各手順の失敗と流し直し、公開の前の検証の失敗、引数を検証する。
# 準備と補助は tests/release-test-lib.sh、承認・拒否とタグと Release が揃った状態からの続きは tests/release-test.sh、検証で止まるケースは tests/release-check-test.sh にある。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/tests/release-test-lib.sh"

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
no_tag
make_case release-without-tag-published
add_release false
expect_stop_keep 'Release があります'
no_tag

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
grep -qxF 'すること: すでにあるタグのまま、下書きの Release を作り、配布物を作らせて検証し、公開する' "$case_dir/out"
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
log_lacks '^run list'
log_lacks '^release edit'
[[ $(draft_flag) == true ]]
rm -f "$case_dir/gh.log"
run_release "$test_dir/answer-y"
[[ $rc == 0 ]]
log_lacks '^release create'
[[ $(log_count '^workflow run') == 1 ]]
grep -qxF 'すること: すでにある下書きの Release に、配布物を作らせて検証し、公開する' "$case_dir/out"
[[ $(draft_flag) == false ]]

# 起こした実行が、一覧に出るまで間がある: 決まった回数のうちは読み直して、見つかれば続ける。
make_case runs-delayed
GH_RUNS_DELAY=3 run_release "$test_dir/answer-y"
[[ $rc == 0 ]]
[[ $(log_count '^run list') == 4 ]]
[[ $(draft_flag) == false ]]
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
no_download
log_lacks '^release edit'
[[ $(draft_flag) == true ]]
rm -f "$case_dir/gh.log"
run_release "$test_dir/answer-y"
[[ $rc == 0 ]]
log_lacks '^release create'
[[ $(draft_flag) == false ]]

# 公開の前の検証が失敗する: 何が合わなかったかを出し、release edit も削除も呼ばない。下書きと配布物は残り、流し直さないことを出す。
# expect_verify_stop <理由に含む文字>: 配布物のそろった下書きから流して、検証で止まったことを確認する。
expect_verify_stop() {
	run_release "$test_dir/answer-y"
	[[ $rc == 1 ]]
	grep -qF "$1" "$case_dir/err"
	grep -qF '公開しません。下書きと配布物は残してあります。' "$case_dir/err"
	grep -qF '人が確認するまで流し直さないでください。' "$case_dir/err"
	log_lacks '^release \(edit\|delete\)'
	log_lacks '^api -X\|^api --method'
	log_lacks '^workflow run'
	[[ $(draft_flag) == true ]]
	[[ $(jq -r '.[] | select(.tag_name == "v1.6.0") | .assets | length' "$GH_RELEASES") == 4 ]]
	no_leftover
}
# 束での証明が通らない: タグの install.sh の検証（束なし）は通り、配布物ごとの束での検証で止まる。
for file in install.sh SHA256SUMS multica-squad-kit-v1.6.0.tar.gz; do
	make_case "verify-bundle-$file"
	tag_here
	add_release true
	seed_assets
	GH_ATTEST_FAIL=$file GH_ATTEST_FAIL_WITH=bundle expect_verify_stop "証明の束で、$file の証明を検証できませんでした。"
	grep -qF 'stub: attestation failed' "$case_dir/err"
done
# 使う人の入口と同じ検証（束なしの証明）が通らない: タグの install.sh の --verify が止める。
make_case verify-nobundle
tag_here
add_release true
seed_assets
GH_ATTEST_FAIL=SHA256SUMS GH_ATTEST_FAIL_WITH=nobundle expect_verify_stop 'タグの install.sh の --verify が通りませんでした。'
grep -qF '証明を検証できませんでした: SHA256SUMS' "$case_dir/err"
log_lacks '^attestation verify .* --bundle '
# チェックサムが合わない: 配布物が SHA256SUMS と違う。
make_case verify-checksum
tag_here
add_release true
seed_assets sums
expect_verify_stop 'タグの install.sh の --verify が通りませんでした。'
grep -qF 'のチェックサムが、SHA256SUMS と違います' "$case_dir/err"
# 配布物の install.sh がタグと違う（SHA256SUMS は合っている）。
make_case verify-install-differs
tag_here
add_release true
seed_assets install
expect_verify_stop '配布物の install.sh が、タグの install.sh と違います。'
# 配布物の install.sh が SHA256SUMS と違う。
make_case verify-install-sum
tag_here
add_release true
seed_assets install-sum
expect_verify_stop 'install.sh のチェックサムが、SHA256SUMS と違います。'
# 配布物の中身が、git archive で取り出したタグの中身と違う（ほかの検証は通る）。違いの先頭を出す。
make_case verify-content
tag_here
add_release true
seed_assets content
expect_verify_stop '配布物の中身が、git archive で取り出したタグの中身と違います。'
grep -qF 'evil.txt' "$case_dir/err"
# 配布物を取得できない
make_case verify-download
tag_here
add_release true
seed_assets
GH_DL_FAIL=104 expect_verify_stop '配布物を取得できませんでした: multica-squad-kit-v1.6.0.sigstore.json'
# ワークフローを経た流れでも、差し替えられた配布物は公開しない。
make_case verify-after-workflow
GH_TAMPER=content run_release "$test_dir/answer-y"
[[ $rc == 1 ]]
grep -qF '配布物の中身が、git archive で取り出したタグの中身と違います。' "$case_dir/err"
log_lacks '^release edit'
[[ $(draft_flag) == true ]]
! grep -qF 'Release を公開しました' "$case_dir/out"

# 公開が失敗する: 下書きが残り、1 で終わる。流し直すと、配布物を検証し直して公開する。
make_case edit-fails
tag_here
add_release true
seed_assets
GH_EDIT_FAIL=1 run_release "$test_dir/answer-y"
[[ $rc == 1 ]]
grep -qF 'Release の公開に失敗しました。下書きは残してあります。' "$case_dir/err"
[[ $(draft_flag) == true ]]
rm -f "$case_dir/gh.log"
run_release "$test_dir/answer-y"
[[ $rc == 0 ]]
log_lacks '^release create'
log_lacks '^workflow run'
[[ $(log_count 'releases/assets/') == 4 ]]
log_has '^release edit v1.6.0 --repo example/kit --draft=false$'
grep -qxF 'すること: すでにある下書きの Release の配布物を検証し、公開する' "$case_dir/out"
[[ $(draft_flag) == false ]]

# 引数: 知らない引数と余分な引数は、使い方を出して 2 で終わる。--help と -h は、使い方を出して 0 で終わる。
make_case args
for args in "foo" "--yes" "--help extra" "-h --help"; do
	run_release_notty $args
	[[ $rc == 2 ]]
	grep -qF '使い方: bash scripts/release.sh' "$case_dir/err"
	no_tag
	[[ ! -e $case_dir/gh.log ]]
done
for flag in --help -h; do
	run_release_notty "$flag"
	[[ $rc == 0 ]]
	grep -qF '使い方: bash scripts/release.sh' "$case_dir/out"
	no_tag
	[[ ! -e $case_dir/gh.log ]]
done
echo 'PASS release: 検証で止まり、承認でだけ、タグと下書きの Release を作り、ワークフローで配布物を作らせ、検証してから公開する。拒否・端末でない・各手順の失敗と流し直し・公開の前の検証の失敗・すでにあるタグと Release の状態・引数を検証した'
