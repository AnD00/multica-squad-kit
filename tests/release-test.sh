#!/usr/bin/env bash
# scripts/release.sh の動きのうち、承認・拒否と、確かめで止まるケース、タグと Release が揃った状態からの続きを確かめる。
# 準備と補助は tests/release-test-lib.sh、失敗と流し直しは tests/release-failure-test.sh にある。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/tests/release-test-lib.sh"

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
grep -qxF '出すバージョン: v1.6.0' "$case_dir/out"
grep -qF "タグを付けるコミット: $main_head Release content" "$case_dir/out"
grep -qxF 'すること: 注釈付きのタグを作って origin に push し、下書きの Release を作り、配布物を作らせて確かめ、公開する' "$case_dir/out"
grep -qxF '新しいバージョンの 1 段落目。' "$case_dir/out"
grep -qxF "下書きの Release を作りました: $draft_url" "$case_dir/out"
grep -qxF "発行のワークフローを待ちます: $run_url" "$case_dir/out"
grep -qxF '配布物の確かめが通りました。' "$case_dir/out"
grep -qxF "Release を公開しました: $published_url" "$case_dir/out"
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
# パイプで y を流し込んでも、確認を飛ばせない。
rc=0
(cd "$work" && printf 'y\n' | env -u BASH_ENV PATH="$test_dir/bin:$PATH" TMPDIR="$case_dir/tmp" /bin/bash scripts/release.sh) >"$case_dir/out" 2>"$case_dir/err" || rc=$?
[[ $rc == 1 ]]
no_tag
no_write

# 確かめで止まるケース: 理由を出し、fetch のほかは何も変えず、タグも Release も作らない。gh は書き込まない。
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
grep -qxF 'すること: すでにあるタグのまま、下書きの Release を作り、配布物を作らせて確かめ、公開する' "$case_dir/out"
grep -qF "タグを付けるコミット: $tag_commit Release content" "$case_dir/out"
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
grep -qxF 'すること: すでにある下書きの Release に、配布物を作らせて確かめ、公開する' "$case_dir/out"
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
log_lacks '^run list'
log_lacks '^run watch'
[[ $(log_count 'releases/assets/') == 4 ]]
before_in_log 'releases/assets/' '^release edit'
grep -qxF 'すること: すでにある下書きの Release の配布物を確かめ、公開する' "$case_dir/out"
grep -qxF "Release を公開しました: $published_url" "$case_dir/out"
[[ $(draft_flag) == false ]]
no_leftover

# 配布物が足りないか余分な下書き: 理由と、画面で消すことを出して止まり、何も変えない。
make_case draft-missing
tag_here
add_release true
seed_assets
edit_assets 'map(select(.name != "SHA256SUMS"))'
expect_stop_keep '4 つそろっていないか、余分なものがあります'
grep -qF '下書きの配布物を消してから流し直してください' "$case_dir/err"
grep -qF "$draft_url" "$case_dir/err"
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
run_release_notty
[[ $rc == 0 ]]
no_write
[[ $(snapshot) == "$before" ]]
grep -qF 'すでに出してあります' "$case_dir/out"
echo 'PASS release 前半: 承認でだけ公開し、拒否・端末でない・確かめで止まるケース・タグと Release が揃った状態からの続きを確かめた'
