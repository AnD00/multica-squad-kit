#!/usr/bin/env bash
# 公開のテストの準備と照合を共有する。CLI は一時のリポジトリとスタブに置き換える。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/tests/release-assertions.sh"

# 承認する: origin に注釈付きのタグができ、main の先頭を指す。下書きを作り、ワークフローを起こして待ち、確かめて公開する。
make_case approve
main_head=$(git -C "$work" rev-parse HEAD)
run_release "$test_dir/answer-y"
[[ $rc == 0 ]]
[[ $(git -C "$bare" cat-file -t v1.6.0) == tag ]]
[[ $(git -C "$bare" rev-parse 'v1.6.0^{commit}') == "$main_head" ]]
[[ $(git -C "$bare" tag -l --format='%(contents:subject)' v1.6.0) == v1.6.0 ]]
[[ $(git -C "$work" cat-file -t v1.6.0) == tag ]]
[[ $(git -C "$work" rev-parse 'v1.6.0^{commit}') == "$main_head" ]]
[[ $(log_count '^release create') == 1 ]]
log_has '^release create v1.6.0 --repo example/kit --draft --verify-tag --title v1.6.0 --notes-file '
[[ $(<"$case_dir/gh.notes") == "$notes_expected" ]]
log_has '^workflow run release-assets.yml --repo example/kit --ref v1.6.0$'
log_has '^run list --repo example/kit --workflow release-assets.yml --event workflow_dispatch --limit 20 --json databaseId,headBranch,createdAt,event,url --jq '
log_has '^run watch 4242 --repo example/kit --exit-status$'
log_has '^release edit v1.6.0 --repo example/kit --draft=false$'
before_in_log '^release create' '^workflow run'
before_in_log '^workflow run' '^run list'
before_in_log '^run list' '^run watch'
before_in_log '^run watch' 'releases/assets/'
before_in_log 'releases/assets/' '^attestation verify .* --bundle '
before_in_log '^attestation verify .* --bundle ' '^release edit'
# 公開の前に、配布物を 1 回ずつ取得する。
[[ $(log_count 'api -H Accept: application/octet-stream repos/example/kit/releases/assets/') == 4 ]]
# 証明は、タグの install.sh の --verify（束なし、2 つ）と、束での確かめ（3 つ）の 5 回。指定は docs/install.md の 4 つ。
[[ $(log_count '^attestation verify ') == 5 ]]
[[ $(log_count '^attestation verify .* --bundle ') == 3 ]]
for file in install.sh SHA256SUMS multica-squad-kit-v1.6.0.tar.gz; do
	grep -q "^attestation verify .*/$file --bundle .*/multica-squad-kit-v1.6.0.sigstore.json --repo AnD00/multica-squad-kit --signer-workflow AnD00/multica-squad-kit/.github/workflows/release-assets.yml --source-ref refs/tags/v1.6.0 --deny-self-hosted-runners\$" "$case_dir/gh.log"
done
[[ $(draft_flag) == false ]]
grep -qxF '  v1.6.0  example/kit' "$case_dir/out"
grep -qF "  ${main_head:0:12}  Release content" "$case_dir/out"
expect_steps 1
expect_headings 1
grep -qxF '  │ 新しいバージョンの 1 段落目。' "$case_dir/out"
grep -qE "^  ✔ タグを作って push する +v1\.6\.0  ${main_head:0:12}\$" "$case_dir/out"
# 下書きの URL は 6 字の字下げの続きの行で、その次の行が、→ の付いたタグの名前の URL。
grep -A2 -xE '  ✔ 下書きの Release を作る' "$case_dir/out" | tail -n2 | cmp -s - <(printf '      %s\n      → %s\n' "$draft_url" "$published_url")
grep -A1 -E '^  ✔ 発行のワークフローに配布物を作らせ、終わるまで待つ  ' "$case_dir/out" | tail -n1 | grep -qxF "      $run_url"
grep -qE '^  ✔ 発行のワークフローに配布物を作らせ、終わるまで待つ  ([0-9]+s|[0-9]+m[0-9]+s)$' "$case_dir/out"
! grep -qE 'Enumerating objects|Writing objects|To https://|\[new tag\]|Created workflow_dispatch event|To see|JOBS|Set up job|completed with' "$case_dir/out" "$case_dir/err"
expect_verify_rows
expect_summary "$main_head" "$published_url" "$run_url"
# 色は、端末でない出力には付けない。
! grep -q "$(printf '\033')" "$case_dir/out" "$case_dir/err"
grep -qF '公開しますか [y/N]: ' "$case_dir/err"
no_leftover

# 追跡していないファイルは、止める理由にしない。origin の URL の 3 つの形から OWNER/REPO を読む。
for url in https://github.com/example/kit git@github.com:example/kit.git ssh://git@github.com/example/kit.git; do
	make_case "url-$(printf '%s' "$url" | tr -c 'A-Za-z0-9' '_')" "$url"
	printf 'untracked\n' >"$work/untracked.txt"
	run_release "$test_dir/answer-y"
	[[ $rc == 0 ]]
	[[ $(git -C "$bare" cat-file -t v1.6.0) == tag ]]
	log_has '^release create v1.6.0 --repo example/kit '
	[[ $(draft_flag) == false ]]
done

# 承認しない: n、yes、空の答え、入力の終わりでは、何も変えずに 1 で終わる。gh は書き込みも取得もしない。
for answer in n yes empty eof; do
	make_case "decline-$answer"
	before=$(snapshot)
	run_release "$test_dir/answer-$answer"
	[[ $rc == 1 ]]
	no_tag
	no_write
	no_download
	[[ $(snapshot) == "$before" ]]
	grep -qF '公開を取りやめました。' "$case_dir/err"
	no_leftover
done
# 配布物のそろった下書きがあるときも、承認しなければ、確かめも公開もしない。
make_case decline-verify
tag_here
add_release true
seed_assets
before=$(snapshot)
run_release "$test_dir/answer-n"
[[ $rc == 1 ]]
no_write
no_download
log_lacks '^attestation verify'
[[ $(snapshot) == "$before" && $(draft_flag) == true ]]
grep -qF '公開を取りやめました。' "$case_dir/err"

# 確認の前の画面: 確かめの一覧、本文の罫線、見出し、○の手順が、設計のとおり、することの 4 つの状態ごとに出る。
# タグも Release もない: 手順は 5 つ。
make_case screen-tag
screen_commit=$(git -C "$work" rev-parse HEAD)
run_release "$test_dir/answer-n"
[[ $rc == 1 ]]
expect_screen 新規 '手元 なし  origin なし  Release なし' "$screen_commit" 1
# タグだけある: 手順は 4 つ。タグを付けるコミットは、タグが指すコミット。
make_case screen-draft
tag_here
git -C "$work" commit -q --allow-empty -m 'After tag'
git -C "$work" push -q origin main
screen_tag_commit=$(git -C "$work" rev-parse 'v1.6.0^{commit}')
run_release "$test_dir/answer-n"
[[ $rc == 1 ]]
expect_screen 既存 '手元 あり  origin あり（同じ）  Release なし' "$screen_tag_commit" 2
# 配布物のない下書きがある: 手順は 3 つ。
make_case screen-workflow
tag_here
add_release true
screen_tag_commit=$(git -C "$work" rev-parse 'v1.6.0^{commit}')
run_release "$test_dir/answer-n"
[[ $rc == 1 ]]
expect_screen 既存 '手元 あり  origin あり（同じ）  Release 下書き（配布物 0 個）' "$screen_tag_commit" 3
# 配布物のそろった下書きがある: 手順は 2 つ。
make_case screen-verify
tag_here
add_release true
seed_assets
screen_tag_commit=$(git -C "$work" rev-parse 'v1.6.0^{commit}')
run_release "$test_dir/answer-n"
[[ $rc == 1 ]]
expect_screen 既存 '手元 あり  origin あり（同じ）  Release 下書き（配布物 4 個）' "$screen_tag_commit" 4

# 標準入力が端末でない: 問いを出さず、確認を求められないと出して、何も変えない。
make_case notty
before=$(snapshot)
run_release_notty
[[ $rc == 1 ]]
no_tag
no_write
[[ $(snapshot) == "$before" ]]
grep -qF '端末でない' "$case_dir/err"
! grep -qF '公開しますか' "$case_dir/err"
! grep -qF '✔ 道具' "$case_dir/out"
# パイプで y を流し込んでも、確認を飛ばせない。
rc=0
(cd "$work" && printf 'y\n' | env -u BASH_ENV PATH="$test_dir/bin:$PATH" TMPDIR="$case_dir/tmp" /bin/bash scripts/release.sh) >"$case_dir/out" 2>"$case_dir/err" || rc=$?
[[ $rc == 1 ]]
no_tag
no_write

# 確かめで止まるケース: 理由を出し、fetch のほかは何も変えず、タグも Release も作らない。gh は書き込まない。
# expect_stop_keep <理由に含む文字>: 作業コピーに手を入れたあとで流し、止まって何も変えないことを確かめる。タグがあるケース用。
expect_stop_keep() {
	local before
	before=$(snapshot)
	run_release "$test_dir/answer-y"
	[[ $rc == 1 ]]
	no_write
	no_download
	[[ $(snapshot) == "$before" ]]
	grep -qF "$1" "$case_dir/err"
	! grep -qF '公開しますか' "$case_dir/err"
	! grep -qF '✔ 道具' "$case_dir/out"
}
# expect_stop <理由に含む文字>: expect_stop_keep に、手元にも origin にもタグがないことを足す。
expect_stop() {
	expect_stop_keep "$1"
	no_tag
}

# 1: gh のバージョンが古い・読めない。必要なバージョンを出す。
make_case stop-gh-old
GH_VERSION_OUT='gh version 2.101.9 (2026-01-01)' expect_stop 'gh のバージョンが古く'
grep -qF '2.102.0' "$case_dir/err"
make_case stop-gh-unreadable
GH_VERSION_OUT='unknown' expect_stop 'gh のバージョンを読めません'
grep -qF '2.102.0' "$case_dir/err"
make_case stop-gh-fails
GH_VERSION_FAIL=1 expect_stop 'gh のバージョンを読めません'
# 新しいバージョンの gh は通る。
make_case gh-newer
GH_VERSION_OUT='gh version 2.200.7 (2026-06-01)' run_release "$test_dir/answer-y"
[[ $rc == 0 ]]

# 2: origin が GitHub のリポジトリでない
make_case stop-origin
git -C "$work" config remote.origin.url "$bare"
expect_stop 'GitHub のリポジトリではありません'

# 3: main でない
make_case stop-branch
git -C "$work" switch -q -c topic
expect_stop 'main ではありません'
[[ $(git -C "$work" symbolic-ref --short HEAD) == topic ]]

# 4: 追跡しているファイルの未コミットの変更（作業ツリーとインデックス）
make_case stop-dirty
printf 'changed\n' >>"$work/tracked.txt"
expect_stop '未コミットの変更'
git -C "$work" add tracked.txt
expect_stop '未コミットの変更'

# 5: 手元の main が origin/main と一致しない（先行と遅れ）
make_case stop-ahead
git -C "$work" commit -q --allow-empty -m 'Unpublished content'
expect_stop 'origin/main と一致しません'
make_case stop-behind
git clone -q "$bare" "$case_dir/other"
git -C "$case_dir/other" commit -q --allow-empty -m 'Newer content'
git -C "$case_dir/other" push -q origin main
expect_stop 'origin/main と一致しません'

# 6: VERSION の形が vX.Y.Z でない
n=0
for bad in 1.6.0 v1.6 v1.6.0.1 v01.6.0 v1.6.0-rc1 'v1.6.0 ' ''; do
	n=$((n + 1))
	make_case "stop-version-$n"
	printf '%s\n' "$bad" >"$work/VERSION"
	commit_work 'Bad version'
	expect_stop 'vX.Y.Z の形ではありません'
done

# 7: CHANGELOG.md の先頭のバージョンが VERSION と違う
make_case stop-changelog-top
printf 'v1.7.0\n' >"$work/VERSION"
commit_work 'Version only'
expect_stop 'CHANGELOG.md の先頭のバージョン'
grep -qF 'v1.7.0' "$case_dir/err"
grep -qF 'v1.6.0' "$case_dir/err"

# 8: そのバージョンの節が、空白と改行だけ
make_case stop-empty-section
printf '# 変更の記録\n\n## v1.6.0\n\n  \n\n## v1.5.0\n\n古いバージョンの本文。\n' >"$work/CHANGELOG.md"
commit_work 'Empty section'
expect_stop '節が空です'
make_case stop-empty-last-section
printf '# 変更の記録\n\n## v1.6.0\n' >"$work/CHANGELOG.md"
commit_work 'Empty last section'
expect_stop '節が空です'

# 1: 原本のリポジトリのルートでないところに置いたコピーは、流せない。
make_case stop-root
mkdir -p "$case_dir/copy/scripts" "$case_dir/copy/lib"
cp "$root/scripts/release.sh" "$case_dir/copy/scripts/"
cp "$root/lib/ui.sh" "$case_dir/copy/lib/"
rc=0
(cd "$case_dir/copy" && env -u BASH_ENV PATH="$test_dir/bin:$PATH" TMPDIR="$case_dir/tmp" /bin/bash scripts/release.sh) </dev/null >"$case_dir/out" 2>"$case_dir/err" || rc=$?
[[ $rc == 1 ]]
grep -qF 'ルートで流してください' "$case_dir/err"
no_write

# タグがあって Release がない: 承認すると、タグを変えずに、下書きの作成から続ける。
# タグのあとに main に別のコミットがあっても、本文と配布物はタグの中身から作る。
make_case tag-only
tag_here
tag_sha=$(git -C "$work" rev-parse v1.6.0)
tag_commit=$(git -C "$work" rev-parse HEAD)
sed 's/新しいバージョンの 1 段落目。/main のあとの本文。/' "$work/CHANGELOG.md" >"$work/CHANGELOG.new"
mv "$work/CHANGELOG.new" "$work/CHANGELOG.md"
printf 'after the tag\n' >"$work/after.txt"
commit_work 'Content after the tag'
before=$(snapshot)
run_release "$test_dir/answer-y"
[[ $rc == 0 ]]
[[ $(snapshot) == "$before" ]]
[[ $(git -C "$work" rev-parse v1.6.0) == "$tag_sha" && $(git -C "$bare" rev-parse v1.6.0) == "$tag_sha" ]]
[[ $(log_count '^release create') == 1 ]]
[[ $(<"$case_dir/gh.notes") == "$notes_expected" ]]
expect_steps 2
expect_headings 2
grep -qF "  ${tag_commit:0:12}  Release content" "$case_dir/out"
expect_verify_rows
expect_summary "$tag_commit" "$published_url" "$run_url"
[[ $(draft_flag) == false ]]
# 配布物は、main のあとのファイルを含まない（タグの中身から作られている）。
[[ ! -e $case_dir/gh/built/multica-squad-kit-v1.6.0.tar.gz || -z $(tar -tzf "$case_dir/gh/built/multica-squad-kit-v1.6.0.tar.gz" | grep after.txt || true) ]]
# 承認しないときは、何も作らない。
make_case tag-only-decline
tag_here
before=$(snapshot)
run_release "$test_dir/answer-n"
[[ $rc == 1 ]]
no_write
[[ $(snapshot) == "$before" ]]
grep -qF '公開を取りやめました。' "$case_dir/err"

# 配布物のない下書きがある: 承認すると、release create を呼ばず、workflow run から続ける。
make_case draft-empty
tag_here
add_release true
run_release "$test_dir/answer-y"
[[ $rc == 0 ]]
log_lacks '^release create'
[[ $(log_count '^workflow run') == 1 ]]
before_in_log '^workflow run' '^run watch'
before_in_log '^run watch' '^release edit'
expect_steps 3
expect_headings 3
expect_verify_rows
expect_summary "$(git -C "$work" rev-parse v1.6.0^{commit})" "$published_url" "$run_url"
[[ $(draft_flag) == false ]]
no_leftover

# 配布物のそろった下書きがある: 承認すると、workflow run を呼ばず、確かめから続ける。
make_case draft-complete
tag_here
add_release true
seed_assets
run_release "$test_dir/answer-y"
[[ $rc == 0 ]]
log_lacks '^release create'
log_lacks '^workflow run'
log_lacks '^run watch'
[[ $(log_count 'releases/assets/') == 4 ]]
before_in_log 'releases/assets/' '^release edit'
# ワークフローを起こしていないので、実行の一覧は、公開のあとのまとめのためだけに 1 回読む。
[[ $(log_count '^run list') == 1 ]]
before_in_log '^release edit' '^run list'
expect_steps 4
expect_headings 4
expect_verify_rows
# 一覧に実行がないときは、見つからないことを出して、0 で終わる。
expect_summary "$(git -C "$work" rev-parse v1.6.0^{commit})" "$published_url" ''
[[ $(draft_flag) == false ]]
no_leftover

# 確かめから続けるとき、前に成功した実行があれば、最も新しい成功の実行の URL を、まとめに出す。
make_case draft-complete-past-run
tag_here
add_release true
seed_assets
GH_PAST_RUN=1 run_release "$test_dir/answer-y"
[[ $rc == 0 ]]
expect_summary "$(git -C "$work" rev-parse v1.6.0^{commit})" "$published_url" https://github.com/example/kit/actions/runs/4100
# 実行の一覧を読めなくても、止まらずに、見つからないことを出す。公開は済んでいる。
make_case draft-complete-runs-fail
tag_here
add_release true
seed_assets
GH_RUNS_MODE=fail run_release "$test_dir/answer-y"
[[ $rc == 0 ]]
expect_summary "$(git -C "$work" rev-parse v1.6.0^{commit})" "$published_url" ''
[[ $(draft_flag) == false ]]

# gh release edit が URL を返さなくても、公開したタグの URL を案内する。
make_case edit-empty-url
tag_here
add_release true
seed_assets
GH_EDIT_EMPTY=1 run_release "$test_dir/answer-y"
[[ $rc == 0 && $(draft_flag) == false ]]
expect_summary "$(git -C "$work" rev-parse v1.6.0^{commit})" "$published_url" ''

# 配布物が足りないか余分な下書き: 理由と、画面で消すことを出して止まり、何も変えない。
make_case draft-missing
tag_here
add_release true
seed_assets
edit_assets 'map(select(.name != "SHA256SUMS"))'
expect_stop_keep '4 つそろっていないか、余分なものがあります'
grep -qF '下書きの配布物を消してから流し直してください' "$case_dir/err"
grep -qF "$draft_url" "$case_dir/err"
grep -qxF "$draft_note" "$case_dir/err"
[[ $(draft_flag) == true ]]
make_case draft-extra
tag_here
add_release true
seed_assets
edit_assets '. + [{"id": 105, "name": "extra.txt"}]'
expect_stop_keep '4 つそろっていないか、余分なものがあります'
grep -qF 'extra.txt' "$case_dir/err"
make_case draft-duplicate
tag_here
add_release true
seed_assets
edit_assets '. + [{"id": 106, "name": "install.sh"}]'
expect_stop_keep '4 つそろっていないか、余分なものがあります'
make_case draft-partial
tag_here
add_release true
seed_assets
edit_assets 'map(select(.name == "install.sh"))'
expect_stop_keep '4 つそろっていないか、余分なものがあります'

# 公開済み: 問いを出さず、何も変えずに 0 で終わる。標準入力が端末でなくても同じ。配布物のない古い Release も公開済みとして扱う。
make_case published
tag_here
add_release false
before=$(snapshot)
run_release "$test_dir/answer-n"
[[ $rc == 0 ]]
no_write
no_download
[[ $(snapshot) == "$before" ]]
grep -qxF "v1.6.0 のタグと Release は、すでに出してあります: $published_url" "$case_dir/out"
! grep -qF '公開しますか' "$case_dir/err"
! grep -qF '✔ 道具' "$case_dir/out"
run_release_notty
[[ $rc == 0 ]]
no_write
[[ $(snapshot) == "$before" ]]
grep -qF 'すでに出してあります' "$case_dir/out"

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

# 6〜8 は、タグが指すコミットで確かめる。main がそのあとで直っていても、タグの中身が悪ければ止まる。
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

# 公開済みのときも、タグが指すコミットで 6〜8 を確かめてから 0 で終わる。悪ければ、端末でなくても 1 で止まる。
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
# 実行が失敗する: 実行の URL を出し、確かめも release edit もしない。配布物がないので、流し直すと配布物を作らせ直す。
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
# このケースだけ見張りを長く待たせ、実際の PID が消えることを確かめる。
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

echo 'PASS release: 承認・拒否、状態からの再開、公開の処理と中断、完了の表示を確かめた'
