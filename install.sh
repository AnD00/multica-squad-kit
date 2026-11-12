#!/usr/bin/env bash
# clone せずに導入・更新する入口。Release の配布物を確かめてから展開し、セットアップを流す。
# 設計は docs/install.md の「入口のスクリプト」「標準入力から流すとき」。1 ファイルで動き、原本のほかのファイルを読まない。bash 3.2 で動かす。
# curl ... | bash のように標準入力から流されても動くよう、処理はすべて関数に入れ、最後の呼び出し（main を波括弧で囲んだ 1 つの塊）だけで流し始める。
set -euo pipefail

# 標準入力から流されているか。ファイルとして流すと BASH_SOURCE[0] にパスが入る。関数の中では見分けられないので、関数の外で決める。
if [[ -z ${BASH_SOURCE[0]-} ]]; then from_stdin=yes; else from_stdin=no; fi

repo=AnD00/multica-squad-kit
signer_workflow=$repo/.github/workflows/release-assets.yml
required_gh=2.102.0

# 画面の印と色。lib/ui.sh を読めないので、使う種類だけを同じ値で持つ（tests/install-test.sh が lib/ui.sh と照らす）。
ui_color_out=no
ui_color_err=no
ui_spec() {
	case $1 in
	success) printf '%s\n' '0 28' ;;
	warning) printf '%s\n' '1 166' ;;
	error) printf '%s\n' '1 196' ;;
	*) return 1 ;;
	esac
}
ui_init() {
	local colors
	ui_color_out=no
	ui_color_err=no
	[[ -z ${NO_COLOR+x} ]] || return 0
	case ${TERM:-} in '' | dumb) return 0 ;; esac
	colors=$(tput colors 2>/dev/null) || return 0
	[[ $colors =~ ^[0-9]+$ ]] && ((colors >= 256)) || return 0
	if [[ -t 1 ]]; then ui_color_out=yes; fi
	if [[ -t 2 ]]; then ui_color_err=yes; fi
	return 0
}
ui_paint() {
	local target=$1 kind=$2 text=$3 spec bold color enabled
	spec=$(ui_spec "$kind") || return 1
	bold=${spec% *}
	color=${spec#* }
	case $target in
	out) enabled=$ui_color_out ;;
	err) enabled=$ui_color_err ;;
	*) return 1 ;;
	esac
	if [[ $enabled != yes || ( $color == - && $bold == 0 ) ]]; then
		printf '%s' "$text"
	elif [[ $color == - ]]; then
		printf '\033[1m%s\033[0m' "$text"
	elif [[ $bold == 1 ]]; then
		printf '\033[1;38;5;%sm%s\033[0m' "$color" "$text"
	else
		printf '\033[38;5;%sm%s\033[0m' "$color" "$text"
	fi
}
ui_line() {
	if [[ $1 == err ]]; then ui_paint "$@" >&2; printf '\n' >&2
	else ui_paint "$@"; printf '\n'; fi
}
ui_error() { ui_line err error "エラー: $*"; }
ui_warning() { ui_line err warning "警告: $*"; }
ui_init

usage() {
	cat <<'USAGE'
使い方:
  bash install.sh [<バージョン>] [--extension <拡張のディレクトリ>]
  bash install.sh --verify <バージョン> <置き場>
  bash install.sh --help
<バージョン> は vX.Y.Z の形で渡す。省いたときは、最新の Release のバージョンを使う。
標準入力から流すときは、bash -s -- のあとに引数を渡す。セットアップの質問には、端末（/dev/tty）から答える。
--verify は、置き場にある配布物と SHA256SUMS を確かめるだけで、展開も実行もしない。
USAGE
}
# 引数の誤りは 2 で終わる。
usage_error() {
	if [[ $# -gt 0 ]]; then ui_error "$*"; fi
	usage >&2
	exit 2
}
# 確かめ、取得、展開のどれかで止まるときは 1 で終わる。
stop() {
	ui_error "$*"
	exit 1
}

# ver_ge <a.b.c> <x.y.z>: 数として順に比べ、a.b.c が x.y.z 以上なら 0。
ver_ge() {
	local IFS=.
	set -- $1 $2
	if ((10#$1 != 10#$4)); then
		((10#$1 > 10#$4))
		return
	fi
	if ((10#$2 != 10#$5)); then
		((10#$2 > 10#$5))
		return
	fi
	((10#$3 >= 10#$6))
}

# OS と道具を確かめる。
check_tools() {
	local tool
	case $(uname -s) in
	Darwin | Linux) ;;
	*) stop "対応するのは macOS と Linux（WSL 2 を含む）だけです: $(uname -s)" ;;
	esac
	for tool in gh tar shasum; do
		command -v "$tool" >/dev/null || stop "$tool がありません。$tool を入れてから流してください。"
	done
}

# gh のバージョンが、証明を確かめられるものか確かめる。読めないときも、古いときと同じに扱う。
check_gh_version() {
	local output first re version
	output=$(gh --version 2>/dev/null </dev/null) || output=
	first=${output%%$'\n'*}
	re='^gh version ([0-9]{1,9})\.([0-9]{1,9})\.([0-9]{1,9})'
	if [[ $first =~ $re ]]; then
		version=${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}
		if ver_ge "$version" "$required_gh"; then return 0; fi
		stop "gh のバージョンが古く、配布物の証明を確かめられません（今: ${version}、必要: $required_gh 以上）。gh を更新してから流し直してください。"
	fi
	stop "gh のバージョンを読めません（必要: $required_gh 以上）。gh --version の出力を確かめ、gh を更新してから流し直してください。"
}

# verify_attestation <ファイル> <バージョン>: 4 つの指定をそろえて、証明を確かめる。
verify_attestation() {
	local file=$1 version=$2 result
	result=$(gh attestation verify "$file" \
		--repo "$repo" \
		--signer-workflow "$signer_workflow" \
		--source-ref "refs/tags/$version" \
		--deny-self-hosted-runners 2>&1 </dev/null) || {
		printf '%s\n' "$result" >&2
		stop "証明を確かめられませんでした: ${file##*/}。展開も実行もしません。gh のログインは gh auth status で確かめられます。"
	}
}

# verify_checksum <置き場> <バージョン>: SHA256SUMS の配布物の行を 1 行だけ取り出し、配布物と照合する。
verify_checksum() {
	local dir=$1 asset=multica-squad-kit-$2.tar.gz line re count=0 expected= actual
	re='^([0-9a-f]{64})  (.+)$'
	while IFS= read -r line || [[ -n $line ]]; do
		if [[ $line =~ $re && ${BASH_REMATCH[2]} == "$asset" ]]; then
			count=$((count + 1))
			expected=${BASH_REMATCH[1]}
		fi
	done <"$dir/SHA256SUMS"
	[[ $count -ge 1 ]] || stop "SHA256SUMS に $asset の行がありません。"
	[[ $count -eq 1 ]] || stop "SHA256SUMS に $asset の行が 2 行以上あります。"
	actual=$(shasum -a 256 "$dir/$asset") || stop "$asset のチェックサムを計算できませんでした。"
	actual=${actual%% *}
	[[ $actual == "$expected" ]] || stop "$asset のチェックサムが、SHA256SUMS と違います。展開も実行もしません。"
}

# check_listing <配布物> <バージョン>: 展開の前に一覧を読み、展開先の外へ書くもの、読み違えのおそれがあるものを拒む。
# 一覧は LC_ALL=C で読み、GNU tar と bsdtar で同じ見分け方にする。
check_listing() {
	local archive=$1 prefix=multica-squad-kit-$2/ names verbose name line names_count verbose_count
	local had_lc_all=${LC_ALL+x} old_lc_all=${LC_ALL-}
	export LC_ALL=C
	names=$(tar -tzf "$archive") || stop '配布物の一覧を読めません。'
	verbose=$(tar -tvzf "$archive") || stop '配布物の詳細な一覧を読めません。'
	[[ -n $names ]] || stop '配布物が空です。'
	names_count=$(printf '%s\n' "$names" | wc -l)
	verbose_count=$(printf '%s\n' "$verbose" | wc -l)
	[[ $names_count -eq $verbose_count ]] || stop "配布物の 2 つの一覧の行の数が違います（$names_count と ${verbose_count}）。名前に改行があるおそれがあります。"
	while IFS= read -r name; do
		case $name in
		/*) stop "配布物に絶対パスがあります: $name" ;;
		esac
		case /$name/ in
		*/../*) stop "配布物に上へ出るパスがあります: $name" ;;
		esac
		case $name in
		"$prefix"*) ;;
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
	if [[ -n $had_lc_all ]]; then LC_ALL=$old_lc_all; else unset LC_ALL; fi
}

# verify_assets <バージョン> <置き場>: 置き場の SHA256SUMS と配布物を、証明、チェックサム、一覧の順に確かめる。展開はしない。
verify_assets() {
	local version=$1 dir=$2 asset=multica-squad-kit-$1.tar.gz
	[[ -d $dir ]] || stop "置き場がディレクトリではありません: $dir"
	[[ -f $dir/SHA256SUMS && ! -L $dir/SHA256SUMS ]] || stop "置き場に通常のファイルの SHA256SUMS がありません: $dir"
	[[ -f $dir/$asset && ! -L $dir/$asset ]] || stop "置き場に通常のファイルの $asset がありません: $dir"
	verify_attestation "$dir/SHA256SUMS" "$version"
	verify_checksum "$dir" "$version"
	verify_attestation "$dir/$asset" "$version"
	check_listing "$dir/$asset" "$version"
}

version_re='^v[0-9]+\.[0-9]+\.[0-9]+$'

# 一時の置き場。取得、展開、セットアップの流しのすべてを、この下に置く。
work_dir=
cleanup() {
	[[ -n $work_dir && -d $work_dir ]] || return 0
	chmod -R u+rwX "$work_dir" 2>/dev/null || true
	rm -rf -- "$work_dir" || ui_warning "一時の置き場を消せませんでした: $work_dir"
}

# fetch_assets <バージョン> <置き場>: 配布物と SHA256SUMS を、新しい空の置き場へ取ってくる。取り直しはしない。
fetch_assets() {
	local version=$1 dir=$2 asset=multica-squad-kit-$1.tar.gz result
	mkdir "$dir" || stop "取得先を作れません: $dir"
	result=$(gh release download "$version" --repo "$repo" --pattern "$asset" --pattern SHA256SUMS --dir "$dir" 2>&1 </dev/null) || {
		printf '%s\n' "$result" >&2
		stop "$version を取得できませんでした。gh のログインは gh auth status で確かめられます。"
	}
}

# check_extracted <展開先> <バージョン>: 展開したものに、リンクと、通常のファイルとディレクトリのほかのものがなく、VERSION が合うか確かめる。
check_extracted() {
	local dir=$1 version=$2 top=$1/multica-squad-kit-$2 found
	[[ -d $top && ! -L $top ]] || stop "展開したものに multica-squad-kit-${version} のディレクトリがありません。"
	found=$(find "$dir" ! -type f ! -type d -print -quit) || stop '展開したものを調べられませんでした。'
	[[ -z $found ]] || stop "展開したものに、通常のファイルとディレクトリのどちらでもないもの（リンクか特殊なファイル）があります: ${found#"$dir"/}"
	found=$(find "$dir" -type f -links +1 -print -quit) || stop '展開したものを調べられませんでした。'
	[[ -z $found ]] || stop "展開したものに、ハードリンクのファイルがあります: ${found#"$dir"/}"
	[[ -f $top/VERSION ]] || stop "展開したものに VERSION がありません。"
	[[ $(<"$top/VERSION") == "$version" ]] || stop "展開したものの VERSION が、指定したバージョン $version と違います。"
	[[ -f $top/setup.sh ]] || stop "展開したものに setup.sh がありません。"
}

# check_tty: 標準入力から流されているときは、セットアップの質問に端末から答えられるか、取得の前に確かめる。
check_tty() {
	[[ $from_stdin == yes ]] || return 0
	{ : </dev/tty; } 2>/dev/null || stop "端末（/dev/tty）を開けません。セットアップの質問に答えられないので、何も取らずに止まります。入口をファイルに取ってから bash install.sh で流してください。"
}

# latest_version: 最新の Release のバージョンを 1 回だけ読み、vX.Y.Z の形かを確かめて出す。
latest_version() {
	local result
	result=$(gh release view --repo "$repo" --json tagName --jq .tagName </dev/null) \
		|| stop "最新のバージョンを読めませんでした。gh のログインは gh auth status で確かめられます。バージョンを指定して流すこともできます。"
	[[ $result =~ $version_re ]] || stop "最新の Release のバージョンが vX.Y.Z の形ではありません: $result"
	printf '%s\n' "$result"
}

# run_setup <setup.sh> [引数...]: セットアップを子のプロセスとして流す。標準入力から流されているときは、標準入力が入口の残りなので、質問を端末から読ませる。
run_setup() {
	local setup=$1
	shift
	if [[ $from_stdin == yes ]]; then
		bash "$setup" "$@" </dev/tty
	else
		bash "$setup" "$@"
	fi
}

# install_release <バージョン> [拡張のディレクトリ]: 取得、確かめ、展開、確かめ、セットアップの順に行う。
# セットアップが終わったときはその終了コードで、止まったときは 1 で終わる。
install_release() {
	local version=$1 extension=${2-} asset=multica-squad-kit-$1.tar.gz setup_rc=0
	trap cleanup EXIT
	trap 'exit 129' HUP
	trap 'exit 130' INT
	trap 'exit 143' TERM
	# macOS の mktemp -d は TMPDIR を見ないので、名前の型を渡して、TMPDIR の下に作らせる。
	work_dir=$(mktemp -d "${TMPDIR:-/tmp}/multica-squad-kit.XXXXXX") || stop '一時の置き場を作れません。'
	echo "取得します: $version"
	fetch_assets "$version" "$work_dir/assets"
	verify_assets "$version" "$work_dir/assets"
	echo "確かめが通りました。展開します。"
	mkdir "$work_dir/src" || stop "展開先を作れません。"
	tar -xzf "$work_dir/assets/$asset" -C "$work_dir/src" || stop '配布物を展開できませんでした。'
	check_extracted "$work_dir/src" "$version"
	echo "セットアップを流します。"
	if [[ -n $extension ]]; then
		run_setup "$work_dir/src/multica-squad-kit-$version/setup.sh" --extension "$extension" || setup_rc=$?
	else
		run_setup "$work_dir/src/multica-squad-kit-$version/setup.sh" || setup_rc=$?
	fi
	exit "$setup_rc"
}

# parse_args <引数...>: 引数を読んで、mode・version・have_version・place・extension を決める。バージョンは最初の引数にだけ置ける。
mode=install
version=
have_version=no
place=
extension=
parse_args() {
	case ${1-} in
	--help | -h)
		[[ $# -eq 1 ]] || usage_error '--help に、ほかの引数は付けられません。'
		usage
		exit 0
		;;
	--verify)
		[[ $# -eq 3 ]] || usage_error '--verify は、バージョンと置き場の 2 つを渡してください。'
		mode=verify
		version=$2
		have_version=yes
		place=$3
		[[ -n $place ]] || usage_error '置き場が空です。'
		;;
	*)
		if [[ $# -gt 0 && $1 != -* ]]; then
			version=$1
			have_version=yes
			shift
		fi
		while [[ $# -gt 0 ]]; do
			case $1 in
			--extension)
				[[ $# -ge 2 && -z $extension ]] || usage_error '--extension は、拡張のディレクトリを 1 つだけ渡してください。'
				[[ -n $2 ]] || usage_error '拡張のディレクトリが空です。'
				extension=$2
				shift 2
				;;
			*) usage_error "知らない指定です: $1" ;;
			esac
		done
		;;
	esac
	if [[ $have_version == yes ]]; then
		[[ $version =~ $version_re ]] || usage_error "バージョンは vX.Y.Z の形で渡してください: $version"
	fi
}

main() {
	parse_args "$@"
	check_tools
	check_gh_version
	if [[ $mode == verify ]]; then
		verify_assets "$version" "$place"
		ui_line out success "確かめが通りました: ${version}（SHA256SUMS と配布物の証明、チェックサム、一覧）。展開も実行もしていません。"
		exit 0
	fi
	check_tty
	if [[ $have_version == no ]]; then
		version=$(latest_version)
		echo "使うバージョン: $version"
	fi
	install_release "$version" "$extension"
}

# 最後の呼び出しは、閉じ括弧まで届かなければ構文が成立しない形にする。
# main だけの行にすると、行の途中で切れたときに、引数のない main が流れてしまう。
{
	main "$@"
}
