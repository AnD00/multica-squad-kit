#!/usr/bin/env bash
# 承認・拒否と、タグと Release の状態からの再開を確認する。
# 確認で止まるケースは release-check-test.sh、途中の失敗は release-failure-test.sh、画面は release-display-test.sh。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/tests/release-assertions.sh"

# 承認する: origin に注釈付きのタグができ、main の先頭を指す。下書きを作り、ワークフローを起こして待ち、検証して公開する。
make_case approve
main_head=$(git -C "$work" rev-parse HEAD)
run_release "$test_dir/answer-y"
[[ $rc == 0 ]]
grep -qF '検証の 9' "$case_dir/out"
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
# 証明は、タグの install.sh の --verify（束なし、2 つ）と、束での検証（3 つ）の 5 回。指定は docs/install.md の 4 つ。
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
# 配布物のそろった下書きがあるときも、承認しなければ、検証も公開もしない。
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

# 確認の前の画面: 確認の一覧、本文の罫線、見出し、○の手順が、設計のとおり、することの 4 つの状態ごとに出る。
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

# 配布物のそろった下書きがある: 承認すると、workflow run を呼ばず、検証から続ける。
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

# 確認から続けるとき、前に成功した実行があれば、最も新しい成功の実行の URL を、まとめに出す。
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

echo 'PASS release 前半: 承認でだけ公開し、拒否・端末でない・タグと Release が揃った状態からの続きを確認した'
