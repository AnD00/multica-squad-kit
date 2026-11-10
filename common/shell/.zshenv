# multica-squad-kit-managed
export SQUAD_KIT_ALLOWED_REPOS='{{ALLOWED_REPOS_FILE}}'
# シェル起動時に関所を先頭に戻す。
# env.sh は CLAUDE_ENV_FILE でも渡し、Claude Code のコマンド直前にも読む。
case $PATH in
	'{{AGENT_BIN_DIR}}':*) ;;
	*) export PATH='{{AGENT_BIN_DIR}}':"$PATH" ;;
esac
