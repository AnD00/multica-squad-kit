#!/usr/bin/env bash
# BASH_ENV として、テストの最上位の bash にだけ読み込む。
_squad_kit_error_file=${SQUAD_KIT_TEST_ERROR_FILE:?}
unset BASH_ENV SQUAD_KIT_TEST_ERROR_FILE
_squad_kit_record_error() {
	# set +e の間の終了コード確認を、終了の原因として残さない。
	[[ $- == *e* && $BASH_SUBSHELL == 0 && ! -s $_squad_kit_error_file ]] || return 0
	local source=$1 line=$2 command=$3 frame
	{
		printf '%s\n%s\n%s\n' "$source" "$line" "$command"
		for ((frame=1; frame<${#FUNCNAME[@]}-1; frame++)); do
			printf '呼び出し: %s:%s: %s\n' "${BASH_SOURCE[$((frame+1))]}" "${BASH_LINENO[$frame]}" "${FUNCNAME[$frame]}"
		done
	} >"$_squad_kit_error_file"
	return 0
}
set -o errtrace
trap '_squad_kit_record_error "${BASH_SOURCE[0]}" "$LINENO" "$BASH_COMMAND"' ERR
