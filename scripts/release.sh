#!/usr/bin/env bash
# バージョンを上げる PR のマージのあとに、VERSION のバージョンの注釈付きのタグと Release を出す。
# 下書きの Release を作り、発行のワークフローに配布物を作らせ、確かめてから公開する。
# 設計は docs/release.md。bash 3.2 で動かす。
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib/ui.sh
source lib/ui.sh
ui_init

# 配布物の確かめは、使う人の入口（install.sh）と同じ値で行う。docs/install.md の「確かめ方」。
attest_repo=AnD00/multica-squad-kit
attest_signer_workflow=$attest_repo/.github/workflows/release-assets.yml
required_gh=2.102.0
workflow_file=release-assets.yml
# 起こしたワークフローの実行を探す回数と間隔（秒）。間隔は、テストで 0 にするために環境変数で変えられる。
run_find_tries=10
run_find_interval=${RELEASE_RUN_FIND_INTERVAL:-3}
# 待つ間のゲージを読む間隔と、書き換えないときに経過の行を足す間隔（秒）。テストで短くするために環境変数で変えられる。
progress_interval=${RELEASE_PROGRESS_INTERVAL:-5}
watch_tick_interval=${RELEASE_WATCH_TICK_INTERVAL:-30}
ui_steps_wait_interval=$watch_tick_interval

usage() {
	cat <<'USAGE'
使い方: bash scripts/release.sh
原本のリポジトリのルートの main で流す。VERSION のバージョンのタグと Release を、確認のあとに出す。
下書きの Release を作り、配布物を作らせて確かめてから、公開する。
USAGE
}
# 手順の一覧の中で動いている手順があるあいだは yes。止まるときに、その手順を ✖ にしてから案内を出す。
step_running=no
stop() {
	fail_step
	ui_error "$*"
	exit 1
}
# 下書きの URL の次の行に、公開のあとのタグの名前の URL を足す。案内の文は変えない。
tag_url() {
	printf 'https://github.com/%s/releases/tag/%s' "$repo" "$version"
}
stop_with_draft_url() {
	ui_error "$*"
	printf '      → %s\n' "$(tag_url)" >&2
	exit 1
}
# fail_step [値]: 動いている手順を ✖ にする。続けて画面に出す前に呼ぶ（書き換えを止め、カーソルを一覧の下に置くため）。
fail_step() {
	[[ $step_running == yes ]] || return 0
	step_running=no
	ui_step_fail "${1-}"
}
# show_failure <コマンドの 1 行> <受けたファイル>: 灰の「$ コマンド」の行と、受けた中身をそのまま標準エラー出力に出す。
# 外のコマンドの出力とスクリプトの行の境目はコマンドの行で示し、区切りの文字の行は出さない。
show_failure() {
	ui_line err default "\$ $1"
	cat "$2" >&2
	if [[ -s $2 && -n $(tail -c 1 "$2") ]]; then printf '\n' >&2; fi
}
# command_failed <値> <コマンドの 1 行> <受けたファイル> <案内>: 手順を ✖ にし、コマンドの行と中身を出して、案内で止まる。
command_failed() {
	fail_step "$1"
	show_failure "$2" "$3"
	stop "$4"
}
# duration <秒>: 48s、1m12s の形。
duration() {
	if [[ $1 -lt 60 ]]; then printf '%ds' "$1"
	else printf '%dm%ds' "$(($1 / 60))" "$(($1 % 60))"; fi
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

# 確かめの一覧（docs/release.md の「確かめの一覧」）。止まるときの出力を変えないよう、結果の行はためておき、
# 端末の判定を通ったあとの確認で出す。1 行は「結果の語<タブ>項目の名前<タブ>読んだ値」。
check_rows=
add_check() {
	check_rows="${check_rows}$1"$'\t'"$2"$'\t'"$3"$'\n'
}

# 1: 道具と置き場所
tools='git gh tar shasum diff cmp'
for tool in $tools; do
	command -v "$tool" >/dev/null || stop "$tool がありません。"
done
# gh のバージョンは、docs/install.md の「必要な gh のバージョン」と同じ。読めないときも、古いときと同じに扱う。
gh_output=$(gh --version 2>/dev/null </dev/null) || gh_output=
gh_first=${gh_output%%$'\n'*}
gh_re='^gh version ([0-9]{1,9})\.([0-9]{1,9})\.([0-9]{1,9})'
if [[ $gh_first =~ $gh_re ]]; then
	gh_version=${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}
	ver_ge "$gh_version" "$required_gh" || stop "gh のバージョンが古く、配布物の証明を確かめられません（今: ${gh_version}、必要: $required_gh 以上）。gh を更新してから流し直してください。"
else
	stop "gh のバージョンを読めません（必要: $required_gh 以上）。gh --version の出力を確かめ、gh を更新してから流し直してください。"
fi
add_check 成功 道具 "${tools}  gh ${gh_version}  ${required_gh} 以上"
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
add_check 成功 場所 "$repo  $branch"

# 4: 追跡しているファイルの未コミットの変更。追跡していないファイルは公開する中身に入らない。
[[ -z $(git status --porcelain --untracked-files=no) ]] || stop '未コミットの変更があります。コミットするか戻してから流してください。'
add_check 成功 未コミットの変更 なし

# 5: origin の main と手元の main の一致。origin/main だけを更新し、タグは取ってこない。
git fetch --quiet --no-tags origin main || stop 'origin の main を取ってこれません。'
[[ $(git rev-parse HEAD) == "$(git rev-parse FETCH_HEAD)" ]] || stop '手元の main が origin/main と一致しません。未公開のコミットがあるか、origin/main に遅れています。`git pull --ff-only origin main` をしても合わないときは、PR でマージしてから流してください。'
commit=$(git rev-parse HEAD)
add_check 一致 'origin/main' "${commit:0:12}"

# 6: VERSION の形。タグの名前を決めるため、まず手元の main の先頭から読む。
version=$(git show "$commit:VERSION" 2>/dev/null | tr -d '\n') || version=
[[ $version =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || stop "VERSION が vX.Y.Z の形ではありません: ${version:-（空）}"

# 一時の置き場。macOS の mktemp -d は TMPDIR を見ないので、名前の型を渡して、TMPDIR の下に作らせる。
work_tmp=$(mktemp -d "${TMPDIR:-/tmp}/release.XXXXXX") || stop '一時の置き場を作れません。'
watch_pid=
stop_watch() {
	if [[ -n $watch_pid ]]; then
		kill "$watch_pid" 2>/dev/null || true
		wait "$watch_pid" 2>/dev/null || true
		watch_pid=
	fi
}
cleanup() {
	stop_watch
	ui_steps_cleanup
	chmod -R u+rwX "$work_tmp" 2>/dev/null || true
	rm -rf -- "$work_tmp"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

tar_name=multica-squad-kit-$version.tar.gz
bundle_name=multica-squad-kit-$version.sigstore.json

# read_release: Release の一覧から、そのバージョンのものを読み、次を決める。
#   release: none | draft | published
#   release_url: Release の URL
#   asset_status: （下書きのとき）empty | complete | bad
#   asset_names: 下書きの配布物の名前（bad のときの表示用）
#   id_tar, id_install, id_sums, id_bundle: complete のときの配布物の ID
# releases/tags/<バージョン> は下書きを返さないので、一覧から探す。
read_release() {
	local filter out line tab kind re_r re_a name id count_r=0 count_a=0
	local c_tar=0 c_install=0 c_sums=0 c_bundle=0 extra=0
	tab=$'\t'
	re_r="^R${tab}(true|false)${tab}(.*)\$"
	re_a="^A${tab}([0-9]+)${tab}(.*)\$"
	filter=".[] | select(.tag_name == \"$version\") | \"R\\t\\(.draft)\\t\\(.html_url)\", (.assets[] | \"A\\t\\(.id)\\t\\(.name)\")"
	release=none
	release_url=
	asset_status=
	asset_names=
	id_tar=
	id_install=
	id_sums=
	id_bundle=
	out=$(gh api --paginate "repos/$repo/releases?per_page=100" --jq "$filter" 2>"$work_tmp/gh-err" </dev/null) || stop "$version の Release の有無を GitHub から読めません: $(tr '\n' ' ' <"$work_tmp/gh-err")"
	while IFS= read -r line; do
		[[ -n $line ]] || continue
		if [[ $line =~ $re_r ]]; then
			count_r=$((count_r + 1))
			kind=${BASH_REMATCH[1]}
			release_url=${BASH_REMATCH[2]}
			if [[ $kind == true ]]; then release=draft; else release=published; fi
		elif [[ $line =~ $re_a && $count_r -ge 1 ]]; then
			count_a=$((count_a + 1))
			id=${BASH_REMATCH[1]}
			name=${BASH_REMATCH[2]}
			asset_names="${asset_names:+$asset_names }$name"
			case $name in
			"$tar_name")
				c_tar=$((c_tar + 1))
				id_tar=$id
				;;
			install.sh)
				c_install=$((c_install + 1))
				id_install=$id
				;;
			SHA256SUMS)
				c_sums=$((c_sums + 1))
				id_sums=$id
				;;
			"$bundle_name")
				c_bundle=$((c_bundle + 1))
				id_bundle=$id
				;;
			*) extra=$((extra + 1)) ;;
			esac
		else
			stop "$version の Release の一覧の形が、想定と違います。"
		fi
	done <<<"$out"
	[[ $count_r -le 1 ]] || stop "$version の Release が GitHub に $count_r 件あります。1 件だけにしてから流し直してください。"
	if [[ $release == draft ]]; then
		if [[ $count_a -eq 0 ]]; then
			asset_status=empty
		elif [[ $c_tar -eq 1 && $c_install -eq 1 && $c_sums -eq 1 && $c_bundle -eq 1 && $extra -eq 0 && $count_a -eq 4 ]]; then
			asset_status=complete
		else
			asset_status=bad
		fi
	fi
}

# タグと Release の状態: 手元と origin のタグを読み、表（docs/release.md）ですることを決める。--tags では取ってこない。
local_tag=$(git rev-parse --verify --quiet "refs/tags/$version") || local_tag=
remote_out=$(git ls-remote origin "refs/tags/$version") || stop 'origin のタグを読めません。'
remote_tag=$(printf '%s\n' "$remote_out" | awk -v ref="refs/tags/$version" '$2 == ref {print $1; exit}')
if [[ -n $local_tag && $(git cat-file -t "$local_tag") != tag ]]; then
	stop "手元の $version のタグは、注釈付きではありません。手で付けたタグのおそれがあるため、動かしません。"
fi
if [[ -n $local_tag && -z $remote_tag ]]; then
	stop "手元に $version のタグがありますが、origin にはありません（まだ公開されていません）。\`git tag -d $version\` で消してから流し直してください。"
fi
if [[ -z $local_tag && -n $remote_tag ]]; then
	stop "origin に $version のタグがありますが、手元にはありません。\`git fetch origin tag $version\` で取ってきてから流し直してください。"
fi
if [[ -n $local_tag && $local_tag != "$remote_tag" ]]; then
	stop "手元と origin の $version のタグが違います。タグは動かしません。"
fi
read_release
if [[ -z $local_tag && $release != none ]]; then
	if [[ $release == draft ]]; then
		stop_with_draft_url "$version のタグはありませんが、Release があります: $release_url"
	fi
	stop "$version のタグはありませんが、Release があります: $release_url"
fi
# することと、タグを付けるコミット: タグがなければ main の先頭、あればそのタグが指すコミット。
#   tag: タグから / draft: 下書きの作成から / workflow: 配布物の作成から / verify: 配布物の確かめから / published: 何もしない
if [[ -n $local_tag ]]; then
	commit=$(git rev-parse "refs/tags/$version^{commit}")
	case $release in
	none) action=draft ;;
	published) action=published ;;
	draft)
		case $asset_status in
		empty) action=workflow ;;
		complete) action=verify ;;
		*) stop_with_draft_url "$version の下書きの Release の配布物が、4 つそろっていないか、余分なものがあります（今: ${asset_names:-なし}）。GitHub の画面で、下書きの配布物を消してから流し直してください: $release_url" ;;
		esac
		;;
	esac
else
	action=tag
fi

# 6〜8: タグを付けるコミットの VERSION と CHANGELOG.md から確かめ、Release の本文を作る。
commit_version=$(git show "$commit:VERSION" 2>/dev/null | tr -d '\n') || commit_version=
[[ $commit_version == "$version" ]] || stop "$version のタグが指すコミットの VERSION（${commit_version:-空}）が、タグの名前と違います。"

# 7: CHANGELOG.md の先頭のバージョン
changelog=$(git show "$commit:CHANGELOG.md" 2>/dev/null) || stop 'CHANGELOG.md を読めません。'
top_version=$(printf '%s\n' "$changelog" | awk '/^## / {print $2; exit}')
[[ $top_version == "$version" ]] || stop "VERSION（${version}）と CHANGELOG.md の先頭のバージョン（${top_version:-なし}）が違います。"

# 8: そのバージョンの節。次の ## の見出しの前までで、前後の空行を除いたものが Release の本文になる。
notes=$(printf '%s\n' "$changelog" | awk -v heading="## $version" '$0 == heading {found = 1; next} found && /^## / {exit} found')
[[ -n $(printf '%s' "$notes" | tr -d '[:space:]') ]] || stop "CHANGELOG.md の $version の節が空です。"
notes=$(printf '%s\n' "$notes" | awk 'NF {if (started) for (; blank > 0; blank--) print ""; started = 1; blank = 0; print; next} started {blank++}')
add_check 一致 バージョン "VERSION ${commit_version}  CHANGELOG.md ${top_version}"
# タグと Release の行。値は、手元のタグ、origin のタグ、Release の順に読む。
if [[ -z $local_tag ]]; then
	add_check 新規 'タグと Release' '手元 なし  origin なし  Release なし'
else
	case $release in
	none) release_text=なし ;;
	draft) release_text="下書き（配布物 $(printf '%s\n' "$asset_names" | wc -w | tr -d ' ') 個）" ;;
	published) release_text=公開済み ;;
	esac
	add_check 既存 'タグと Release' "手元 あり  origin あり（同じ）  Release $release_text"
fi

# 公開済みのバージョンは、確かめを済ませてから、何もせずに成功で終わる。端末でなくても終わる。
if [[ $action == published ]]; then
	printf '%s のタグと Release は、すでに出してあります: %s\n' "$version" "$release_url"
	exit 0
fi

# 確認: 確かめの一覧、本文、要約を標準出力に出し、問いを標準エラー出力に出して、標準入力の答えを読む。
[[ -t 0 ]] || stop '標準入力が端末でないため、確認を求められません。端末から流してください。'
while IFS=$'\t' read -r check_word check_name check_value; do
	printf '  '
	ui_mark out ok "$(ui_pad 16 "$check_name")" "$check_value"
done <<<"${check_rows%$'\n'}"
printf '\n'
while IFS= read -r note_line; do
	printf '  '
	ui_body_line out "$note_line"
done <<<"$notes"
printf '\n  '
ui_paint out strong "$version"
printf '  '
ui_line out default "$repo"
printf '  '
ui_paint out default "${commit:0:12}"
printf '  %s\n\n' "$(git log -1 --format=%s "$commit")"
# すること: 公開の手順の表（docs/release.md の「公開」）のうち、することから決まる手順だけを、1 から振り直して並べる。
case $action in
tag) step_first=1 ;;
draft) step_first=2 ;;
workflow) step_first=3 ;;
verify) step_first=4 ;;
esac
step_names=(
	'タグを作って push する'
	'下書きの Release を作る'
	'発行のワークフローに配布物を作らせ、終わるまで待つ'
	'配布物を確かめる'
	'Release を公開する'
)
remaining_steps=("${step_names[@]:$((step_first - 1))}")
# 確認の前は、端末でも切らずに順に出す。承認のあとの書き換えは、問いを覚えてから始める。
release_live_out=$ui_live_out
ui_live_out=no
ui_steps_begin out 2 "${remaining_steps[@]}"
ui_live_out=$release_live_out
ui_steps_show
printf '\n'
printf '公開しますか [y/N]: ' >&2
answer=
read -r answer || :
[[ $answer == y || $answer == Y ]] || stop '公開を取りやめました。'
if [[ $ui_live_out == yes && $ui_live_err == yes ]]; then
	ui_steps_tail $'\n'"公開しますか [y/N]: $answer"$'\n'
fi
# 確認で並べた手順を、同じ名前で、その場で進める。<表の番号> は docs/release.md の「公開」の表の番号で、
# 確認の一覧の番号（step_first から数え直したもの）に直して渡す。
begin_step() {
	ui_step_start "$(($1 - step_first + 1))"
	step_running=yes
}
end_step() {
	step_running=no
	ui_step_done "${1-}"
}

# read_gauge: 実行のジョブのステップのうち、終わったものの数と全体の数を gauge_done と gauge_total に置く。
# 読めないときや、ステップがまだないときは、1 を返す。
read_gauge() {
	local out
	out=$(gh run view "$run_id" --repo "$repo" --json jobs --jq '[.jobs[].steps[]?] | "\(map(select(.status == "completed")) | length)\t\(length)"' 2>/dev/null </dev/null) || return 1
	gauge_done=${out%%$'\t'*}
	gauge_total=${out#*$'\t'}
	[[ $gauge_done =~ ^[0-9]+$ && $gauge_total =~ ^[0-9]+$ && $gauge_total -gt 0 ]]
}

# gh run watch を裏で流し、終わるまで、動いている手順の行のスピナー、ゲージ、経過の時間を更新する。
# ゲージは書き換えるときだけ読む（書き換えないときは gh を余分に呼ばない）。読めなければ前の割合のまま。
# 成否は gh run watch の終了コードだけで決める。出力はファイルに受けて、画面に出さない。
watch_workflow() {
	local status=0 elapsed last_elapsed=-1 last_gauge=$SECONDS
	watch_command=(gh run watch "$run_id" --repo "$repo" --exit-status)
	"${watch_command[@]}" >"$work_tmp/watch-output" 2>&1 </dev/null &
	watch_pid=$!
	ui_step_progress 0 1 '' nocount
	while kill -0 "$watch_pid" 2>/dev/null; do
		if [[ $ui_steps_live == yes ]] && ((SECONDS - last_gauge >= progress_interval)); then
			last_gauge=$SECONDS
			if read_gauge; then ui_step_progress "$gauge_done" "$gauge_total" '' nocount; fi
		fi
		elapsed=$((SECONDS - workflow_started))
		if ((elapsed != last_elapsed)); then
			last_elapsed=$elapsed
			ui_step_wait "$elapsed"
		fi
		sleep 0.1
	done
	wait "$watch_pid" || status=$?
	watch_pid=
	stop_watch
	return "$status"
}

# find_run <起こした時刻>: 起こした時刻のあとに作られた、workflow_dispatch の実行で、headBranch がバージョンのものを探す。
# 起こしてから一覧に出るまで間があるので、決まった回数だけ間を空けて読み直す。見つかった実行を run_id と run_url に置く。
find_run() {
	local since=$1 try=0 out filter count
	filter=".[] | select(.event == \"workflow_dispatch\" and .headBranch == \"$version\" and .createdAt >= \"$since\") | \"\\(.databaseId)\\t\\(.url)\""
	run_id=
	run_url=
	while [[ $try -lt $run_find_tries ]]; do
		try=$((try + 1))
		out=$(gh run list --repo "$repo" --workflow "$workflow_file" --event workflow_dispatch --limit 20 --json databaseId,headBranch,createdAt,event,url --jq "$filter" 2>"$work_tmp/gh-err" </dev/null) || stop "発行のワークフローの実行の一覧を読めません: $(tr '\n' ' ' <"$work_tmp/gh-err")下書きは残してあります。"
		count=$(printf '%s' "$out" | grep -c . || true)
		if [[ $count -gt 1 ]]; then
			stop "起こした時刻のあとの $workflow_file の実行が $count 件あり、どれか決められません。下書きは残してあります。GitHub の Actions の画面で実行を確かめ、終わってから流し直してください。"
		fi
		if [[ $count -eq 1 ]]; then
			run_id=${out%%$'\t'*}
			run_url=${out#*$'\t'}
			[[ $run_id =~ ^[0-9]+$ ]] || stop "発行のワークフローの実行の ID を読めません: $run_id"
			return 0
		fi
		if [[ $try -lt $run_find_tries ]]; then sleep "$run_find_interval"; fi
	done
	stop "起こした $workflow_file の実行が、一覧に見つかりません。下書きは残してあります。GitHub の Actions の画面で実行を確かめてください。動いているなら終わってから、配布物が載っていなければ、流し直してください。"
}

# verify_stop <理由>: 公開の前の確かめで止まる。公開せず、下書きと配布物は残す。
verify_stop() {
	stop "$1 公開しません。下書きと配布物は残してあります。配布物の差し替えのおそれがあるので、人が確かめるまで流し直さないでください。"
}

# attest <ファイル> <束>: docs/install.md の「確かめ方」の 4 つの指定をそろえて、証明の束を確かめる。
attest() {
	local file=$1 bundle=$2 result
	result=$(gh attestation verify "$file" \
		--bundle "$bundle" \
		--repo "$attest_repo" \
		--signer-workflow "$attest_signer_workflow" \
		--source-ref "refs/tags/$version" \
		--deny-self-hosted-runners 2>&1 </dev/null) || {
		fail_step
		printf '%s\n' "$result" >&2
		verify_stop "証明の束で、${file##*/} の証明を確かめられませんでした。"
	}
}

# download_asset <ID> <名前> <置き場>: 下書きの配布物を、ID から取ってくる。下書きの配布物は、タグの名前からは取れない。
download_asset() {
	local id=$1 name=$2 dir=$3
	gh api -H 'Accept: application/octet-stream' "repos/$repo/releases/assets/$id" >"$dir/$name" 2>"$work_tmp/gh-err" </dev/null || verify_stop "配布物を取得できませんでした: $name"
	[[ -f $dir/$name && ! -L $dir/$name ]] || verify_stop "配布物を取得できませんでした: $name"
}

# verify_row <項目の名前> <値>: 通った確かめの行を、4 の手順の続きの行に足す。名前は一番長いものにそろえる。
verify_row() {
	ui_step_line ok "$(ui_pad 19 "$1")" "$2"
}

# 公開の前の確かめ（docs/release.md の「公開の前の確かめ」）。
verify_draft() {
	local vdir=$work_tmp/verify assets tag_install sums_line sums_count line re actual
	assets=$vdir/assets
	tag_install=$vdir/tag-install.sh
	mkdir -p "$assets" "$vdir/archive" "$vdir/expected" || stop '確かめる置き場を作れません。'
	# 1: 一覧で読み直した ID で、4 つを新しい置き場へ取ってくる。
	read_release
	[[ $release == draft && $asset_status == complete ]] || stop "$version の下書きの Release に、配布物が 4 つそろっていません（今: ${asset_names:-なし}）。公開しません。下書きは残してあります。"
	download_asset "$id_tar" "$tar_name" "$assets"
	download_asset "$id_install" install.sh "$assets"
	download_asset "$id_sums" SHA256SUMS "$assets"
	download_asset "$id_bundle" "$bundle_name" "$assets"
	# 2: タグの install.sh で、使う人の入口と同じ確かめ（証明、チェックサム、一覧）を流す。
	git ls-tree "$version" -- install.sh | grep -Eq '^100(644|755) blob ' || verify_stop 'タグの install.sh が、通常のファイルではありません。'
	git show "$version:install.sh" >"$tag_install" || verify_stop 'タグの install.sh を読めません。'
	# install.sh の文は導入する人に向けたものなので、画面に出さない。失敗したときだけ、そのまま出す。
	install_command=(bash "$tag_install" --verify "$version" "$assets")
	if ! "${install_command[@]}" >"$work_tmp/install-output" 2>&1 </dev/null; then
		fail_step
		show_failure "${install_command[*]}" "$work_tmp/install-output"
		verify_stop "タグの install.sh の --verify が通りませんでした。"
	fi
	verify_row 'タグの install.sh' '証明  チェックサム  tar.gz の中の一覧'
	# 3: 配布物の install.sh の証明、SHA256SUMS の行、タグの install.sh との一致。
	attest "$assets/install.sh" "$assets/$bundle_name"
	sums_count=0
	actual=$(shasum -a 256 "$assets/install.sh") || verify_stop 'install.sh のチェックサムを計算できません。'
	actual=${actual%% *}
	re='^([0-9a-f]{64})  (.+)$'
	while IFS= read -r line || [[ -n $line ]]; do
		if [[ $line =~ $re && ${BASH_REMATCH[2]} == install.sh ]]; then
			sums_count=$((sums_count + 1))
			sums_line=${BASH_REMATCH[1]}
		fi
	done <"$assets/SHA256SUMS"
	[[ $sums_count -eq 1 ]] || verify_stop "SHA256SUMS の install.sh の行が、1 行ではありません（$sums_count 行）。"
	[[ $sums_line == "$actual" ]] || verify_stop "install.sh のチェックサムが、SHA256SUMS と違います。"
	cmp -s "$assets/install.sh" "$tag_install" || verify_stop "配布物の install.sh が、タグの install.sh と違います。"
	verify_row '配布物の install.sh' '証明  SHA256SUMS の行  タグの install.sh'
	# 4: 配布物を展開したものと、git archive を展開したものを比べる。
	tar -xzf "$assets/$tar_name" -C "$vdir/archive" || verify_stop '配布物を展開できません。'
	git archive --format=tar --prefix="multica-squad-kit-$version/" "$version" | tar -xf - -C "$vdir/expected" || verify_stop 'タグの中身を取り出せません。'
	diff -r "$vdir/archive" "$vdir/expected" >"$vdir/diff" 2>&1 || {
		fail_step
		head -n 20 "$vdir/diff" >&2
		verify_stop '配布物の中身が、git archive で取り出したタグの中身と違います。'
	}
	verify_row '配布物の中身' "git archive $version"
	# 5: 証明の束で、3 つの証明を確かめる。
	attest "$assets/$tar_name" "$assets/$bundle_name"
	attest "$assets/SHA256SUMS" "$assets/$bundle_name"
	verify_row 証明 '配布物  SHA256SUMS'
}

# 確かめるところから続けたときは、この実行でワークフローを起こしていないので、成功した実行のうち最も新しいものを探す。
# 読めない、または見つからないときは、止まらずに、見つからないことを返す。
find_past_run() {
	local filter out
	filter=".[] | select(.event == \"workflow_dispatch\" and .headBranch == \"$version\" and .conclusion == \"success\") | .url"
	out=$(gh run list --repo "$repo" --workflow "$workflow_file" --event workflow_dispatch --limit 20 --json headBranch,conclusion,event,url --jq "$filter" 2>/dev/null </dev/null) || out=
	printf '%s' "${out%%$'\n'*}"
}

# 公開: 確認で出したコミットを明示してタグを作る。--force は付けない。
printf '%s\n' "$notes" >"$work_tmp/notes"
# 1: タグを作り、push する。push の出力は画面に出さない。失敗したときは、この実行で作った手元のタグを消す。
if [[ $action == tag ]]; then
	begin_step 1
	git tag -a "$version" -m "$version" "$commit" || stop 'タグを作れませんでした。'
	push_command=(git push origin "refs/tags/$version")
	if ! "${push_command[@]}" >"$work_tmp/push-output" 2>&1; then
		git tag -d "$version" >/dev/null
		command_failed '' "${push_command[*]}" "$work_tmp/push-output" 'タグの push に失敗しました。手元のタグを消したので、流し直せます。'
	fi
	end_step "$version  ${commit:0:12}"
fi
# 2: 下書きの Release を作る。標準出力は URL として読み、標準エラー出力は失敗したときだけ画面に出す。
if [[ $action == tag || $action == draft ]]; then
	begin_step 2
	create_command=(gh release create "$version" --repo "$repo" --draft --verify-tag --title "$version" --notes-file "$work_tmp/notes")
	if ! url=$("${create_command[@]}" 2>"$work_tmp/create-error" </dev/null); then
		if [[ $action == draft ]]; then
			create_message='下書きの Release の作成に失敗しました。同じコマンドを流し直すと、下書きの作成から続けます。'
		else
			create_message='タグは push しましたが、下書きの Release の作成に失敗しました。同じコマンドを流し直すと、下書きの作成から続けます。'
		fi
		command_failed '' "${create_command[*]}" "$work_tmp/create-error" "$create_message"
	fi
	# 灰の下書きの URL は今だけのもの。矢印の先が、公開のあとの URL。
	if [[ -n $url ]]; then ui_step_line - '' "$url"; fi
	ui_step_line - "→ $(tag_url)"
	end_step
fi
# 3: 配布物を作らせ、終わるまで待つ。
if [[ $action != verify ]]; then
	begin_step 3
	workflow_started=$SECONDS
	since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	run_command=(gh workflow run "$workflow_file" --repo "$repo" --ref "$version")
	"${run_command[@]}" >"$work_tmp/workflow-output" 2>&1 </dev/null ||
		command_failed '' "${run_command[*]}" "$work_tmp/workflow-output" '発行のワークフローを起こせませんでした。下書きは残してあります。同じコマンドを流し直すと、配布物を作らせ直します。'
	find_run "$since"
	ui_step_line - '' "$run_url"
	watch_workflow ||
		command_failed "$run_url" "${watch_command[*]}" "$work_tmp/watch-output" "発行のワークフローが失敗しました: ${run_url}。下書きは残してあります。配布物が 1 つも載っていなければ、流し直すと配布物を作らせ直します。途中まで載っているときは、GitHub の画面で下書きの配布物を消してから流し直してください。"
	end_step "$(duration "$((SECONDS - workflow_started))")"
fi
# 4: 配布物を確かめる。
begin_step 4
verify_draft
end_step
# 5: 公開する。
begin_step 5
edit_command=(gh release edit "$version" --repo "$repo" --draft=false)
if ! url=$("${edit_command[@]}" 2>"$work_tmp/edit-error" </dev/null); then
	command_failed '' "${edit_command[*]}" "$work_tmp/edit-error" 'Release の公開に失敗しました。下書きは残してあります。同じコマンドを流し直すと、配布物を確かめ直して公開します。'
fi
end_step
# 終わりのまとめ（docs/release.md の「終わりのまとめ」）。
[[ $action != verify ]] || run_url=$(find_past_run)
printf '\n'
ui_line out done "${version} の Release を公開しました"
printf '  バージョン: %s\n' "$version"
printf '  コミット: %s\n' "$commit"
printf '  Release: %s\n' "${url:-https://github.com/$repo/releases/tag/$version}"
printf '  配布物:\n'
for asset_name in "$tar_name" install.sh SHA256SUMS "$bundle_name"; do
	printf '    %s\n' "$asset_name"
done
printf '  発行のワークフロー: %s\n' "${run_url:-見つかりません（GitHub の Actions の画面で確かめてください）}"
