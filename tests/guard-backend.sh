#!/bin/bash
# 関所の次にある gh の差し替え。本物の GitHub へ送信しない。
set -euo pipefail
case "$*" in
'api --help')
 cat <<'HELP'
FLAGS
  -i, --include                Include HTTP response headers
  -X, --method string          HTTP method
  -f, --raw-field key=value    Add a string parameter

HELP
 ;;
'pr comment --help'|'issue comment --help'|'issue edit --help')
 cat <<'HELP'
FLAGS
  -b, --body text               Comment body
      --add-assignee login     Add an assignee

INHERITED FLAGS
  -R, --repo [HOST/]OWNER/REPO   Select repository

HELP
 ;;
'api --include --method POST repos/'*'/git/refs --raw-field ref=invalid')
	[[ -z ${TEST_GUARD_MARKER:-} ]] || touch "$TEST_GUARD_MARKER"
 [[ -z ${TEST_GUARD_CALLS:-} ]] || jq -nc --args '$ARGS.positional' -- "$@" >>"$TEST_GUARD_CALLS"
 case ${TEST_GUARD_RESPONSE:-422} in
 empty) echo 'intentional network failure' >&2; exit 77 ;;
 bad-json) printf 'HTTP/2.0 422\n\nnot json\n'; exit 1 ;;
 201) printf 'HTTP/2.0 201\n\n{}\n'; exit 0 ;;
 *) printf 'HTTP/2.0 %s\n\n{"message":"Validation Failed"}\n' "${TEST_GUARD_RESPONSE:-422}"; exit 1 ;;
 esac ;;
'pr comment '*|'issue comment '*|'issue edit '*)
 [[ -z ${HOST_GH_CALLS:-} ]] || jq -nc --args '$ARGS.positional' -- "$@" >>"$HOST_GH_CALLS" ;;
*) echo "Unexpected gh call: $*" >&2; exit 90 ;;
esac
