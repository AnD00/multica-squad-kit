#!/usr/bin/env bash
# 版を上げる PR のマージのあとに、VERSION の版の注釈付きのタグと Release を出す。
# 設計は docs/release.md。bash 3.2 で動かす。
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib/ui.sh
source lib/ui.sh
ui_init

usage() {
	cat <<'USAGE'
使い方: bash scripts/release.sh
原本のリポジトリのルートの main で流す。VERSION の版のタグと Release を、確認のあとに出す。
USAGE
}
stop() {
	ui_error "$*"
	exit 1
}

case $# in
0) ;;
1)
	case $1 in
	--help | -h)
		usage
		exit 0
		;;
	esac
	usage >&2
	exit 2
	;;
*)
	usage >&2
	exit 2
	;;
esac

# 1: 道具と置き場所
command -v git >/dev/null || stop 'git がありません。'
command -v gh >/dev/null || stop 'gh がありません。'
root=$(pwd -P)
top=$(git rev-parse --show-toplevel 2>/dev/null) || stop '原本のリポジトリのルートで流してください。'
[[ $(cd "$top" && pwd -P) == "$root" ]] || stop '原本のリポジトリのルートで流してください。'

# 2: GitHub のリポジトリ（OWNER/REPO）。insteadOf の書き換えを受けないよう、設定の値を読む。
origin_url=$(git config --get remote.origin.url) || stop '`origin` がありません。'
repo=
case $origin_url in
https://github.com/*) repo=${origin_url#https://github.com/} ;;
git@github.com:*) repo=${origin_url#git@github.com:} ;;
ssh://git@github.com/*) repo=${origin_url#ssh://git@github.com/} ;;
esac
repo=${repo%.git}
[[ $repo =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || stop "\`origin\` が GitHub のリポジトリではありません: $origin_url"

# 3: ブランチ。止まるときは手元の状態を変えず、流すコマンドを添える。
branch=$(git symbolic-ref --quiet --short HEAD) || branch=
[[ $branch == main ]] || stop '今のブランチが main ではありません。`git switch main` と `git pull --ff-only origin main` をしてから流してください。'

# 4: 追跡しているファイルの未コミットの変更。追跡していないファイルは公開する中身に入らない。
[[ -z $(git status --porcelain --untracked-files=no) ]] || stop '未コミットの変更があります。コミットするか戻してから流してください。'

# 5: origin の main と手元の main の一致。origin/main だけを更新し、タグは取ってこない。
git fetch --quiet --no-tags origin main || stop 'origin の main を取ってこれません。'
[[ $(git rev-parse HEAD) == "$(git rev-parse FETCH_HEAD)" ]] || stop '手元の main が origin/main と一致しません。未公開のコミットがあるか、origin/main に遅れています。`git pull --ff-only origin main` をしても合わないときは、PR でマージしてから流してください。'
commit=$(git rev-parse HEAD)

# 6: VERSION の形。公開する中身と同じコミットから読む。
version=$(git show "$commit:VERSION" 2>/dev/null | tr -d '\n') || version=
[[ $version =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || stop "VERSION が vX.Y.Z の形ではありません: ${version:-（空）}"

# 7: CHANGELOG.md の先頭の版
changelog=$(git show "$commit:CHANGELOG.md" 2>/dev/null) || stop 'CHANGELOG.md を読めません。'
top_version=$(printf '%s\n' "$changelog" | awk '/^## / {print $2; exit}')
[[ $top_version == "$version" ]] || stop "VERSION（${version}）と CHANGELOG.md の先頭の版（${top_version:-なし}）が違います。"

# 8: その版の節。次の ## の見出しの前までで、前後の空行を除いたものが Release の本文になる。
notes=$(printf '%s\n' "$changelog" | awk -v heading="## $version" '$0 == heading {found = 1; next} found && /^## / {exit} found')
[[ -n $(printf '%s' "$notes" | tr -d '[:space:]') ]] || stop "CHANGELOG.md の $version の節が空です。"
notes=$(printf '%s\n' "$notes" | awk 'NF {if (started) for (; blank > 0; blank--) print ""; started = 1; blank = 0; print; next} started {blank++}')

# 段 2 で、すでにあるタグと Release の状態の読み分けに置き換える。
[[ -z $(git rev-parse --verify --quiet "refs/tags/$version") ]] || stop "手元に $version のタグがすでにあります。"
[[ -z $(git ls-remote origin "refs/tags/$version") ]] || stop "origin に $version のタグがすでにあります。"

# 確認: 中身を標準出力に出し、問いを標準エラー出力に出して、標準入力の答えを読む。
[[ -t 0 ]] || stop '標準入力が端末でないため、確認を求められません。端末から流してください。'
printf 'リポジトリ: %s\n' "$repo"
printf '出す版: %s\n' "$version"
printf 'タグを付けるコミット: %s %s\n' "$commit" "$(git log -1 --format=%s "$commit")"
printf 'すること: 注釈付きのタグを作って origin に push し、Release を作る\n'
printf 'Release の本文:\n----------------------------------------\n%s\n----------------------------------------\n' "$notes"
printf '公開しますか [y/N]: ' >&2
answer=
read -r answer || :
[[ $answer == y || $answer == Y ]] || stop '公開を取りやめました。'

# 公開: 確認で出したコミットを明示してタグを作る。--force は付けない。
notes_file=$(mktemp "${TMPDIR:-/tmp}/release-notes.XXXXXX")
trap 'rm -f -- "$notes_file"' EXIT
printf '%s\n' "$notes" >"$notes_file"
git tag -a "$version" -m "$version" "$commit"
if ! git push origin "refs/tags/$version"; then
	git tag -d "$version" >/dev/null
	stop "タグの push に失敗しました。手元のタグを消したので、流し直せます。"
fi
if ! url=$(gh release create "$version" --repo "$repo" --verify-tag --title "$version" --notes-file "$notes_file"); then
	stop "タグは push しましたが、Release の作成に失敗しました。同じコマンドを流し直すと、Release だけを作ります。"
fi
printf 'タグと Release を出しました: %s\n' "$url"
