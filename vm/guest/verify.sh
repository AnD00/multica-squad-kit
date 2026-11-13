#!/usr/bin/env bash
# 使う人として実行: bash verify.sh lima|wsl
# テストでは SQUAD_VM_ROOT で /proc・/mnt などの読む先を差し替える。
set -euo pipefail
die() { printf 'verify: %s\n' "$*" >&2; exit 1; }
[[ $# == 1 && ( $1 == lima || $1 == wsl ) ]] || die '対象の lima または wsl を渡してください。'
platform=$1
[[ $(id -u) != 0 ]] || die 'VM の中の使う人として実行してください。'
guest_root=${SQUAD_VM_ROOT:-}
guest_root=${guest_root%/}
[[ -z $guest_root || ( $guest_root == /* && $guest_root != *$'\n'* ) ]] || die '根は改行のない絶対パスにしてください。'
failed=0
passed=no
check() {
	local label=$1
	shift
	if "$@"; then passed=yes; printf 'PASS verify: %s\n' "$label"; else passed=no; printf 'FAIL verify: %s\n' "$label" >&2; failed=1; fi
}
absent() { [[ ! -e $1 && ! -L $1 ]]; }
# WSL は初回起動で /mnt/c を作る。automount を切ったあとも、空のディレクトリは残る。
absent_or_empty_directory() {
	[[ ! -e $1 && ! -L $1 ]] && return 0
	[[ -d $1 && ! -L $1 ]] || return 1
	[[ -z $(ls -A "$1") ]]
}
no_host_mounts() {
	local mounts
	mounts=$(cat "$guest_root/proc/self/mountinfo") || return 1
	awk -v platform="$platform" '
	{for (i=1;i+2<=NF;i++) if ($i=="-") {
	 seen=1
	 fs=$(i+1); source=$(i+2)
	 if (platform=="lima" && (fs=="virtiofs" || fs=="9p" || fs=="sshfs" || fs=="fuse.sshfs")) bad=1
	 if (platform=="wsl" && ($5 ~ /^\/mnt\/[A-Za-z]$/ || fs=="drvfs" || (fs=="9p" && (source ~ /^[A-Za-z]:/ || tolower($0) ~ /drvfs/)))) bad=1
	 break
	}} END {exit (bad || !seen)}' <<<"$mounts" || return 1
	if [[ $platform == lima ]]; then absent "$guest_root/Users"; else absent_or_empty_directory "$guest_root/mnt/c"; fi
}
no_agent_socket() { [[ -z ${SSH_AUTH_SOCK:-} ]]; }
no_windows_exec() {
	absent "$guest_root/proc/sys/fs/binfmt_misc/WSLInterop" || return 1
	! cmd.exe /c exit 0 >/dev/null 2>&1
}
no_sudo() { ! sudo -n true >/dev/null 2>&1; }
no_desktop() {
	local path
	for path in /mnt/wsl/docker-desktop /mnt/wsl/docker-desktop-bind-mounts /Docker/host /usr/bin/docker.exe; do
		absent "$guest_root$path" || return 1
	done
}
isolation() {
	check 'ホストのファイルの共有がない' no_host_mounts
	check 'ホストの SSH の鍵の転送がない' no_agent_socket
	if [[ $platform == wsl ]]; then
		check 'Windows の実行ファイルを呼べない' no_windows_exec
		check 'sudo で root になれない' no_sudo
		check 'Docker Desktop の統合がない' no_desktop
	fi
}
rootless_docker() {
	local security
	security=$(docker info --format '{{json .SecurityOptions}}') || return 1
	jq -e 'type=="array" and index("name=rootless")!=null' >/dev/null <<<"$security"
}
has_linger() { [[ $(loginctl show-user "$(id -un)" -p Linger --value) == yes ]]; }
daemon_environment() {
	local login_path status pid observed
	login_path=$(bash -lc 'printf "%s\n" "$PATH"') || return 1
	status=$(PATH="$HOME/.multica-agent/bin:$login_path" multica daemon status --output json) || return 1
	pid=$(jq -er 'select(.status=="running") | .pid | select(type=="number" and .>0 and floor==.)' <<<"$status") || return 1
	observed=$(ps eww -o command= -p "$pid") || return 1
	[[ " $observed " == *" CODEX_HOME=$HOME/.multica-agent/codex "* && " $observed " == *" PATH=$HOME/.multica-agent/bin:"* ]]
}
# record-server を 1 回流し、記録をデーモンの接続先と照合する。
# 最初の記録の前に VM を止めても、接続先が残るようにするため。
server_recorded() {
	local login_path status expected
	"$BASH" "$guest_root/usr/local/lib/multica-squad-vm/record-server" || return 1
	login_path=$(bash -lc 'printf "%s\n" "$PATH"') || return 1
	status=$(PATH="$HOME/.multica-agent/bin:$login_path" multica daemon status --output json) || return 1
	expected=$(jq -er 'select(.status=="running") | .server_url | select(type=="string")' <<<"$status") || return 1
	[[ -f $HOME/.config/multica-squad-vm/server-url && $(cat "$HOME/.config/multica-squad-vm/server-url") == "${expected%/}" ]]
}

isolation
if rootless_docker; then
	printf 'PASS verify: Docker は rootless\n'
	check 'Docker の hello-world が動く' docker run --rm hello-world
else
	printf 'FAIL verify: Docker が rootless で動いていません。hello-world は飛ばします。\n' >&2
	failed=1
fi
# Docker を使ったあとにも閉じ込めが保たれていることを確認する。
isolation
check 'デーモンの unit が有効' systemctl is-enabled --quiet multica-squad-daemon.service
check '接続先を記録する timer が有効' systemctl is-enabled --quiet multica-squad-record-server.timer
check '使う人の linger が有効' has_linger
if [[ -f $HOME/.multica-agent/bin/gh ]]; then
	check '起動中のデーモンの環境がセットアップと同じ' daemon_environment
	# 環境が違うデーモンは記録の元にならないので、環境が合ったときだけ確認する。
	if [[ $passed == yes ]]; then
		check '記録した接続先が起動中のデーモンと同じ' server_recorded
	fi
else
	printf 'SKIP verify: セットアップ前のためデーモンの確認を飛ばします。\n'
fi
exit "$failed"
