#!/usr/bin/env bash
# project-failure-test.sh の lib/render.sh のコピーにだけ追加する。
_project_failure_template_apply_definition=$(declare -f template_apply)
_project_failure_template_apply_definition=${_project_failure_template_apply_definition#template_apply}
eval "_project_failure_template_apply$_project_failure_template_apply_definition"
unset _project_failure_template_apply_definition

template_apply() {
 local key entry result=0
 # この補助は、2 つの通常ファイルを読む既存の呼び出しだけを対象にする。
 if [[ $# != 2 || ! -f $1 || ! -f $2 ]]; then
  _project_failure_template_apply "$@"
  return
 fi
 # 一時パスが違っても、内容・表示環境が同じなら成功した展開を共有する。
 key=$({
  printf '%s\0' "${LC_ALL-}" "${LC_CTYPE-}" "${LANG-}"
  cat "$1" || exit
  printf '\0'
  cat "$2"
 } | shasum -a 256) || return
 key=${key%% *}
 entry=$TEST_PROJECT_RENDER_CACHE/$key
 if [[ ! -f $entry.ready ]]; then
  _project_failure_template_apply "$@" >"$entry.out" 2>"$entry.err" || result=$?
  if [[ $result == 0 ]]; then
   : >"$entry.ready"
  fi
 fi
 cat "$entry.out"
 cat "$entry.err" >&2
 return "$result"
}
