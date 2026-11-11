#!/usr/bin/env bash
# tests/ci-install-test.sh が使う、署名つきのパッケージ情報を作り直す。ふだんは実行しない。
# 鍵・署名・Packages の中身を変えたいときだけ実行し、できたファイルをコミットする。
#
# 作るもの（この script と同じディレクトリへ）:
#   keyring.gpg          ランナーの Ubuntu アーカイブ公開鍵の代わり（trusted の公開鍵だけ）
#   Packages             テストのパッケージ一覧。各 .deb の中身は「deb-<名前>」の 1 行
#   Packages.tampered    zsh の .deb を「evil」に差し替えたもの（SHA-256 もそれに合わせて書き換え）
#   InRelease            trusted が署名。Packages の SHA-256 を記す
#   InRelease.expired    trusted が署名。Valid-Until が過ぎている
#   InRelease.attacker   別の鍵（keyring.gpg にない）が署名。Packages.tampered の SHA-256 を記す
#
# gpg-agent の socket パスには長さの上限があるので、鍵の置き場所は短い TMPDIR の下に作る。
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
packages=(bash zsh git jq gh zip unzip python3 tzdata libdigest-sha-perl procps gpgv)
prefix=mirror.test_ubuntu_dists_noble
work=$(mktemp -d "${TMPDIR:-/tmp}/ci-fixture.XXXXXX")
trap 'gpgconf --homedir "$work/g" --kill all >/dev/null 2>&1 || true; rm -rf -- "$work"' EXIT
mkdir -m 700 "$work/g"
export GNUPGHOME=$work/g

sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | awk '{print $1}'; }

for key in trusted attacker; do
	gpg --batch --quiet --pinentry-mode loopback --passphrase '' --quick-generate-key "$key@ci.invalid" default default never
done
gpg --batch --export trusted@ci.invalid >"$here/keyring.gpg"

for p in "${packages[@]}"; do
	printf 'Package: %s\nVersion: 1.0\nArchitecture: amd64\nFilename: pool/main/x/%s/%s_1.0_amd64.deb\nSHA256: %s\n\n' \
		"$p" "$p" "$p" "$(printf 'deb-%s\n' "$p" | sha256_of)"
done >"$here/Packages"
sed "s/$(printf 'deb-zsh\n' | sha256_of)/$(printf 'evil\n' | sha256_of)/" "$here/Packages" >"$here/Packages.tampered"

# release <Packages> <Valid-Until か空> <鍵> <出力>
release() {
	{
		printf 'Origin: Test\nSuite: noble\n'
		[[ -z $2 ]] || printf 'Valid-Until: %s\n' "$2"
		printf 'SHA256:\n %s %s main/binary-amd64/Packages\n' "$(sha256_of <"$1")" "$(wc -c <"$1" | tr -d ' ')"
	} >"$work/Release"
	gpg --batch --quiet --yes --pinentry-mode loopback --passphrase '' -u "$3@ci.invalid" --clearsign -o "$4" "$work/Release"
}
release "$here/Packages" '' trusted "$here/InRelease"
release "$here/Packages" 'Thu, 01 Jan 2026 00:00:00 UTC' trusted "$here/InRelease.expired"
release "$here/Packages.tampered" '' attacker "$here/InRelease.attacker"
echo "prefix=$prefix"
