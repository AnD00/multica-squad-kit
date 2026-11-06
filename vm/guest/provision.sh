#!/usr/bin/env bash
# root で実行: bash provision.sh lima|wsl USER
# テストでは SQUAD_VM_ROOT で /etc・/usr・/run の根を差し替える。
set -euo pipefail
die() { printf 'provision: %s\n' "$*" >&2; exit 1; }
[[ $# == 2 ]] || die 'lima または wsl と、使う人の名前を渡してください。'
platform=$1 guest_user=$2
[[ $platform == lima || $platform == wsl ]] || die '対象は lima または wsl です。'
[[ $guest_user =~ ^[a-z_][a-z0-9_-]*$ && $guest_user != root ]] || die '使う人の名前が不正です。'
[[ $(id -u) == 0 ]] || die 'VM の中の root で実行してください。'
guest_root=${SQUAD_VM_ROOT:-}
guest_root=${guest_root%/}
[[ -z $guest_root || ( $guest_root == /* && $guest_root != *$'\n'* ) ]] || die '根は改行のない絶対パスにしてください。'
source_dir=$(cd "$(dirname "$0")" && pwd)
[[ -r $guest_root/etc/os-release ]] || die 'Ubuntu の版を読めません。'
. "$guest_root/etc/os-release"
[[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 24.04 ]] || die 'Ubuntu 24.04 で実行してください。'

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y bash zsh git jq gh zip unzip python3 tzdata libdigest-sha-perl coreutils findutils procps ca-certificates curl uidmap dbus-user-session slirp4netns iptables apparmor
if ! passwd_entry=$(getent passwd "$guest_user"); then
	[[ $platform == wsl ]] || die 'Lima の使う人が見つかりません。'
	useradd --create-home --shell /bin/bash "$guest_user"
	passwd_entry=$(getent passwd "$guest_user") || die '作った使う人を読めません。'
fi
IFS=: read -r account _ guest_uid _ _ guest_home _ <<<"$passwd_entry"
[[ $account == "$guest_user" && $guest_uid =~ ^[0-9]+$ && $guest_uid != 0 && $guest_home == /* && $guest_home != *$'\n'* ]] || die '使う人の UID とホームを確認してください。'
groups=$(id -nG "$guest_user")
[[ " $groups " != *' docker '* ]] || die '使う人を docker の群から外してください。rootless だけを使います。'
if [[ $platform == wsl && ( " $groups " == *' sudo '* || " $groups " == *' admin '* || " $groups " == *' root '* ) ]]; then
	die 'WSL の使う人に root の権限を持たせないでください。'
fi

# useradd より前に作られた Lima の利用者にも、重ならない従属 ID を用意する。
for kind in subuid subgid; do
	file=$guest_root/etc/$kind
	touch "$file"
	if ! awk -F: -v user="$guest_user" -v uid="$guest_uid" '($1==user || $1==uid) && $3>=65536 {found=1} END {exit !found}' "$file"; then
		first=$(awk -F: 'BEGIN {first=100000} $2+$3>first {first=$2+$3} END {printf "%.0f", first}' "$file")
		last=$((first + 65535))
		if [[ $kind == subuid ]]; then option=--add-subuids; else option=--add-subgids; fi
		usermod "$option" "$first-$last" "$guest_user"
	fi
done

install -d -m 0755 "$guest_root/etc/apt/keyrings" "$guest_root/etc/apt/sources.list.d"
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "$guest_root/etc/apt/keyrings/docker.asc"
chmod 0644 "$guest_root/etc/apt/keyrings/docker.asc"
architecture=$(dpkg --print-architecture)
cat >"$guest_root/etc/apt/sources.list.d/docker.sources" <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Architectures: $architecture
Signed-By: /etc/apt/keyrings/docker.asc
EOF
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-ce-rootless-extras docker-buildx-plugin docker-compose-plugin
systemctl disable --now docker.service docker.socket

# ログイン前でも、Docker の installer がユーザーの systemd を見付けられるようにする。
loginctl enable-linger "$guest_user"
systemctl start "user@$guest_uid.service"
as_user() {
	runuser -u "$guest_user" -- env -i HOME="$guest_home" USER="$guest_user" LOGNAME="$guest_user" SHELL=/bin/bash PATH="$PATH" XDG_RUNTIME_DIR="$guest_root/run/user/$guest_uid" DBUS_SESSION_BUS_ADDRESS="unix:path=$guest_root/run/user/$guest_uid/bus" "$@"
}
as_user dockerd-rootless-setuptool.sh install
as_user systemctl --user enable --now docker.service
as_user docker context use rootless

destination=$guest_root/usr/local/lib/multica-squad-vm
install -d -m 0755 "$destination" "$guest_root/etc/systemd/system"
for file in provision.sh start-daemon verify.sh; do
	if ! cmp -s "$source_dir/$file" "$destination/$file"; then
		install -m 0755 "$source_dir/$file" "$destination/$file"
	fi
	chmod 0755 "$destination/$file"
done
cat >"$guest_root/etc/systemd/system/multica-squad-daemon.service" <<EOF
[Unit]
Description=Multica daemon for multica-squad-kit
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=$guest_user
ExecStart=/usr/local/lib/multica-squad-vm/start-daemon
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
if [[ $platform == wsl ]]; then
	cat >"$guest_root/etc/wsl.conf" <<EOF
[boot]
systemd=true

[automount]
enabled=false
mountFsTab=false

[interop]
enabled=false
appendWindowsPath=false

[user]
default=$guest_user
EOF
fi
systemctl daemon-reload
systemctl enable multica-squad-daemon.service
printf 'PASS provision: %s のゲストを準備しました（%s）。\n' "$platform" "$guest_user"
