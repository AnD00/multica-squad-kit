#!/usr/bin/env bash
# setup-version-test.sh が作る questions.sh のコピーにだけ追加する。
# 入力の読み取り・更新確認・保存・記録には介入しない。
_setup_version_cache_allowed() {
 [[ ! -t 0 && ! -t 1 && ! -t 2 &&
    ${ui_color_out:-no} == no && ${ui_color_err:-no} == no &&
    ${ui_live_out:-no} == no && ${ui_live_err:-no} == no &&
    -z ${extension_work:-} && -z ${extension_dir:-} ]] || return 1
 # fixture の既定の読み取り応答以外は、元の処理へ返す。
 [[ ! ${TEST_PROFILE_FILE+x} && ! ${TEST_PROJECTS_FILE+x} &&
    ! ${TEST_REPOS_FILE+x} && ! ${TEST_MEMBERS_FILE+x} &&
    ! ${TEST_SQUADS_FILE+x} && ! ${TEST_ROSTER_FILE+x} &&
    ! ${TEST_AGENTS_FILE+x} && ! ${TEST_SKILLS_FILE+x} &&
    ! ${TEST_AUTOPILOTS_FILE+x} && ! ${TEST_RESOURCES_DIR+x} &&
    ! ${TEST_FAIL+x} && ! ${TEST_OS+x} && ! ${TEST_KERNEL+x} &&
    ! ${TEST_SERVER+x} && ! ${TEST_UNREACHABLE_URL+x} ]]
}
_setup_version_cached() {
 local name=$1 key entry result=0
 shift
 if ! _setup_version_cache_allowed ||
    [[ $name == confirmation_plan && $BASH_SUBSHELL == 0 ]]; then
  "_setup_version_original_$name" "$@"
  return
 fi
 # NUL で区切り、引数の境界も鍵に含める。MANIFEST とスタブ本体も毎回読む。
 key=$({
  printf '%s\0' "$name" "$#" "$@" "${answers-}" "${saved-}" \
   "${question_squads-}" "${question_people-}" "${question_actor_id-}" \
   "${template_roles-}" "${extension_disabled_roles-}" "${extension_current_roles-}" \
   "${role_choices-}" "${project_key-}" "${member_key-}" "${runtimes-}" \
   "${repositories-}" "${LC_ALL-}" "${LANG-}" "$root"
  cat "$root/MANIFEST" "$TEST_SETUP_VERSION_STUB"
 } | shasum -a 256) || return
 key=${key%% *}
 entry=$TEST_SETUP_VERSION_CACHE/$key
 if [[ ! -f $entry.ready ]]; then
  "_setup_version_original_$name" "$@" >"$entry.out" 2>"$entry.err"
  result=$?
  if [[ $result == 0 ]]; then
   : >"$entry.ready"
  fi
 fi
 cat "$entry.out"
 cat "$entry.err" >&2
 return "$result"
}
# 本物の関数を保ち、成功した同じ入力の出力だけを再利用する。
for _setup_version_name in confirmation_plan confirmation_show; do
 _setup_version_definition=$(declare -f "$_setup_version_name")
 _setup_version_definition=${_setup_version_definition#"$_setup_version_name"}
 eval "_setup_version_original_$_setup_version_name$_setup_version_definition"
done
unset _setup_version_name _setup_version_definition
confirmation_plan() { _setup_version_cached confirmation_plan "$@"; }
confirmation_show() { _setup_version_cached confirmation_show "$@"; }
