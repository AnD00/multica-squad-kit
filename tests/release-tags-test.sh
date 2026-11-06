#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/release-tags.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
python3 - "$root/CONTRIBUTING.md" "$test_dir/release.sh" <<'PY'
import sys
from pathlib import Path

document = Path(sys.argv[1]).read_text()
section = document.split('## タグを発行する\n')[1]
script = section.split('```bash\n')[1].split('```')[0]
Path(sys.argv[2]).write_text(script)
PY

git init -q -b main "$test_dir/origin"
cp "$root/VERSION" "$root/CHANGELOG.md" "$test_dir/origin/"
git -C "$test_dir/origin" add VERSION CHANGELOG.md
git -C "$test_dir/origin" -c user.name='Test User' -c user.email=test@example.test commit -qm 'Release content'
upstream_head=$(git -C "$test_dir/origin" rev-parse HEAD)
release_tag=$(cat "$root/VERSION")
# タグの作成までは実行し、push は記録だけにする。
git() {
	if [[ ${1:-} == push ]]; then
		printf '%s\n' "$*" >"$RELEASE_TEST_PUSH_FILE"
	else
		command git "$@"
	fi
}
export -f git
export GIT_AUTHOR_NAME='Test User' GIT_AUTHOR_EMAIL=test@example.test
export GIT_COMMITTER_NAME='Test User' GIT_COMMITTER_EMAIL=test@example.test
for scenario in current ahead; do
	git clone -q "$test_dir/origin" "$test_dir/$scenario"
	if [[ $scenario == ahead ]]; then
		git -C "$test_dir/$scenario" commit -qm 'Unpublished content' --allow-empty
	fi
	[[ -z $(git -C "$test_dir/$scenario" status --porcelain) ]]
	export RELEASE_TEST_PUSH_FILE="$test_dir/$scenario.push"
	result=0
	(cd "$test_dir/$scenario" && /bin/bash "$test_dir/release.sh") >"$test_dir/$scenario.out" 2>"$test_dir/$scenario.err" || result=$?
	if [[ $scenario == current ]]; then
		[[ $result == 0 ]]
		[[ $(git -C "$test_dir/$scenario" cat-file -t "$release_tag") == tag ]]
		[[ $(git -C "$test_dir/$scenario" rev-parse "$release_tag^{}") == "$upstream_head" ]]
		grep -qxF "push origin refs/tags/$release_tag" "$RELEASE_TEST_PUSH_FILE"
	else
		[[ $result != 0 ]]
		[[ -z $(git -C "$test_dir/$scenario" tag) && ! -e $RELEASE_TEST_PUSH_FILE ]]
	fi
done
echo 'PASS release: 文書の手順は origin/main に注釈付きタグを作り、先行する main ではタグ作成・push 前に止まる'
