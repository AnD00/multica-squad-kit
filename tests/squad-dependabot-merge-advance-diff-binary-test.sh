#!/usr/bin/env bash
# ZIP のルートで bash tests/squad-dependabot-merge-advance-diff-binary-test.sh。
# gh と multica を差し替え、実際の PR・タスクには書き込まない。advance のバイナリを含む差分の扱いを確認する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
if [[ ${SQUAD_CLI_TEST_COMPARING:-} != 1 ]]; then
	source "$root/tests/cli-mode-test-lib.sh"
	cli_test_compare_modes "$0" "$@"
	exit $?
fi

source "$root/tests/dependabot-merge-test-lib.sh"
source "$root/tests/dependabot-merge-advance-test-lib.sh"

# バイナリの内容は差分に出ず、blob の ID も除くので、ハッシュが同じでも内容が同じとは限らない。
rebase_fixture
printf 'diff --git a/api/go.mod b/api/go.mod\nindex 1111111..3333333 100644\nBinary files a/api/go.mod and b/api/go.mod differ\n' >"$test_dir/pr.diff"
run_advance changed
no_writes
rebase_fixture
printf 'GIT binary patch\n' >>"$test_dir/pr.diff"
run_advance changed
no_writes
echo 'PASS advance: rebase 後の差分がバイナリを含めば、ハッシュに頼らず changed、書き込みなし'

# 短いバイナリ差分の後ろに大きなテキスト差分が続いても、検出を取りこぼさない。
large_text_diff() {
	printf 'diff --git a/logo.png b/logo.png\nindex 1111111..2222222 100644\nBinary files a/logo.png and b/logo.png differ\n'
	printf 'diff --git a/api/go.mod b/api/go.mod\nindex 1111111..2222222 100644\n--- a/api/go.mod\n+++ b/api/go.mod\n@@ -1,3 +1,20000 @@\n'
	awk 'BEGIN { for (i = 0; i < 20000; i++) printf "+example v1.2.%d // dependencies dependencies dependencies\n", i }'
}
rebase_fixture
large_text_diff >"$test_dir/pr.diff"
run_advance changed
no_writes
advance_fixture
edit_pr '.mergeStateStatus = "BEHIND"'
large_text_diff >"$test_dir/pr.diff"
run_advance waiting
jq -e '.[0].body | contains("diff:") | not' "$test_dir/comments.json" >/dev/null
echo 'PASS advance: 大きなテキスト差分の前のバイナリ差分も検出し、changed・ハッシュなしの依頼にする'
