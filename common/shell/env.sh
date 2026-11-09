# multica-squad-kit-managed
export SQUAD_KIT_ALLOWED_REPOS='{{ALLOWED_REPOS_FILE}}'
# ランタイムが PATH を組み替えても、通常の gh は関所を先に選ぶ。
case $PATH in
	'{{AGENT_BIN_DIR}}':*) ;;
	*) export PATH='{{AGENT_BIN_DIR}}':"$PATH" ;;
esac
