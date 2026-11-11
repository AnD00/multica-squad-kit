#!/usr/bin/env bash
# 取り出したタグの中身から、配布物（tar.gz）と install.sh と SHA256SUMS を出力先に作る。
# 設計は docs/release.md の「配布物を作る」と docs/install.md の「展開の前の確かめ」。bash 3.2 で動かす。
set -euo pipefail
# 出力先は、呼んだ場所からの相対で渡されても、リポジトリのルートへ移ったあとで同じ場所を指すようにする。
caller_dir=$PWD
cd "$(dirname "$0")/.."
# shellcheck source=lib/ui.sh
source lib/ui.sh
ui_init
# 一覧の読み方を、GNU tar と bsdtar で、手元と CI で同じにする。
export LC_ALL=C

usage() {
	cat <<'USAGE'
使い方: bash scripts/build-assets.sh <バージョン> <出力先>
取り出したタグ（HEAD がそのタグの指すコミット）の中身から、配布物と install.sh と SHA256SUMS を出力先に作る。
<バージョン> は vX.Y.Z の形。出力先は、なければ作り、あれば空にしておく。
USAGE
}
stop() {
	ui_error "$*"
	exit 1
}

case $# in
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
2) ;;
*)
	usage >&2
	exit 2
	;;
esac
version=$1
out_arg=$2
[[ $version =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
	usage >&2
	stop "バージョンは vX.Y.Z の形で渡してください: $version"
}
[[ -n $out_arg ]] || {
	usage >&2
	exit 2
}
case $out_arg in
/*) out=$out_arg ;;
*) out=$caller_dir/$out_arg ;;
esac

command -v git >/dev/null || stop 'git がありません。'
command -v tar >/dev/null || stop 'tar がありません。'
command -v shasum >/dev/null || stop 'shasum がありません。'

# 1: HEAD がタグの指すコミットで、VERSION がバージョンと一致する
tag_ref=refs/tags/$version
tag_commit=$(git rev-parse --verify --quiet "$tag_ref^{commit}") || stop "タグ $version がありません。"
head_commit=$(git rev-parse --verify --quiet 'HEAD^{commit}') || stop 'HEAD を読めません。'
[[ $head_commit == "$tag_commit" ]] || stop "HEAD（$head_commit）が、タグ $version の指すコミット（$tag_commit）と違います。タグを取り出してから流してください。"
tag_version=$(git show "$tag_ref:VERSION" 2>/dev/null) || stop "タグ $version に VERSION がありません。"
[[ $tag_version == "$version" ]] || stop "タグ $version の VERSION（$tag_version）が、バージョンと違います。"
install_mode=$(git ls-tree "$tag_ref" -- install.sh | cut -c1-6)
[[ $install_mode == 100644 || $install_mode == 100755 ]] || stop "タグ $version に、通常のファイルの install.sh がありません。"

# 出力先は、空にしておく。前に作ったものと混ざらないようにするため。
if [[ -e $out || -L $out ]]; then
	[[ -d $out && ! -L $out ]] || stop "出力先がディレクトリではありません: $out"
	[[ -z $(ls -A "$out") ]] || stop "出力先が空ではありません: $out"
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/build-assets.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
asset=multica-squad-kit-$version.tar.gz
prefix=multica-squad-kit-$version/

# 2: タグの中身から、配布物を作る
git archive --format=tar.gz --prefix="$prefix" -o "$work/$asset" "$tag_ref" || stop '配布物を作れませんでした。'

# 3: 展開の前に、一覧を読んで、展開先の外へ書くもの、読み違えのおそれがあるものを拒む
names=$(tar -tzf "$work/$asset") || stop '配布物の一覧を読めません。'
verbose=$(tar -tvzf "$work/$asset") || stop '配布物の詳細な一覧を読めません。'
[[ -n $names ]] || stop '配布物が空です。'
names_count=$(printf '%s\n' "$names" | wc -l)
verbose_count=$(printf '%s\n' "$verbose" | wc -l)
[[ $names_count -eq $verbose_count ]] || stop "配布物の 2 つの一覧の行の数が違います（$names_count と $verbose_count）。名前に改行があるおそれがあります。"
while IFS= read -r name; do
	case $name in
	/*) stop "配布物に絶対パスがあります: $name" ;;
	esac
	case /$name/ in
	*/../*) stop "配布物に上へ出るパスがあります: $name" ;;
	esac
	case $name in
	"$prefix"* | "${prefix%/}") ;;
	*) stop "配布物に、$prefix の下ではないものがあります: $name" ;;
	esac
	if [[ $name == *[[:cntrl:]]* || $name == *\\* ]]; then
		stop "配布物に、制御文字かバックスラッシュを含む名前があります: $name"
	fi
done <<<"$names"
while IFS= read -r line; do
	case ${line:0:1} in
	- | d) ;;
	*) stop "配布物に、通常のファイルとディレクトリのどちらでもないもの（リンクか特殊なファイル）があります: $line" ;;
	esac
done <<<"$verbose"

# 4: 新しい一時の置き場に展開し、MANIFEST の一覧と中のファイルが一致し、MANIFEST の確かめが通ることを確かめる
extract=$work/extract
mkdir "$extract"
tar -xzf "$work/$asset" -C "$extract" || stop '配布物を展開できませんでした。'
[[ $(ls -A "$extract") == "${prefix%/}" ]] || stop "展開した一番上が、$prefix の 1 つのディレクトリだけではありません。"
root_dir=$extract/${prefix%/}
[[ -z $(find "$root_dir" ! -type f ! -type d -print -quit) ]] || stop '展開したものに、通常のファイルとディレクトリのどちらでもないものがあります。'
[[ -f $root_dir/MANIFEST ]] || stop '配布物に MANIFEST がありません。'
(cd "$root_dir" && find . -type f ! -path ./MANIFEST | sort) >"$work/files.actual"
sed 's/^[0-9a-f]\{64\}  //' "$root_dir/MANIFEST" | sort >"$work/files.manifest"
cmp -s "$work/files.actual" "$work/files.manifest" || stop 'MANIFEST の一覧と、配布物の中のファイルが一致しません。'
(cd "$root_dir" && shasum -a 256 -c MANIFEST) >"$work/shasum.log" 2>&1 || {
	cat "$work/shasum.log" >&2
	stop '配布物の中のファイルが、MANIFEST のハッシュと合いません。'
}

# 5: install.sh を写し、2 つの SHA-256 を SHA256SUMS に書く
mkdir -p "$out"
cp "$work/$asset" "$out/$asset"
git show "$tag_ref:install.sh" >"$out/install.sh"
(cd "$out" && shasum -a 256 "$asset" install.sh >SHA256SUMS)
ui_line out success "配布物を作りました: $out（$asset、install.sh、SHA256SUMS）"
