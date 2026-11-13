#!/usr/bin/env bash
# scripts/release.sh の動きのうち、確かめで止まるケース（docs/release.md の「確かめること」の 1 の gh のバージョン、ルートでないところに置いたコピー、2〜9）を確かめる。9 は、配布物のそろった下書きと公開済みで 9 を省くことも含む。
# 準備と補助は tests/release-test-lib.sh、承認・拒否とタグと Release が揃った状態からの続きは tests/release-test.sh、失敗と流し直しは tests/release-failure-test.sh にある。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/tests/release-assertions.sh"

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

# 9: 名前の検査は、問い・タグ・push・下書きの作成より前に行う。
# 既存のタグでは、その後の main が直っていても、タグのコミットを確かめる。
for state in tag draft workflow; do
	make_case "preflight-name-$state"
	printf 'invalid name\n' >"$work/保.txt"
	(cd "$work" && bash scripts/manifest.sh)
	commit_work 'Non-ASCII name'
	if [[ $state != tag ]]; then
		tag_here
		if [[ $state == workflow ]]; then add_release true; fi
		rm "$work/保.txt"
		(cd "$work" && bash scripts/manifest.sh)
		commit_work 'Clean main after the tag'
	fi
	# 仕込みが終わってから hook を置き、同じタグへの push も呼んでいないか記録する。
	cat >"$work/.git/hooks/pre-push" <<'HOOK'
#!/bin/sh
printf 'push\n' >>"$GH_STATE/push.log"
HOOK
	chmod +x "$work/.git/hooks/pre-push"
	before=$(snapshot)
	before_releases=$(cat "$GH_RELEASES")
	run_release "$test_dir/answer-y"
	[[ $rc == 1 && $(snapshot) == "$before" && $(cat "$GH_RELEASES") == "$before_releases" ]]
	[[ ! -e $GH_STATE/push.log ]]
	no_write
	no_download
	no_leftover
	! grep -qF '公開しますか' "$case_dir/err"
	grep -qF '保.txt' "$case_dir/err"
	grep -qF '印字できる ASCII ではない文字がある' "$case_dir/err"
	grep -qF '配布物の確かめ（9）で止まりました' "$case_dir/err"
	grep -qF 'CONTRIBUTING.md の「ファイルとディレクトリの名前」' "$case_dir/err"
	if [[ $state == tag ]]; then
		no_tag
	else
		grep -qF 'v1.6.0 のタグでは出せません' "$case_dir/err"
		grep -qF '直したコミットを新しいバージョンで出してください' "$case_dir/err"
	fi
done

# 名前が正しくても、配布物の完全性の検査に通らなければ同じく 9 で止まる。
make_case preflight-manifest
printf 'changed\n' >>"$work/tracked.txt"
commit_work 'Outdated MANIFEST'
before=$(snapshot)
run_release "$test_dir/answer-y"
[[ $rc == 1 && $(snapshot) == "$before" ]]
no_tag
no_write
no_download
no_leftover
grep -qF 'MANIFEST のハッシュと合いません' "$case_dir/err"
grep -qF '配布物の確かめ（9）で止まりました' "$case_dir/err"
! grep -qF '公開しますか' "$case_dir/err"

# そろった下書きは 9 を省き、確認のあとに公開の前の確かめへ進む。
# 名前が悪いタグでも、4 つの配布物の ID がそろっていれば同じ経路を選ぶ。
# 配布物の取得を失敗させ、公開の前の確かめに入ったことまでを見る。
make_case preflight-skip-complete
printf 'invalid name\n' >"$work/保.txt"
(cd "$work" && bash scripts/manifest.sh)
commit_work 'Non-ASCII name'
tag_here
add_release true
edit_assets '[{"id":101,"name":"multica-squad-kit-v1.6.0.tar.gz"},{"id":102,"name":"install.sh"},{"id":103,"name":"SHA256SUMS"},{"id":104,"name":"multica-squad-kit-v1.6.0.sigstore.json"}]'
before=$(snapshot)
GH_DL_FAIL=101 run_release "$test_dir/answer-y"
[[ $rc == 1 && $(snapshot) == "$before" ]]
! grep -qF '確かめの 9' "$case_dir/out"
! grep -qF '配布物の確かめ（9）' "$case_dir/err"
grep -qF '公開しますか' "$case_dir/err"
grep -qF '✖ 配布物を確かめる' "$case_dir/out"
log_has 'releases/assets/101'
log_lacks '^workflow run'
no_write
no_leftover

# 公開済みは、名前が悪くても 9 を省き、端末も書き込みもなしで成功する。
make_case preflight-skip-published
printf 'invalid name\n' >"$work/保.txt"
(cd "$work" && bash scripts/manifest.sh)
commit_work 'Non-ASCII name'
tag_here
add_release false
before=$(snapshot)
run_release_notty
[[ $rc == 0 && $(snapshot) == "$before" ]]
! grep -qF '確かめの 9' "$case_dir/out"
! grep -qF '配布物の確かめ（9）' "$case_dir/err"
! grep -qF '公開しますか' "$case_dir/err"
grep -qF 'すでに出してあります' "$case_dir/out"
no_write
no_download
no_leftover
echo 'PASS release 確かめ: gh のバージョン、origin、ブランチ、未コミットの変更、origin/main との一致、VERSION の形、CHANGELOG.md の先頭と空の節、ルートでないところに置いたコピー、配布物の確かめで止まり、何も変えないことと、そろった下書きと公開済みでは配布物の確かめを省くことを確かめた'
