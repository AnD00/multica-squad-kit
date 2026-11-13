#!/usr/bin/env bash
# タグかコミットの中身から、配布物（tar.gz）と install.sh と SHA256SUMS を出力先に作る。
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
        bash scripts/build-assets.sh --commit <コミット> <出力先>
取り出したタグ（HEAD がそのタグの指すコミット）の中身から、配布物と install.sh と SHA256SUMS を出力先に作る。
--commit は、タグを必要とせず、渡したコミットの VERSION を読んで同じ配布物を作る。
<バージョン> は vX.Y.Z の形。出力先は、なければ作り、あれば空にしておく。
USAGE
}
stop() {
	ui_error "$*"
	exit 1
}

mode=tag
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
2) [[ $1 != --commit ]] || { usage >&2; exit 2; } ;;
3)
	[[ $1 == --commit ]] || { usage >&2; exit 2; }
	mode=commit
	shift
	;;
*)
	usage >&2
	exit 2
	;;
esac
ref_arg=$1
out_arg=$2
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

# 1: 対象を決める。コミットの形では、HEAD やタグとの一致は求めない。
version_re='^v[0-9]+\.[0-9]+\.[0-9]+$'
if [[ $mode == commit ]]; then
	target=$(git rev-parse --verify --quiet "$ref_arg^{commit}") || stop "コミットを読めません: $ref_arg"
	version=$(git show "$target:VERSION" 2>/dev/null) || stop "コミット $target に VERSION がありません。"
	[[ $version =~ $version_re ]] || stop "コミット $target の VERSION は vX.Y.Z の形で書いてください: $version"
	target_label="コミット $target"
else
	version=$ref_arg
	[[ $version =~ $version_re ]] || { usage >&2; stop "バージョンは vX.Y.Z の形で渡してください: $version"; }
	target=refs/tags/$version
	tag_commit=$(git rev-parse --verify --quiet "$target^{commit}") || stop "タグ $version がありません。"
	head_commit=$(git rev-parse --verify --quiet 'HEAD^{commit}') || stop 'HEAD を読めません。'
	[[ $head_commit == "$tag_commit" ]] || stop "HEAD（${head_commit}）が、タグ $version の指すコミット（${tag_commit}）と違います。タグを取り出してから流してください。"
	tag_version=$(git show "$target:VERSION" 2>/dev/null) || stop "タグ $version に VERSION がありません。"
	[[ $tag_version == "$version" ]] || stop "タグ $version の VERSION（${tag_version}）が、バージョンと違います。"
	target_label="タグ $version"
fi
install_mode=$(git ls-tree "$target" -- install.sh | cut -c1-6)
[[ $install_mode == 100644 || $install_mode == 100755 ]] || stop "$target_label に、通常のファイルの install.sh がありません。"

# 出力先は、空にしておく。前に作ったものと混ざらないようにするため。
if [[ -e $out || -L $out ]]; then
	[[ -d $out && ! -L $out ]] || stop "出力先がディレクトリではありません: $out"
	[[ -z $(ls -A "$out") ]] || stop "出力先が空ではありません: $out"
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/build-assets.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
asset=multica-squad-kit-$version.tar.gz
prefix=multica-squad-kit-$version/

# 名前を表示するときは、制御文字だけを 8 進の形にし、漢字などのバイトは保つ。
display_name() {
	local name=$1 escaped= char i
	for ((i = 0; i < ${#name}; i++)); do
		char=${name:i:1}
		if [[ $char == [[:cntrl:]] ]]; then
			printf -v escaped '%s\\%03o' "$escaped" "'$char"
		else
			escaped=$escaped$char
		fi
	done
	printf '%s' "$escaped"
}

# 2: Git の木を NUL 区切りで読み、ディレクトリを含めて名前を確かめる。
git ls-tree -r -t -z --name-only "$target" >"$work/names" || stop '対象の木の名前を読めません。'
bad_names=0
while IFS= read -r -d '' name; do
	reason=
	if [[ $name == *[![:print:]]* ]]; then reason='印字できる ASCII ではない文字がある'; fi
	if [[ $name == *\\* ]]; then reason=${reason:+${reason}、}'バックスラッシュがある'; fi
	if [[ -n $reason ]]; then
		bad_names=$((bad_names + 1))
		if [[ $bad_names -le 20 ]]; then ui_error "$(display_name "$name"): $reason"; fi
	fi
done <"$work/names"
if [[ $bad_names -gt 0 ]]; then
	if [[ $bad_names -gt 20 ]]; then ui_error "ほかに $((bad_names - 20)) 件の名前が決まりに合いません。"; fi
	stop 'CONTRIBUTING.md の「ファイルとディレクトリの名前」に沿って、名前を ASCII に替えてください。'
fi

# 3: 対象の中身から配布物を作り、4: 作業ツリーの入口に一覧の確かめを委譲する。
git archive --format=tar.gz --prefix="$prefix" -o "$work/$asset" "$target" || stop '配布物を作れませんでした。'
bash install.sh --check-listing "$version" "$work/$asset" || stop 'CONTRIBUTING.md の「ファイルとディレクトリの名前」と docs/install.md の「展開の前の確かめ」を確認してください。'

# 5: 新しい一時の置き場に展開し、MANIFEST の一覧と中のファイルが一致し、MANIFEST の確かめが通ることを確かめる
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

# 6: 対象の install.sh を写し、2 つの SHA-256 を SHA256SUMS に書く
mkdir -p "$out"
cp "$work/$asset" "$out/$asset"
git show "$target:install.sh" >"$out/install.sh"
(cd "$out" && shasum -a 256 "$asset" install.sh >SHA256SUMS)
ui_line out success "配布物を作りました: ${out}（${asset}、install.sh、SHA256SUMS）"
