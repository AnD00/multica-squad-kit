#!/usr/bin/env bash
# scripts/release.sh の動きを、一時の Git のリポジトリとスタブの gh で確かめる。
# origin は一時の bare のリポジトリで、本物の GitHub には push せず、Release もワークフローの実行も作らない。
# 設計は docs/release.md の「テストと CI」。スタブの gh は、Release の一覧を JSON の状態として持ち、
# release create、run watch、release edit で状態を動かす。配布物は、スタブが scripts/build-assets.sh をタグに流して作る。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/release.XXXXXX")
# 標準エラーを err に向けたまま止まっても、trap が err 自身へ書き足し続けないよう、元の標準エラーを控えて出す。
exec 8>&2
trap 'test_exit=$?; if [[ $test_exit != 0 ]]; then for log in "$test_dir"/*/out "$test_dir"/*/err "$test_dir"/*/gh.log; do [[ -f $log ]] && { echo "--- $log" >&8; cat "$log" >&8; }; done; fi; rm -rf -- "$test_dir"' EXIT
source "$root/tests/release-test-lib.sh"

printf 'y\n' >"$test_dir/answer-y"
printf 'n\n' >"$test_dir/answer-n"
printf '\n' >"$test_dir/answer-empty"
: >"$test_dir/answer-eof"
printf 'yes\n' >"$test_dir/answer-yes"

# gh の呼び方の記録（gh.log）を読む道具。
log_count() { grep -c -- "$1" "$case_dir/gh.log" || true; }
# log_has / log_lacks <正規表現>: 呼ばれた / 呼ばれていない。
log_has() { [[ -f $case_dir/gh.log ]] && grep -q -- "$1" "$case_dir/gh.log"; }
log_lacks() { [[ ! -f $case_dir/gh.log ]] || ! grep -q -- "$1" "$case_dir/gh.log"; }
# before_in_log <先の正規表現> <後の正規表現>: 先の最初の呼び出しが、後の最初の呼び出しより前にある。
before_in_log() {
	local a b
	a=$(grep -n -m1 -- "$1" "$case_dir/gh.log" | cut -d: -f1 || true)
	b=$(grep -n -m1 -- "$2" "$case_dir/gh.log" | cut -d: -f1 || true)
	[[ -n $a && -n $b && $a -lt $b ]]
}
# no_write: GitHub に書く gh の呼び出し（Release の作成・公開・削除、ワークフローの実行）がない。
no_write() { log_lacks '^release \(create\|edit\|delete\|upload\)\|^workflow run\|^api -X\|^api --method'; }
# no_download: 配布物を取得していない。
no_download() { log_lacks 'releases/assets/'; }
no_tag() { [[ -z $(git -C "$work" tag) && -z $(git -C "$bare" tag) ]]; }
# no_leftover: 流したあとに、一時の置き場が残っていない。
no_leftover() { [[ -z $(ls -A "$case_dir/tmp") ]]; }

# 公開の手順の名前（docs/release.md の「公開」の表）。確認の「すること」の一覧は、することに応じて、この名前を 1 から振り直した番号で並べる。
step_names=(
	'タグを作って push する'
	'下書きの Release を作る'
	'発行のワークフローに配布物を作らせ、終わるまで待つ'
	'配布物を確かめる'
	'Release を公開する'
)
# steps_expected <最初の手順の番号>: 「すること:」の行と、番号付きの一覧。
steps_expected() {
	local first=$1 no=0
	printf 'すること:'
	while [[ $first -le 5 ]]; do
		no=$((no + 1))
		printf '\n  %d. %s' "$no" "${step_names[$((first - 1))]}"
		first=$((first + 1))
	done
	printf '\n'
}
# expect_steps <最初の手順の番号>: 標準出力の「すること:」の行と、そのあとの手順の行（承認のあとの出力は含めない）が、その一覧と同じ。
expect_steps() {
	[[ $(sed -n '/^すること:$/,$p' "$case_dir/out" | head -n "$((7 - $1))") == "$(steps_expected "$1")" ]]
}
# expect_screen <結果の語> <タグと Release の値> <タグを付けるコミット> <最初の手順の番号>: 確認の前の画面の全体（確かめの一覧から、することの一覧まで）が設計のとおり。
expect_screen() {
	local head12 commit12
	head12=$(git -C "$work" rev-parse HEAD)
	head12=${head12:0:12}
	commit12=${3:0:12}
	local expected
	expected=$(
		printf '確かめ:\n'
		printf '  成功  道具: git, gh, tar, shasum, diff, cmp（gh 2.102.0、必要: 2.102.0 以上）\n'
		printf '  成功  場所: example/kit のルート、ブランチ main\n'
		printf '  成功  未コミットの変更: なし\n'
		printf '  一致  origin の main: %s（手元の main と同じ）\n' "$head12"
		printf '  一致  バージョン: VERSION v1.6.0、CHANGELOG.md の先頭 v1.6.0、節は空でない\n'
		printf '  %s  タグと Release: %s\n' "$1" "$2"
		printf '\n【Release の本文 ここから】\n%s\n【Release の本文 ここまで】\n\n' "$notes_expected"
		printf 'リポジトリ: example/kit\n出すバージョン: v1.6.0\nタグを付けるコミット: %s Release content\n' "$commit12"
		steps_expected "$4"
	)
	[[ $(cat "$case_dir/out") == "$expected" ]]
	grep -qF '公開しますか [y/N]: ' "$case_dir/err"
}

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
grep -qF "タグを付けるコミット: ${main_head:0:12} Release content" "$case_dir/out"
expect_steps 1
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

# 確認の前の画面: 確かめの一覧、本文の区切り、要約、番号付きのすることが、設計のとおり、することの 4 つの状態ごとに出る。
# タグも Release もない: 手順は 5 つ。
make_case screen-tag
screen_commit=$(git -C "$work" rev-parse HEAD)
run_release "$test_dir/answer-n"
[[ $rc == 1 ]]
expect_screen 新規 '手元のタグ なし、origin のタグ なし、Release なし' "$screen_commit" 1
# タグだけある: 手順は 4 つ。タグを付けるコミットは、タグが指すコミット。
make_case screen-draft
tag_here
git -C "$work" commit -q --allow-empty -m 'After tag'
git -C "$work" push -q origin main
screen_tag_commit=$(git -C "$work" rev-parse 'v1.6.0^{commit}')
run_release "$test_dir/answer-n"
[[ $rc == 1 ]]
expect_screen 既存 '手元のタグ あり、origin のタグ あり（同じ）、Release なし' "$screen_tag_commit" 2
# 配布物のない下書きがある: 手順は 3 つ。
make_case screen-workflow
tag_here
add_release true
screen_tag_commit=$(git -C "$work" rev-parse 'v1.6.0^{commit}')
run_release "$test_dir/answer-n"
[[ $rc == 1 ]]
expect_screen 既存 '手元のタグ あり、origin のタグ あり（同じ）、Release 下書き（配布物 0 個）' "$screen_tag_commit" 3
# 配布物のそろった下書きがある: 手順は 2 つ。
make_case screen-verify
tag_here
add_release true
seed_assets
screen_tag_commit=$(git -C "$work" rev-parse 'v1.6.0^{commit}')
run_release "$test_dir/answer-n"
[[ $rc == 1 ]]
expect_screen 既存 '手元のタグ あり、origin のタグ あり（同じ）、Release 下書き（配布物 4 個）' "$screen_tag_commit" 4

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
! grep -qF '確かめ:' "$case_dir/out"
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
	! grep -qF '確かめ:' "$case_dir/out"
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
grep -qF "タグを付けるコミット: ${tag_commit:0:12} Release content" "$case_dir/out"
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
expect_steps 4
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
! grep -qF '確かめ:' "$case_dir/out"
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
# 実行が失敗する: 実行の URL を出し、確かめも release edit もしない。配布物がないので、流し直すと配布物を作らせ直す。
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

# 公開の前の確かめが失敗する: 何が合わなかったかを出し、release edit も削除も呼ばない。下書きと配布物は残り、流し直さないことを出す。
# expect_verify_stop <理由に含む文字>: 配布物のそろった下書きから流して、確かめで止まったことを確かめる。
expect_verify_stop() {
	run_release "$test_dir/answer-y"
	[[ $rc == 1 ]]
	grep -qF "$1" "$case_dir/err"
	grep -qF '公開しません。下書きと配布物は残してあります。' "$case_dir/err"
	grep -qF '人が確かめるまで流し直さないでください。' "$case_dir/err"
	log_lacks '^release \(edit\|delete\)'
	log_lacks '^api -X\|^api --method'
	log_lacks '^workflow run'
	[[ $(draft_flag) == true ]]
	[[ $(jq -r '.[] | select(.tag_name == "v1.6.0") | .assets | length' "$GH_RELEASES") == 4 ]]
	no_leftover
}
# 束での証明が通らない: タグの install.sh の確かめ（束なし）は通り、配布物ごとの束での確かめで止まる。
for file in install.sh SHA256SUMS multica-squad-kit-v1.6.0.tar.gz; do
	make_case "verify-bundle-$file"
	tag_here
	add_release true
	seed_assets
	GH_ATTEST_FAIL=$file GH_ATTEST_FAIL_WITH=bundle expect_verify_stop "証明の束で、$file の証明を確かめられませんでした。"
	grep -qF 'stub: attestation failed' "$case_dir/err"
done
# 使う人の入口と同じ確かめ（束なしの証明）が通らない: タグの install.sh の --verify が止める。
make_case verify-nobundle
tag_here
add_release true
seed_assets
GH_ATTEST_FAIL=SHA256SUMS GH_ATTEST_FAIL_WITH=nobundle expect_verify_stop 'タグの install.sh の --verify が通りませんでした。'
grep -qF '証明を確かめられませんでした: SHA256SUMS' "$case_dir/err"
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
# 配布物の中身が、git archive で取り出したタグの中身と違う（ほかの確かめは通る）。違いの先頭を出す。
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

# 公開が失敗する: 下書きが残り、1 で終わる。流し直すと、配布物を確かめ直して公開する。
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
expect_steps 4
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
echo 'PASS release: 確かめで止まり、承認でだけ、タグと下書きの Release を作り、ワークフローで配布物を作らせ、確かめてから公開する。拒否・端末でない・各手順の失敗と流し直し・公開の前の確かめの失敗・すでにあるタグと Release の状態・引数を確かめた'
