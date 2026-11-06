#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/setup-test.XXXXXX")
trap 'test_exit=$?; if [[ $test_exit != 0 ]]; then cat "$test_dir/out" "$test_dir/err" >&2; fi; rm -rf -- "$test_dir"' EXIT
mkdir -p "$test_dir/package/lib" "$test_dir/bin"
cp "$root/VERSION" "$test_dir/package/VERSION"
cp "$root/setup.sh" "$test_dir/package/setup.sh"
cp "$root/lib/"*.sh "$test_dir/package/lib/"
cp -R "$root/common" "$root/skeleton" "$test_dir/package/"
# 質問の試験ではホストを触らない。ホストの実装は host-test.sh で検証する。
printf 'migrate_legacy_host() { :; }\nmigration_report() { :; }\n' >"$test_dir/package/lib/migrate.sh"
printf 'prepare_host() { :; }\n' >"$test_dir/package/lib/host.sh"
printf 'prepare_workspace() { :; }\n' >"$test_dir/package/lib/workspace.sh"
printf 'prepare_project() { echo TEST-project-prepared; }\n' >"$test_dir/package/lib/project.sh"
printf payload >"$test_dir/package/file with spaces"
cat >"$test_dir/bin/uname" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${TEST_OS:-Darwin}"
STUB
cat >"$test_dir/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo 'unexpected gh call' >&2
exit 89
STUB
cat >"$test_dir/bin/multica" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s|%s|%s\n' "${MULTICA_SERVER_URL:-}" "${MULTICA_WORKSPACE_ID:-}" "$*" >>"$TEST_CALLS"
case "$*" in
'config show') printf 'server_url: %s\n' "${TEST_SERVER:-https://example.test}" ;;
'auth status') [[ ${TEST_LOGIN:-yes} == yes && ${MULTICA_SERVER_URL:-} != ${TEST_UNREACHABLE_URL:-__none__} ]] ;;
'user profile get --output json') if [[ -n ${TEST_PROFILE_FILE:-} ]]; then cat "$TEST_PROFILE_FILE"; else echo '{"id":"member-a","name":"Member A","email":"Owner@example.test"}'; fi ;;
'squad list --output json') if [[ -n ${TEST_SQUADS_FILE:-} ]]; then cat "$TEST_SQUADS_FILE"; else echo '[]'; fi ;;
'squad get '* ) echo "{\"id\":\"squad-a\",\"creator_id\":\"${TEST_SQUAD_OWNER:-member-a}\"}" ;;
'agent list --output json') [[ ${TEST_FAIL:-} != agents ]] || exit 76; if [[ -n ${TEST_AGENTS_FILE:-} ]]; then cat "$TEST_AGENTS_FILE"; else echo '[]'; fi ;;
'skill list --output json') if [[ -n ${TEST_SKILLS_FILE:-} ]]; then cat "$TEST_SKILLS_FILE"; else echo '[]'; fi ;;
'autopilot list --output json') if [[ -n ${TEST_AUTOPILOTS_FILE:-} ]]; then cat "$TEST_AUTOPILOTS_FILE"; else echo '{"autopilots":[]}'; fi ;;
'workspace list --output json') if [[ -n ${TEST_WORKSPACES_FILE:-} ]]; then cat "$TEST_WORKSPACES_FILE"; else echo '[{"id":"ws-a","name":"Workspace A"},{"id":"ws-b","name":"Workspace B"}]'; fi ;;
'project list --output json')
 [[ ${TEST_FAIL:-} != project ]] || exit 71
 if [[ ${TEST_MALFORMED:-} == yes ]]; then echo '{}'; elif [[ -n ${TEST_PROJECTS_FILE:-} ]]; then cat "$TEST_PROJECTS_FILE"; else echo '[{"id":"project-a","title":"Existing project"}]'; fi ;;
'project resource list '*)
 [[ ${TEST_FAIL:-} != resources ]] || exit 75
 if [[ -n ${TEST_RESOURCES_DIR:-} && -f $TEST_RESOURCES_DIR/$4.json ]]; then cat "$TEST_RESOURCES_DIR/$4.json"; else echo '[]'; fi ;;
'repo list --output json')
 [[ ${TEST_FAIL:-} != repo ]] || exit 72
 if [[ ${TEST_NO_REPO:-} == yes ]]; then echo '[]'; elif [[ -n ${TEST_REPOS_FILE:-} ]]; then cat "$TEST_REPOS_FILE"; else echo '[{"url":"https://github.com/example/one.git"},{"url":"git@github.com:example/two.git"}]'; fi ;;
'workspace member list --output json')
 [[ ${TEST_FAIL:-} != members ]] || exit 73
 echo '[{"id":"row-a","user_id":"member-a","name":"Member A"},{"id":"row-b","user_id":"member-b","name":"Member B"}]' ;;
*) printf 'unexpected write or CLI call: %s\n' "$*" >&2; exit 90 ;;
esac
STUB
chmod +x "$test_dir/bin/"*
cat >"$test_dir/bin/mv" <<'STUB'
#!/usr/bin/env bash
[[ ${TEST_SAVE_FAIL:-no} != yes ]] || exit 74
exec /bin/mv "$@"
STUB
chmod +x "$test_dir/bin/mv"
export PATH="$test_dir/bin:$PATH" TEST_CALLS="$test_dir/calls"
export TEMPLATE_STATE_ROOT="$test_dir/state"
unset MULTICA_SERVER_URL MULTICA_WORKSPACE_ID
manifest() {
 (cd "$test_dir/package"; while IFS= read -r file; do shasum -a 256 "$file"; done < <(find . -type f ! -name MANIFEST | LC_ALL=C sort)) >"$test_dir/manifest"
 cp "$test_dir/manifest" "$test_dir/package/MANIFEST"
}
run() { { printf "\n"; cat "$test_dir/input"; } | /bin/bash "$test_dir/package/setup.sh" >"$test_dir/out" 2>"$test_dir/err"; }
deny() { if run; then cat "$test_dir/out" "$test_dir/err"; exit 1; fi; [[ -s $test_dir/err ]]; }
no_state() { [[ ! -e $test_dir/state ]]; }
base_input() { printf '1\n1\ndemo\n2\nmembera\n1 2\n3 1\n%s\n' "$1" >"$test_dir/input"; }
