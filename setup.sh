#!/usr/bin/env bash
# 入口で配布物を確かめてから lib/ を読む。bash 3.2 で動かす。
set -euo pipefail
root=$(cd "$(dirname "$0")" && pwd)
die() { printf '%s\n' "$*" >&2; exit 1; }
[[ $# == 0 ]] || die '使い方: bash setup.sh（値は質問に答えて入力する）'
[[ $(uname -s) == Darwin ]] || die '対応する OS は macOS だけです。何も変更していません。'
cd "$root"
damaged() { die "原本のファイルが不足しているか改変されています。$* 原本を clone し、タグを取り出し直してください。"; }
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
source "$root/lib/check.sh"
source "$root/lib/questions.sh"
source "$root/lib/answers.sh"
source "$root/lib/host.sh"
source "$root/lib/workspace.sh"
source "$root/lib/render.sh"
source "$root/lib/project.sh"
source "$root/lib/squad.sh"
source "$root/lib/autopilots.sh"
source "$root/lib/extensions.sh"
setup_cleanup_enabled=yes
setup_cleanup() {
	local result=$?
	[[ -z ${extension_work:-} ]] || rm -rf -- "$extension_work"
	return "$result"
}
trap setup_cleanup EXIT
check_tools
choose_extension
choose_server
check_login
ask_questions
load_extension_inventory
confirm_answers
save_answers
printf '%s\n' 'ホストを準備しています。' >&2
prepare_host
printf '%s\n' '共通のラベルとスキルを合わせています。' >&2
prepare_workspace
printf '%s\n' 'プロジェクトの設定を始めます。' >&2
prepare_project
save_extension_inventory
