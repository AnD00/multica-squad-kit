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
#   InRelease.focal      trusted が署名。別のリリース（Suite・Codename とも focal）の情報
#   InRelease.codename   trusted が署名。Suite は noble だが Codename が focal
#   InRelease.backports  trusted が署名。Codename は noble だが Suite が noble-backports（許可しない）
#   InRelease.updates    trusted が署名。Codename noble、Suite noble-updates（許可する）
#   Packages.old         zsh だけバージョンが 0.5（ランナーの候補 1.0 より古い）
#   InRelease.old        trusted が署名。Packages.old の SHA-256 を記す（Valid-Until なし）
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
# 古いバージョン: zsh だけ 0.5 にする（Filename も合わせる。.deb の中身は同じ「deb-zsh」のまま）
sed -e '/^Package: zsh$/,/^$/{s/^Version: 1.0$/Version: 0.5/;s/zsh_1.0_amd64/zsh_0.5_amd64/;}' "$here/Packages" >"$here/Packages.old"

# release <Packages> <Valid-Until か空> <鍵> <出力> [Codename（既定 noble）] [Suite（既定は Codename）]
release() {
	local codename=${5:-noble} suite=${6:-${5:-noble}}
	{
		printf 'Origin: Test\nSuite: %s\nCodename: %s\n' "$suite" "$codename"
		[[ -z $2 ]] || printf 'Valid-Until: %s\n' "$2"
		printf 'SHA256:\n %s %s main/binary-amd64/Packages\n' "$(sha256_of <"$1")" "$(wc -c <"$1" | tr -d ' ')"
	} >"$work/Release"
	gpg --batch --quiet --yes --pinentry-mode loopback --passphrase '' -u "$3@ci.invalid" --clearsign -o "$4" "$work/Release"
}
release "$here/Packages" '' trusted "$here/InRelease"
release "$here/Packages" 'Thu, 01 Jan 2026 00:00:00 UTC' trusted "$here/InRelease.expired"
release "$here/Packages.tampered" '' attacker "$here/InRelease.attacker"
release "$here/Packages" '' trusted "$here/InRelease.focal" focal
release "$here/Packages" '' trusted "$here/InRelease.codename" focal noble
release "$here/Packages" '' trusted "$here/InRelease.backports" noble noble-backports
release "$here/Packages" '' trusted "$here/InRelease.updates" noble noble-updates
release "$here/Packages.old" '' trusted "$here/InRelease.old"
echo "prefix=$prefix"
