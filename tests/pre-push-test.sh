#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/pre-push.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
mkdir -p "$test_dir/repo" "$test_dir/temp"
# 実際の履歴で fast-forward と巻き戻しを確かめる。remote への push はしない。
git init -q "$test_dir/repo"
cd "$test_dir/repo"
export GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
export TMPDIR="$test_dir/temp"
export GUARD_TEST_COMMON="$test_dir/repo/.git"
export SQUAD_KIT_ALLOWED_REPOS="$test_dir/project-repos"
printf '%s\n' example/template >"$SQUAD_KIT_ALLOWED_REPOS"
guard="$root/common/guard/pre-push"
url=https://github.com/example/template.git
zero=0000000000000000000000000000000000000000
tree=$(git mktree </dev/null)
parent=$(printf 'parent\n' | git commit-tree "$tree")
child=$(printf 'child\n' | git commit-tree "$tree" -p "$parent")
sibling=$(printf 'sibling\n' | git commit-tree "$tree" -p "$parent")
git tag -a fixture-tag -m fixture "$parent"
tag=$(git rev-parse refs/tags/fixture-tag)

allow() {
	bash "$guard" origin "${1:-$url}" >"$test_dir/out" 2>"$test_dir/err"
	[[ ! -s $test_dir/out && ! -s $test_dir/err ]]
}
deny() {
	if bash "$guard" origin "${1:-$url}" >"$test_dir/out" 2>"$test_dir/err"; then exit 1; fi
	grep -q 'git push の関所:' "$test_dir/err"
	[[ ! -s $test_dir/out ]]
}
update() {
	printf 'refs/heads/topic %s refs/heads/topic %s\n' "$1" "$2"
}
for allowed_url in https://github.com/example/template.git https://github.com/example/template \
	git@github.com:example/template.git git@github.com:example/template \
	ssh://git@github.com/example/template.git ssh://git@github.com/example/template; do
	allow "$allowed_url" </dev/null
done
echo 'PASS push: GitHub の HTTPS と SSH の許可先'
for blocked_url in https://github.com/example/other.git git@github.com:other/repo.git invalid \
	https://outside.example/github.com/example/template.git \
	git@outside.example:github.com/example/template.git \
	ssh://git@outside.example/github.com/example/template.git \
	https://notgithub.com/example/template.git \
	git@notgithub.com:example/template.git \
	https://github.com.evil.example/example/template.git \
	ssh://git@github.com.evil.example/example/template.git \
	https://github.com@outside.example/example/template.git \
	https://outside.example@github.com/example/template.git \
	https://github.com:443/example/template.git \
	http://github.com/example/template.git \
	/checkout/github.com/example/template.git \
	./github.com/example/template.git file:///github.com/example/template.git \
	https://github.com/example/template.git/ https://github.com/example/template.git?query \
	"https://github.com/example/template.git#fragment"; do
	deny "$blocked_url" </dev/null
done
echo 'PASS push: 対象外・外部ホスト・類似ホスト・ローカルパス・未許可形式を拒否'
SQUAD_KIT_ALLOWED_REPOS="$test_dir/missing" deny </dev/null
echo 'PASS push: 許可ファイル欠落は拒否'

update "$parent" "$zero" | allow
update "$child" "$parent" | allow
update "$child" "$child" | allow
update "$zero" "$child" | allow
echo 'PASS push: ブランチの新規作成・fast-forward・同一 OID・削除を許す'
update "$parent" "$child" | deny
update "$sibling" "$child" | deny
update "$child" 1111111111111111111111111111111111111111 | deny
echo 'PASS push: 巻き戻し・分岐した履歴・旧オブジェクト不足を拒否'
for new_tag in "$parent" "$tag"; do
	printf 'refs/tags/new %s refs/tags/new %s\n' "$new_tag" "$zero" | allow
	printf 'refs/tags/same %s refs/tags/same %s\n' "$new_tag" "$new_tag" | allow
	printf 'refs/tags/moved %s refs/tags/moved %s\n' "$child" "$new_tag" | deny
done
echo 'PASS push: 軽量・注釈付きタグの作成と同一 OID を許し、既存タグの付け替えを拒否'
for invalid in 'refs/heads/topic old refs/heads/topic new' \
	"refs/heads/topic $child refs/heads/topic $parent extra" \
	"refs/heads/topic $child"; do
	printf '%s\n' "$invalid" | deny
done
# 最終行の改行がなくても検査を省略しない。
printf 'refs/heads/topic %s refs/heads/topic %s' "$parent" "$child" | deny
echo 'PASS push: 不明な更新行と改行なしの巻き戻しも拒否'

cat >"$GUARD_TEST_COMMON/hooks/pre-push" <<'HOOK'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$GUARD_TEST_COMMON/args"
cat >"$GUARD_TEST_COMMON/input"
exit 17
HOOK
chmod +x "$GUARD_TEST_COMMON/hooks/pre-push"
{
	update "$child" "$parent"
	printf 'refs/tags/new %s refs/tags/new %s' "$tag" "$zero"
} >"$test_dir/updates"
set +e
bash "$guard" origin "$url" <"$test_dir/updates"
status=$?
set -e
[[ $status == 17 ]]
[[ $(cat "$GUARD_TEST_COMMON/args") == $'origin\nhttps://github.com/example/template.git' ]]
cmp "$test_dir/updates" "$GUARD_TEST_COMMON/input"
echo 'PASS push: 後続 hook に引数と複数行の標準入力をそのまま渡し、終了コードも返す'
# 正常な行に続く巻き戻しも拒否し、後続 hook は一度も呼ばない。
rm "$GUARD_TEST_COMMON/input" "$GUARD_TEST_COMMON/args"
{ update "$child" "$parent"; update "$parent" "$child"; } | deny
[[ ! -e $GUARD_TEST_COMMON/input && ! -e $GUARD_TEST_COMMON/args ]]
[[ -z $(find "$test_dir/temp" -type f -print) ]]
echo 'PASS push: 複数行の一部が不正なら後続 hook を呼ばず、一時入力を片付ける'
