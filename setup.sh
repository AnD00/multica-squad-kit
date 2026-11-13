#!/usr/bin/env bash
# 入口で配布物を確かめてから lib/ を読む。bash 3.2 で動かす。
set -euo pipefail
root=$(cd "$(dirname "$0")" && pwd)
# lib/ui.sh を読み込む前（MANIFEST の確認が終わるまで）の die は、色を付けず印だけを付ける。
die() { printf 'エラー: %s\n' "$*" >&2; exit 1; }
# 拡張のディレクトリと、タグを取り出さない指定だけを引数で受ける。ほかの値は質問で聞き、保存済みの答えを既定にする。
usage='使い方: bash setup.sh [--extension <拡張のディレクトリ>] [--no-checkout]（ほかの値は質問に答えて入力する）'
extension_option=''
checkout_option=yes
while [[ $# -gt 0 ]]; do
	case $1 in
	--extension) [[ $# -ge 2 && -n $2 && -z $extension_option ]] || die "$usage"; extension_option=$2; shift 2 ;;
	--extension=*) [[ -n ${1#--extension=} && -z $extension_option ]] || die "$usage"; extension_option=${1#--extension=}; shift ;;
	--no-checkout) [[ $checkout_option == yes ]] || die "$usage"; checkout_option=no; shift ;;
	*) die "$usage" ;;
	esac
done
# 原本のルートへ移る前に、流した場所から見たパスにする。
[[ -z $extension_option || $extension_option == /* ]] || extension_option=$PWD/$extension_option
case $(uname -s) in
Darwin) ;;
Linux)
	case $(uname -r) in
	*[Mm]icrosoft-standard*|*[Ww][Ss][Ll]2*) ;;
	*[Mm]icrosoft*) die 'WSL 1 は対象外です。WSL 2 を使ってください。何も変更していません。' ;;
	esac
	;;
*) die '対応する OS は macOS と Linux（WSL 2 を含む）です。この OS は対象外です。何も変更していません。' ;;
esac
# 原本を検査する道具は、lib を読み込む前に確認する。
for tool in find sort shasum; do
	command -v "$tool" >/dev/null || die "$tool がありません。manual.md の「受け取る人の準備」に従って導入してください。Ubuntu では sudo apt-get install coreutils findutils libdigest-sha-perl、macOS では標準の道具と PATH を確認してください。何も変更していません。"
done
# clone した原本は、最新のリリースのタグを取り出し、そのバージョンの setup.sh で流し直す。
# VERSION からタグの URL を作るので、手元の中身がタグと違うと、バージョンの混ざった導入になる。
# ZIP を展開した原本は .git がなく、展開したバージョンのまま流す。
# 関数にするのは、checkout で setup.sh が書き換わる前に、exec までを読み終えておくため。
# 流し直す先が古いバージョンでも受けるよう、取り出し済みの印は引数でなく環境変数で渡す。
use_latest_tag() {
	local checked=${SQUAD_KIT_TAG_CHECKED_OUT:-} tag target
	unset SQUAD_KIT_TAG_CHECKED_OUT
	[[ $checkout_option == yes && -e $root/.git && -z $checked ]] || return 0
	command -v git >/dev/null || die 'git がありません。manual.md の「受け取る人の準備」に従って導入してください。何も変更していません。'
	git -C "$root" fetch --quiet --tags origin || die 'origin からタグを取れません。ネットワークと git remote -v の origin を確かめて、流し直してください。何も変更していません。'
	tag=$(git -C "$root" tag --list 'v*' --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1) || true
	[[ -n $tag ]] || die 'origin にリリースのタグがありません。何も変更していません。'
	target=$(git -C "$root" rev-parse --verify --quiet "refs/tags/$tag^{commit}") || die "タグ $tag を読めません。何も変更していません。"
	[[ $(git -C "$root" rev-parse HEAD) != "$target" ]] || return 0
	[[ -z $(git -C "$root" status --porcelain --untracked-files=no) ]] || die "原本に未コミットの変更があるので、最新のタグ $tag を取り出せません。変更を退避するか捨てて流し直すか、今のバージョンのまま流すなら --no-checkout を付けてください。何も変更していません。"
	git -C "$root" -c advice.detachedHead=false checkout --quiet --detach "$target" || die "タグ $tag を取り出せません。git status で原本の状態を確かめてください。"
	printf '最新のタグ %s を取り出しました。そのバージョンで流し直します。\n' "$tag" >&2
	export SQUAD_KIT_TAG_CHECKED_OUT=$tag
	if [[ -n $extension_option ]]; then
		exec "$BASH" "$root/setup.sh" --extension "$extension_option"
	fi
	exec "$BASH" "$root/setup.sh"
}
use_latest_tag
cd "$root"
damaged() { die "原本のファイルが不足しているか改変されています。$* 原本を取り直して、流してください。"; }
[[ -f MANIFEST && ! -L MANIFEST ]] || damaged 'MANIFEST がありません。'
listed=''
while IFS= read -r line || [[ -n $line ]]; do
	[[ ${line:0:64} =~ ^[0-9a-f]{64}$ && ${line:64:2} == '  ' ]] || damaged 'MANIFEST の書式が不正です。'
	file=${line:66}
	[[ $file == ./* && $file != *$'\r'* && $file != ./MANIFEST && $file != ./tmp/* ]] || damaged 'MANIFEST のファイル名が不正です。'
	case /${file#./}/ in */../*|*/./*) damaged 'MANIFEST に範囲外のパスがあります。' ;; esac
	[[ -f $file && ! -L $file ]] || damaged "ファイルがありません: $file"
	listed+="$file"$'\n'
done <MANIFEST
[[ -n $listed ]] || damaged 'MANIFEST が空です。'
[[ -z $(find . \( -path ./.git -o -path ./tmp \) -prune -o -type l -print) ]] || damaged 'シンボリックリンクがあります。'
actual=$(find . \( -path ./.git -o -path ./tmp \) -prune -o -type f ! -path ./MANIFEST -print | LC_ALL=C sort)
expected=$(printf '%s' "$listed" | LC_ALL=C sort)
[[ $actual == "$expected" ]] || damaged 'MANIFEST とファイルの一覧が違います。'
shasum -a 256 -c MANIFEST >/dev/null || damaged 'ファイルの内容が違います。'
source "$root/lib/ui.sh"
source "$root/lib/check.sh"
source "$root/lib/questions.sh"
source "$root/lib/answers.sh"
source "$root/lib/host.sh"
source "$root/lib/workspace.sh"
source "$root/lib/render.sh"
source "$root/lib/project.sh"
source "$root/lib/setup-issues.sh"
source "$root/lib/project-changes.sh"
source "$root/lib/webhooks.sh"
source "$root/lib/installation.sh"
source "$root/lib/squad.sh"
source "$root/lib/autopilots.sh"
source "$root/lib/extensions.sh"
source "$root/lib/version.sh"
setup_cleanup_enabled=yes
setup_cleanup() {
	local result=$?
	ui_steps_cleanup
	[[ -z ${extension_work:-} ]] || rm -rf -- "$extension_work"
	return "$result"
}
trap setup_cleanup EXIT
ui_init
# 作る間の一覧が動いているときは、動いていた手順を ✖ にしてから、今と同じエラーの行を出す。
die() { ui_phase_fail; ui_error "$*"; exit 1; }
check_tools
choose_extension
choose_server
check_login
check_update
ask_questions
resolve_link_repositories
load_extension_inventory
confirm_answers
save_answers
# 作る間の一覧。手順の番号は docs/screens.md の「作成の進み」の表と同じで、3 から 13 までは prepare_project が進める。
printf '\n' >&2
ui_steps_begin err 2 'ホストを準備' '共通のラベルとスキル' 'プロジェクトとリポジトリ' 'エージェントの ID' 'スクワッド' '指示とスキル' 'エージェントを設定' 'エージェントを公開' 'スクワッドのメンバー' 'オートパイロット' 'Webhook' '導入の確認' 'タスクの起票'
# 子のプロセスの中の通知を受ける置き場。MANIFEST の確認の対象外の tmp/ に置く。
mkdir -p "$root/tmp" || die '作業用の置き場を作れませんでした。'
ui_steps_notice_file=$(mktemp "$root/tmp/notices.XXXXXX") || die '作業用の置き場を作れませんでした。'
ui_phase_start 1
prepare_host
ui_phase_done "$(host_gate_summary)"
ui_phase_start 2
prepare_workspace
ui_phase_done
prepare_project
save_extension_inventory
record_installed_version
