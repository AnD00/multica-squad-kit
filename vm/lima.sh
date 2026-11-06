#!/usr/bin/env bash
# Mac（bash 3.2）から、ホストのファイルを共有しない Lima の VM を扱う。
set -euo pipefail
die() { printf 'lima: %s\n' "$*" >&2; exit 1; }
usage() {
	cat <<'USAGE'
bash vm/lima.sh create [--name NAME] [--cpus N] [--memory GIB] [--disk GIB]
bash vm/lima.sh start|stop|verify [--name NAME] [--force]
bash vm/lima.sh delete [--name NAME] [--force] [--yes]
USAGE
}
[[ $# -gt 0 ]] || { usage >&2; exit 2; }
action=$1
shift
case $action in create|start|stop|delete|verify) ;; --help|-h) usage; exit 0 ;; *) die '操作は create、start、stop、delete、verify です。' ;; esac
name=multica-squad cpus=4 memory=8 disk=100 force=no yes=no
while [[ $# -gt 0 ]]; do
	case $1 in
	--name|--cpus|--memory|--disk)
		[[ $# -ge 2 ]] || die "$1 の値がありません。"
		case $1 in
		--name) name=$2 ;;
		*)
			[[ $action == create ]] || die "$1 は create だけで使えます。"
			[[ $2 =~ ^[0-9]+$ && $2 =~ [1-9] && ${#2} -le 6 ]] || die 'CPU・メモリ・ディスクは正の整数にしてください。'
			value=$2
			while [[ $value == 0* ]]; do value=${value#0}; done
			case $1 in --cpus) cpus=$value ;; --memory) memory=$value ;; --disk) disk=$value ;; esac ;;
		esac
		shift 2 ;;
	--force)
		[[ $action != create ]] || die '--force は create では使えません。'
		force=yes; shift ;;
	--yes)
		[[ $action == delete ]] || die '--yes は delete だけで使えます。'
		yes=yes; shift ;;
	*) die "知らない引数です: $1" ;;
	esac
done
[[ $name =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die 'VM の名前は英数字で始まる英数字・点・下線・ハイフンにしてください。'
[[ $(uname -s) == Darwin ]] || die 'Mac で実行してください。'
command -v limactl >/dev/null || die 'Lima 1.0.0 以上を導入してください。'
command -v plutil >/dev/null || die 'macOS 標準の plutil が必要です。'
version=$(limactl --version) || die 'Lima の版を読めません。'
[[ $version =~ ^limactl[[:space:]]version[[:space:]]([0-9]+)\.([0-9]+)\.([0-9]+)(\+[A-Za-z0-9.-]+)?$ ]] || die 'Lima 1.0.0 以上の正式版を使ってください。'
(( 10#${BASH_REMATCH[1]} >= 1 )) || die 'Lima 1.0.0 以上が必要です。'
script_dir=$(cd "$(dirname "$0")" && pwd)

# list --json は 1 インスタンスに 1 オブジェクトなので、存在を確かめて 1 件を読む。
names=$(limactl list --quiet) || die 'VM の一覧を読めません。'
exists=no
while IFS= read -r candidate; do
	if [[ $candidate == "$name" ]]; then exists=yes; fi
done <<<"$names"
json_field() { printf '%s\n' "$instance" | plutil -extract "$1" raw -expect "$2" -o - - 2>/dev/null; }
read_instance() {
	instance=$(limactl list --json "$name") || die 'VM の実効設定を読めません。'
	[[ $(json_field name string) == "$name" ]] || die 'VM の名前を JSON で確認できません。'
	state=$(json_field status string) || die 'VM の状態を JSON で確認できません。'
}
empty_array() {
	local count
	if count=$(json_field "$1" array); then [[ $count == 0 ]]; else
		# omitempty で省略された空の配列は許し、型が違う値は拒否する。
		! printf '%s\n' "$instance" | plutil -type "$1" - >/dev/null 2>&1
	fi
}
isolated() {
	local field
	empty_array errors || return 1
	empty_array config.mounts || return 1
	for field in config.ssh.forwardAgent config.ssh.forwardX11 config.ssh.loadDotSSHPubKeys config.containerd.system config.containerd.user; do
		[[ $(json_field "$field" bool) == false ]] || return 1
	done
}
require_isolated() {
	isolated || die '共有か鍵の持ち込みが切れていません。Lima の _config/default.yaml と override.yaml を確認してください。'
}
verify_guest() { limactl shell "$name" bash /usr/local/lib/multica-squad-vm/verify.sh lima; }

# jq は準備済みのゲストのものを使う。状態を読めない・件数が不明なら止めない。
require_idle() {
	local active
	[[ $force == no ]] || return 0
	[[ $state != Stopped ]] || return 0
	[[ $state == Running ]] || die 'VM の状態が不明です。確認してから --force を使ってください。'
	active=$(limactl shell "$name" bash -lc '
set -euo pipefail
if ! command -v multica >/dev/null 2>&1; then echo 0; exit 0; fi
if status=$(multica daemon status --output json); then :; else
 jq -e '\''.status=="stopped" or .status=="not_running"'\'' >/dev/null <<<"$status" || exit 1
fi
jq -er '\''if type!="object" then error("invalid status")
elif .status=="stopped" or .status=="not_running" then 0
elif .status=="running" then
 [.active_task_count,.running_task_count,.resource_wait_task_count] | map(select(.!=null)) |
 select(length>0 and all(.[]; type=="number" and .>=0 and floor==.)) | max
else error("unknown status") end'\'' <<<"$status"
') || die '実行中のタスク数が不明なため、止めません。確認してから --force を使ってください。'
	[[ $active == 0 ]] || die '実行中のタスクがあるため、止めません。必要なときだけ --force を使ってください。'
}

created=no
cleanup() {
	local result=$?
	trap - EXIT
	if [[ $result != 0 && $created == yes ]]; then
		printf 'lima: 作った VM %s を削除します。\n' "$name" >&2
		limactl delete --force "$name" || printf 'lima: VM の削除に失敗しました: %s\n' "$name" >&2
	fi
	exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
case $action in
create)
	[[ $exists == no ]] || die '同じ名前の VM があります。作り直すときは先に delete してください。'
	for file in provision.sh start-daemon verify.sh; do
		[[ -r $script_dir/guest/$file ]] || die "ゲストのファイルを読めません: $file"
	done
	expression=".mounts = [] | .ssh.forwardAgent = false | .ssh.forwardX11 = false | .ssh.loadDotSSHPubKeys = false | .containerd.system = false | .containerd.user = false | .cpus = $cpus | .memory = \"${memory}GiB\" | .disk = \"${disk}GiB\""
	limactl create --tty=false --name "$name" --set "$expression" template://ubuntu-24.04
	created=yes
	read_instance
	[[ $state == Stopped ]] || die '作成直後の VM が停止していません。'
	require_isolated
	guest_user=$(json_field config.user.name string) || die 'ゲストの使う人の名前を読めません。'
	[[ $guest_user =~ ^[a-z_][a-z0-9_-]*$ && $guest_user != root ]] || die 'ゲストの使う人の名前が不正です。'
	limactl start --tty=false "$name"
	guest_temporary=$(limactl shell "$name" mktemp -d /tmp/multica-squad-vm.XXXXXX)
	[[ $guest_temporary =~ ^/tmp/multica-squad-vm\.[A-Za-z0-9]+$ ]] || die 'ゲストの一時の置き場が不正です。'
	limactl copy "$script_dir/guest/provision.sh" "$script_dir/guest/start-daemon" "$script_dir/guest/verify.sh" "$name:$guest_temporary/"
	limactl shell "$name" sudo bash "$guest_temporary/provision.sh" lima "$guest_user"
	limactl shell "$name" rm -rf -- "$guest_temporary"
	verify_guest
	created=no
	printf 'VM を作りました。中に入る: limactl shell %s\n中で manual.md の「受け取る人の準備」とセットアップの手順を流してください。\n' "$name" ;;
*)
	[[ $exists == yes ]] || die '指定した VM がありません。'
	read_instance
	case $action in
	start)
		require_isolated
		[[ $state == Running || $state == Stopped ]] || die 'VM の状態が不明です。'
		if [[ $state == Stopped ]]; then limactl start --tty=false "$name"; fi ;;
	verify)
		require_isolated
		[[ $state == Running ]] || die 'verify の前に VM を起動してください。'
		verify_guest ;;
	stop|delete)
		if [[ $action == delete && $yes == no ]]; then
			printf 'VM %s を消します。中のログインと作業コピーもなくなります。消しますか [y/N]: ' "$name" >&2
			answer=
			read -r answer || :
			[[ $answer == y || $answer == Y ]] || die '削除を取りやめました。'
		fi
		require_idle
		if [[ $action == stop && $state == Stopped ]]; then exit 0; fi
		# Lima の通常の delete は停止中の VM だけを受け付ける。
		if [[ $action == delete && $state == Running && $force == no ]]; then limactl stop "$name"; fi
		arguments=("$action")
		[[ $force == no ]] || arguments+=(--force)
		limactl "${arguments[@]}" "$name" ;;
	esac ;;
esac
