#!/usr/bin/env bash
# scripts/release.sh の動きを、一時の Git のリポジトリとスタブの gh で確かめる。
# origin は一時の bare のリポジトリで、本物の GitHub には push せず、Release も作らない。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/release.XXXXXX")
trap 'test_exit=$?; if [[ $test_exit != 0 ]]; then for log in "$test_dir"/*/out "$test_dir"/*/err; do [[ -f $log ]] && { echo "--- $log" >&2; cat "$log" >&2; }; done; fi; rm -rf -- "$test_dir"' EXIT
# 手元の Git の設定（環境変数で入る GIT_CONFIG_COUNT 以降を含む）から切り離す。push は一時の bare にだけ届く。
unset GIT_CONFIG_COUNT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME='Test User' GIT_AUTHOR_EMAIL=test@example.test
export GIT_COMMITTER_NAME='Test User' GIT_COMMITTER_EMAIL=test@example.test

# スタブの gh は、受けた引数を行にして記録し、release create の --notes-file の中身を写す。
mkdir -p "$test_dir/bin"
cat >"$test_dir/bin/gh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$GH_LOG"
if [[ ${1:-} == release && ${2:-} == create ]]; then
	[[ -z ${GH_CREATE_FAIL:-} ]] || { echo 'intentional release failure' >&2; exit 1; }
	while [[ $# -gt 0 ]]; do
		if [[ $1 == --notes-file ]]; then cp "$2" "$GH_NOTES"; fi
		shift
	done
	echo "https://github.com/example/kit/releases/tag/$GH_TAG"
	exit 0
fi
echo "unexpected gh call: $*" >&2
exit 1
STUB
chmod +x "$test_dir/bin/gh"

changelog_default() {
	cat <<'CHANGELOG'
# 変更の記録

## v1.6.0


新しい版の 1 段落目。

- 項目 1
- 項目 2


## v1.5.0

古い版の本文。
CHANGELOG
}
notes_expected=$'新しい版の 1 段落目。\n\n- 項目 1\n- 項目 2'

# make_case <名前> [origin の URL]: bare の origin と、その URL を insteadOf で bare に向けた作業コピーを作る。
make_case() {
	local url=${2:-https://github.com/example/kit.git}
	case_dir="$test_dir/$1"
	bare="$case_dir/origin.git"
	work="$case_dir/work"
	mkdir -p "$case_dir"
	git init -q --bare -b main "$bare"
	git init -q -b main "$work"
	mkdir -p "$work/scripts" "$work/lib"
	cp "$root/scripts/release.sh" "$work/scripts/release.sh"
	cp "$root/lib/ui.sh" "$work/lib/ui.sh"
	printf 'v1.6.0\n' >"$work/VERSION"
	changelog_default >"$work/CHANGELOG.md"
	printf 'tracked\n' >"$work/tracked.txt"
	git -C "$work" add -A
	git -C "$work" commit -qm 'Release content'
	git -C "$work" remote add origin "$url"
	git -C "$work" config "url.$bare.insteadOf" "$url"
	git -C "$work" push -q origin main
}

# commit_work <メッセージ>: 作業コピーの変更をコミットして origin に push する。
commit_work() {
	git -C "$work" add -A
	git -C "$work" commit -qm "$1"
	git -C "$work" push -q origin main
}

# snapshot: 手元と origin のブランチとタグを 1 つの文字にする。
snapshot() {
	git -C "$work" for-each-ref refs/heads refs/tags
	git -C "$bare" for-each-ref refs/heads refs/tags
}

# run_release <入力のファイル> [引数...]: 標準入力を疑似端末につないで流す。終了コードを rc に置く。
run_release() {
	local input=$1
	shift
	rm -f "$case_dir/rc"
	(cd "$work" && env PATH="$test_dir/bin:$PATH" GH_LOG="$case_dir/gh.log" GH_NOTES="$case_dir/gh.notes" GH_TAG=v1.6.0 \
		python3 "$root/tests/ui-pty.py" none "$case_dir/out" "$case_dir/err" --stdin-tty "$input" -- \
		/bin/bash -c 'rc=0; /bin/bash scripts/release.sh "$@" || rc=$?; printf "%s" "$rc" >"$0"' "$case_dir/rc" "$@")
	rc=$(<"$case_dir/rc")
}

# run_release_notty <引数...>: 標準入力を /dev/null にして流す（端末でない）。
run_release_notty() {
	rc=0
	(cd "$work" && env PATH="$test_dir/bin:$PATH" GH_LOG="$case_dir/gh.log" GH_NOTES="$case_dir/gh.notes" GH_TAG=v1.6.0 \
		/bin/bash scripts/release.sh "$@") </dev/null >"$case_dir/out" 2>"$case_dir/err" || rc=$?
}

printf 'y\n' >"$test_dir/answer-y"
printf 'n\n' >"$test_dir/answer-n"
printf '\n' >"$test_dir/answer-empty"
: >"$test_dir/answer-eof"
printf 'yes\n' >"$test_dir/answer-yes"

no_release() { [[ ! -e $case_dir/gh.log ]] || ! grep -q '^release create' "$case_dir/gh.log"; }
no_tag() { [[ -z $(git -C "$work" tag) && -z $(git -C "$bare" tag) ]]; }

# 承認する: origin に注釈付きのタグができ、main の先頭を指す。Release の本文は、その版の節の前後の空行を除いたもの。
make_case approve
main_head=$(git -C "$work" rev-parse HEAD)
run_release "$test_dir/answer-y"
[[ $rc == 0 ]]
[[ $(git -C "$bare" cat-file -t v1.6.0) == tag ]]
[[ $(git -C "$bare" rev-parse 'v1.6.0^{commit}') == "$main_head" ]]
[[ $(git -C "$bare" tag -l --format='%(contents:subject)' v1.6.0) == v1.6.0 ]]
[[ $(git -C "$work" cat-file -t v1.6.0) == tag ]]
[[ $(git -C "$work" rev-parse 'v1.6.0^{commit}') == "$main_head" ]]
[[ $(grep -c '^release create' "$case_dir/gh.log") == 1 ]]
grep -q '^release create v1.6.0 --repo example/kit --verify-tag --title v1.6.0 --notes-file ' "$case_dir/gh.log"
[[ $(<"$case_dir/gh.notes") == "$notes_expected" ]]
grep -qxF '出す版: v1.6.0' "$case_dir/out"
grep -qF "タグを付けるコミット: $main_head Release content" "$case_dir/out"
grep -qxF '新しい版の 1 段落目。' "$case_dir/out"
grep -qF 'https://github.com/example/kit/releases/tag/v1.6.0' "$case_dir/out"
grep -qF '公開しますか [y/N]: ' "$case_dir/err"

# 追跡していないファイルは、止める理由にしない。origin の URL の 3 つの形から OWNER/REPO を読む。
for url in https://github.com/example/kit git@github.com:example/kit.git ssh://git@github.com/example/kit.git; do
	make_case "url-$(printf '%s' "$url" | tr -c 'A-Za-z0-9' '_')" "$url"
	printf 'untracked\n' >"$work/untracked.txt"
	run_release "$test_dir/answer-y"
	[[ $rc == 0 ]]
	[[ $(git -C "$bare" cat-file -t v1.6.0) == tag ]]
	grep -q '^release create v1.6.0 --repo example/kit ' "$case_dir/gh.log"
done

# 承認しない: n、yes、空の答え、入力の終わりでは、何も変えずに 1 で終わる。
for answer in n yes empty eof; do
	make_case "decline-$answer"
	before=$(snapshot)
	run_release "$test_dir/answer-$answer"
	[[ $rc == 1 ]]
	no_tag
	no_release
	[[ $(snapshot) == "$before" ]]
	grep -qF '公開を取りやめました。' "$case_dir/err"
done

# 標準入力が端末でない: 問いを出さず、確認を求められないと出して、何も変えない。
make_case notty
before=$(snapshot)
run_release_notty
[[ $rc == 1 ]]
no_tag
no_release
[[ $(snapshot) == "$before" ]]
grep -qF '端末でない' "$case_dir/err"
! grep -qF '公開しますか' "$case_dir/err"
# パイプで y を流し込んでも、確認を飛ばせない。
rc=0
(cd "$work" && printf 'y\n' | env PATH="$test_dir/bin:$PATH" GH_LOG="$case_dir/gh.log" GH_NOTES="$case_dir/gh.notes" /bin/bash scripts/release.sh) >"$case_dir/out" 2>"$case_dir/err" || rc=$?
[[ $rc == 1 ]]
no_tag
no_release

# 確かめで止まるケース: 理由を出し、fetch のほかは何も変えず、タグも Release も作らない。
# expect_stop <理由に含む文字>: 作業コピーに手を入れたあとで流し、止まることを確かめる。
expect_stop() {
	local before
	before=$(snapshot)
	run_release "$test_dir/answer-y"
	[[ $rc == 1 ]]
	no_tag
	no_release
	[[ $(snapshot) == "$before" ]]
	grep -qF "$1" "$case_dir/err"
	! grep -qF '公開しますか' "$case_dir/err"
}

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

# 7: CHANGELOG.md の先頭の版が VERSION と違う
make_case stop-changelog-top
printf 'v1.7.0\n' >"$work/VERSION"
commit_work 'Version only'
expect_stop 'CHANGELOG.md の先頭の版'
grep -qF 'v1.7.0' "$case_dir/err"
grep -qF 'v1.6.0' "$case_dir/err"

# 8: その版の節が、空白と改行だけ
make_case stop-empty-section
printf '# 変更の記録\n\n## v1.6.0\n\n  \n\n## v1.5.0\n\n古い版の本文。\n' >"$work/CHANGELOG.md"
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
(cd "$case_dir/copy" && env PATH="$test_dir/bin:$PATH" GH_LOG="$case_dir/gh.log" /bin/bash scripts/release.sh) </dev/null >"$case_dir/out" 2>"$case_dir/err" || rc=$?
[[ $rc == 1 ]]
grep -qF 'ルートで流してください' "$case_dir/err"
no_release

# すでにタグがあるとき（段 2 で、状態の読み分けに置き換える）は、タグを動かさずに止まる。
make_case stop-existing-tag
git -C "$work" tag -a v1.6.0 -m v1.6.0
tag_sha=$(git -C "$work" rev-parse v1.6.0)
run_release "$test_dir/answer-y"
[[ $rc == 1 ]]
[[ $(git -C "$work" rev-parse v1.6.0) == "$tag_sha" && -z $(git -C "$bare" tag) ]]
no_release

# push が失敗する: 手元のタグが消え、Release を作らずに 1 で終わる。
make_case push-fails
printf '#!/bin/sh\nexit 1\n' >"$bare/hooks/pre-receive"
chmod +x "$bare/hooks/pre-receive"
run_release "$test_dir/answer-y"
[[ $rc == 1 ]]
no_tag
no_release
grep -qF 'push に失敗しました' "$case_dir/err"

# Release の作成が失敗する: タグは残り、1 で終わる。
make_case release-fails
rc=0
rm -f "$case_dir/rc"
(cd "$work" && env PATH="$test_dir/bin:$PATH" GH_LOG="$case_dir/gh.log" GH_NOTES="$case_dir/gh.notes" GH_TAG=v1.6.0 GH_CREATE_FAIL=1 \
	python3 "$root/tests/ui-pty.py" none "$case_dir/out" "$case_dir/err" --stdin-tty "$test_dir/answer-y" -- \
	/bin/bash -c 'rc=0; /bin/bash scripts/release.sh || rc=$?; printf "%s" "$rc" >"$0"' "$case_dir/rc")
[[ $(<"$case_dir/rc") == 1 ]]
[[ $(git -C "$bare" cat-file -t v1.6.0) == tag && $(git -C "$work" cat-file -t v1.6.0) == tag ]]
grep -q '^release create' "$case_dir/gh.log"
grep -qF 'Release の作成に失敗しました' "$case_dir/err"

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
echo 'PASS release: 確かめで止まり、承認でだけ注釈付きのタグと Release を作る。拒否・端末でない・push と Release の失敗・引数を確かめた'
