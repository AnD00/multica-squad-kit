# 何も変更しない事前確認。
check_tools() {
	local tool missing=0
	for tool in multica jq gh; do
		if ! command -v "$tool" >/dev/null; then
			case $tool in
			multica) printf '%s\n' 'multica がありません。Homebrew で brew install multica-ai/tap/multica を実行してください。' >&2 ;;
			jq|gh) printf '%s\n' "$tool がありません。Homebrew で brew install $tool を実行してください。" >&2 ;;
			esac
			missing=1
		fi
	done
	if ! python3 -c 'import tomllib' >/dev/null 2>&1; then
		printf '%s\n' 'TOML の確認に Python 3.11 以上（tomllib）が必要です。Homebrew で brew install python を実行し、python3 の PATH を確認してください。' >&2
		missing=1
	fi
	[[ $missing == 0 ]] || die '道具を入れてから流し直してください。Homebrew がなければ https://brew.sh を参照してください。'
	if ! command -v claude >/dev/null && ! command -v codex >/dev/null; then
		die 'claude と codex がありません。利用する組織の手順で Claude Code か Codex CLI を導入し、PATH を確認して流し直してください。'
	fi
}

# 保存済みの答えに選択がない場合は、前の版と同じく両方を使う。
uses_runtime() {
	jq -e --arg runtime "$1" 'index($runtime)!=null' >/dev/null <<<"${runtimes:-[\"claude\",\"codex\"]}"
}

check_runtime_tools() {
	local tool missing=0
	for tool in claude codex; do
		uses_runtime "$tool" || continue
		if ! command -v "$tool" >/dev/null; then
			printf '%s\n' "$tool がありません。利用する組織の手順でエージェント用のランタイムを導入し、PATH を確認してください。" >&2
			missing=1
		fi
	done
	[[ $missing == 0 ]]
}

mc() { MULTICA_SERVER_URL="$server_url" MULTICA_WORKSPACE_ID="${workspace_id:-}" multica "$@"; }

# 接続先の質問とログインの案内は questions.sh。

read_list() {
	local kind=$1 raw
	shift
	raw=$(mc "$@" --output json) || die "$kind を取得できませんでした。"
	case $kind in
	ワークスペース) jq -e 'type=="array" and all(.[]; (.id|type=="string" and test("^[A-Za-z0-9_-]+$")) and (.name|type=="string" and length>0))' >/dev/null <<<"$raw" || die "$kind の応答が不正です。" ;;
	プロジェクト) jq -e 'type=="array" and all(.[]; (.id|type=="string" and test("^[A-Za-z0-9_-]+$")) and (.title|type=="string" and length>0))' >/dev/null <<<"$raw" || die "$kind の応答が不正です。" ;;
	リポジトリ) jq -e 'type=="array" and all(.[]; .url|type=="string" and length>0)' >/dev/null <<<"$raw" || die "$kind の応答が不正です。" ;;
	メンバー) jq -e 'type=="array" and all(.[]; (.user_id|type=="string" and test("^[A-Za-z0-9_-]+$")) and (.name|type=="string" and length>0))' >/dev/null <<<"$raw" || die "$kind の応答が不正です。" ;;
	esac
	printf '%s\n' "$raw"
}

# スクワッドだけは既存の大文字・小文字の表記を保って引き継ぐ。
squad_named() {
	jq -e 'type=="array" and all(.[]; (.id|type=="string" and length>0) and (.name|type=="string" and length>0))' >/dev/null <<<"$1" || die 'スクワッド一覧の応答が不正です。'
	matches=$(jq -c --arg name "$2" '[.[] | select((.name|ascii_downcase)==($name|ascii_downcase))]' <<<"$1")
	[[ $(jq length <<<"$matches") -le 1 ]] || die "大文字小文字の違いだけのスクワッドが複数あります: $2"
}
