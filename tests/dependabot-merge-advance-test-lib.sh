#!/usr/bin/env bash
# advance と escalate のテストが読み込む、待ちの時計と PR の状態を進める補助。単独では実行しない。
# advance の待ちは、実時間を進めず、時計と次の CI / PR の状態だけを進める。
cat >"$test_dir/bin/date" <<'EOF'
#!/usr/bin/env bash
[[ $* == +%s ]] || exit 1
cat "$DEPENDABOT_MERGE_TEST_DIR/now"
EOF
cat >"$test_dir/bin/sleep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
dir=$DEPENDABOT_MERGE_TEST_DIR
echo "$1" >>"$dir/sleeps"
echo "$(($(<"$dir/now") + $1))" >"$dir/now"
for kind in checks pr; do
	if [[ -f $dir/next-$kind.json ]]; then
		if [[ $kind == pr ]]; then target=pr-1; else target=checks; fi
		mv "$dir/next-$kind.json" "$dir/$target.json"
	fi
done
EOF
chmod +x "$test_dir/bin/date" "$test_dir/bin/sleep"

advance_fixture() {
	reset_fixture
	rm -f "$test_dir/changed-head" "$test_dir/merge-fail" "$test_dir/next-checks.json" "$test_dir/next-pr.json" "$test_dir/fail" "$test_dir/tick-on" "$test_dir/comments-page2.json"
	printf '200000\n' >"$test_dir/now"
	printf '[]\n' >"$test_dir/comments.json"
	cat >"$test_dir/pr.diff" <<'EOF'
diff --git a/api/go.mod b/api/go.mod
index 1111111..2222222 100644
--- a/api/go.mod
+++ b/api/go.mod
@@ -1,3 +1,3 @@ require (
 // dependencies
-example v1.2.2
+example v1.2.3
 )
EOF
	: >"$test_dir/sleeps"
	: >"$test_dir/body-files"
	add_pr 1 dependabot/go_modules/api/example "$(metadata patch)"
	reviewed=$(printf '%040d' 1)
	run_deadline=214400
}

run_advance() {
	local expected=$1
	shift
	if bash "$script" example/template project-a advance 1 --reviewed-head "$reviewed" --run-deadline "$run_deadline" "$@" >"$test_dir/output" 2>"$test_dir/error"; then :
	else cat "$test_dir/error" >&2; return 1; fi
	if [[ -s $test_dir/error || $(sed -n '1p' "$test_dir/output") != "$expected" || $(wc -l <"$test_dir/output") -ne 2 ]]; then
		printf '期待した結果: %s\n実際の結果:\n' "$expected" >&2
		cat "$test_dir/output" "$test_dir/error" >&2
		return 1
	fi
}

no_writes() {
	jq -se 'all(.[]; .[0:2] != ["pr","merge"] and .[0:2] != ["pr","comment"])' "$test_dir/calls.jsonl" >/dev/null
}

edit_pr() {
	jq "$1" "$test_dir/pr-1.json" >"$test_dir/edit.json"
	mv "$test_dir/edit.json" "$test_dir/pr-1.json"
}

commit_time() {
	jq --argjson time "$2" '.commit.committer.date = ($time | todateiso8601)' "$test_dir/$1.json" >"$test_dir/edit.json"
	mv "$test_dir/edit.json" "$test_dir/$1.json"
}

# 依頼で実際に保存したハッシュを、新しい head の差分と比較する。
rebase_fixture() {
	advance_fixture
	edit_pr '.mergeStateStatus = "BEHIND"'
	run_advance waiting
	jq -e --arg head "$reviewed" '.[0].body | contains("head: " + $head + " diff: ")
		and test("diff: [a-f0-9]{64} -->")' "$test_dir/comments.json" >/dev/null
	add_pr 2 dependabot/go_modules/api/example "$(metadata patch)"
	head2=$(printf '%040d' 2)
	edit_pr ".headRefOid = \"$head2\" | .mergeStateStatus = \"CLEAN\""
	: >"$test_dir/calls.jsonl"
}
