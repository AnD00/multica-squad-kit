# 共有ホストの準備。テストでは置き場と CLI・ps を差し替える。
host_paths() {
	agent_home=${TEMPLATE_AGENT_HOME:-$HOME/.multica-agent}
	daemon_id_file=${TEMPLATE_DAEMON_ID_FILE:-$HOME/.multica/daemon.id}
	[[ $agent_home == /* && $agent_home != *$'\n'* ]] || die 'ホストの置き場は改行のない絶対パスにしてください。'
}

host_install() {
	local src=$1 dst=$2 executable=$3
	[[ ! -L $dst ]] || die "シンボリックリンクは上書きしません: $dst"
	mkdir -p "$(dirname "$dst")" || die "置き場を作れません: $dst"
	if ! cmp -s "$src" "$dst"; then
		cp "$src" "$dst" || die "ファイルを写せません: $dst"
	fi
	[[ $executable != yes || -x $dst ]] || chmod 755 "$dst" || die "実行権限を付けられません: $dst"
}

host_shared_file() {
	local src=$1 dst=$2 executable=$3
	if [[ -e $dst ]] && ! grep -qx '# multica-squad-kit-managed' "$dst"; then
		ui_notice warn "$dst" "印のない既存のファイルをそのまま使います" || ui_warning "印のない既存のファイルをそのまま使います: $dst"
		return
	fi
	host_install "$src" "$dst" "$executable"
}

# 見本を採取したバージョンを、配布するライブラリ自身に持たせる。
host_cli_library() (
	local generated version quoted content result=0 fixture_root=${kit_root:-$root}
	mkdir -p "$root/tmp" || die 'CLI のライブラリの作業場所を作れませんでした。'
	generated=$(mktemp "$root/tmp/cli-library.XXXXXX") || die 'CLI のライブラリの一時ファイルを作れませんでした。'
	trap 'rm -f -- "$generated"' EXIT
	IFS= read -r version <"$fixture_root/tests/fixtures/cli/VERSION" || die 'CLI の見本のバージョンを読めませんでした。'
	printf -v quoted '%q' "$version"
	content=$(cat "$root/common/monitor/squad-cli-lib") || die 'CLI のライブラリを読めませんでした。'
	printf '%s\n' "${content//'{{SQUAD_CLI_VERIFIED_VERSION}}'/$quoted}" >"$generated"
	host_shared_file "$generated" "$agent_home/bin/squad-cli-lib" yes || result=$?
	return "$result"
)

# 手順「ホストを準備」の値。関所のパスを、ホームの下なら ~ で縮めて 2 つの空白で並べる。
host_gate_summary() {
	local path tilde='~' summary='' paths
	[[ -n ${agent_home:-} ]] || return 0
	paths=("$agent_home/bin/gh" "$agent_home/git-hooks/pre-push")
	if uses_runtime codex; then paths[${#paths[@]}]=$agent_home/codex/config.toml; fi
	for path in "${paths[@]}"; do
		if [[ -n ${HOME:-} && $path == "$HOME"/* ]]; then path=$tilde${path#"$HOME"}; fi
		summary+=${summary:+  }$path
	done
	printf '%s' "$summary"
}

# 最初の JSON の値と終了コードで、ログイン切れと確認そのものの失敗を分ける。
host_check_claude_auth() {
	local work state diagnosis result=0
	mkdir -p "$root/tmp" || die 'ログインの確認の作業場所を作れませんでした。'
	work=$(mktemp -d "$root/tmp/claude-auth.XXXXXX") || die 'ログインの確認の作業場所を作れませんでした。'
	CLAUDE_CONFIG_DIR="$agent_home/claude" claude auth status </dev/null >"$work/stdout" 2>"$work/stderr" || result=$?
	if ! diagnosis=$(python3 - "$work/stdout" "$work/stderr" "$result" 2>/dev/null <<'PY'
import json
import sys
from pathlib import Path

stdout = Path(sys.argv[1]).read_bytes()
stderr = Path(sys.argv[2]).read_bytes()
result = int(sys.argv[3])
text = stdout.decode("utf-8", errors="replace").lstrip(" \t\r\n")
state = "unknown"
if not text:
    first = "空"
else:
    try:
        value, _ = json.JSONDecoder().raw_decode(text)
    except ValueError:
        first = "JSON として読めない"
    else:
        if not isinstance(value, dict):
            first = "オブジェクトでない"
        elif type(value.get("loggedIn")) is not bool:
            first = "loggedIn が真偽値でない"
        else:
            state = "true" if value["loggedIn"] else "false"
            first = "loggedIn が " + state

if b"EINVAL" in stderr and b"kqueue" in stderr:
    category = "Claude の CLI の既知の不具合（kqueue）"
elif state == "true" and result != 0:
    category = "CLI がログイン済みと答えたまま失敗した"
else:
    category = "CLI の出力を読めない（詳細は省略）"

print(state)
print("  診断（claude auth status）:")
print("    分類: " + category)
print("    終了コード: " + str(result))
print("    標準出力の最初の値: " + first)
print("    標準出力: " + ("あり（内容は省略）" if stdout else "なし"))
print("    標準エラー: " + ("あり（内容は省略）" if stderr else "なし"))
PY
	); then
		rm -rf -- "$work"
		die 'Claude のログインの確認の出力を読めませんでした。'
	fi
	rm -rf -- "$work"
	state=${diagnosis%%$'\n'*}
	case $state:$result in
	true:0) return 0 ;;
	false:*)
		die "エージェント用の Claude にログインしてください: CLAUDE_CONFIG_DIR=$agent_home/claude claude"
		;;
	esac
	# CLI の文字列は表示せず、固定の診断だけをエラーに続ける。
	ui_phase_fail
	ui_error "エージェント用の Claude のログインを確認できませんでした。ログインが切れているとは限りません。端末から CLAUDE_CONFIG_DIR=$agent_home/claude claude auth status を流して、ログインの状態を確認してから流し直してください。問い合わせるときは、下の診断の行だけを添えてください。"
	printf '%s\n' "${diagnosis#*$'\n'}" >&2
	exit 1
}

prepare_host() {
	local file
	host_paths
	check_runtime_tools || die '選んだランタイムを導入してから流し直してください。'
	(umask 077; mkdir -p "$agent_home/claude" "$agent_home/codex" "$agent_home/bin" "$agent_home/git-hooks") || die 'ホストの置き場を作れませんでした。'
	host_shared_file "$root/common/guard/gh" "$agent_home/bin/gh" yes
	host_shared_file "$root/common/guard/pre-push" "$agent_home/git-hooks/pre-push" yes
	# 作る間の一覧が動いているときは、関所のパスを手順の値に出す（host_gate_summary）。
	ui_phase_active || printf '使用する gh の関所: %s\n使用する git push の関所: %s\n' "$agent_home/bin/gh" "$agent_home/git-hooks/pre-push" >&2
	[[ -f $agent_home/bin/gh && -x $agent_home/bin/gh && -f $agent_home/git-hooks/pre-push && -x $agent_home/git-hooks/pre-push ]] || die '既存の関所を利用できません。表示したファイルの実行権限・読み取り権限を管理者に確認してもらい、流し直してください。既存のファイルは上書きしません。'
	if uses_runtime codex; then
		host_shared_file "$root/common/codex/config.toml" "$agent_home/codex/config.toml" no
		ui_phase_active || printf '使用する Codex の設定: %s\n' "$agent_home/codex/config.toml" >&2
		[[ -r $agent_home/codex/config.toml ]] || die 'Codex の設定を利用できません。表示したファイルの読み取り権限を管理者に確認してもらい、流し直してください。既存の設定は上書きしません。'
		# ログインシェルでは別の起動ファイルが効くため、確認した環境とそろえる。
		if ! python3 - "$agent_home/codex/config.toml" <<'PY'
import sys

try:
    import tomllib
    with open(sys.argv[1], "rb") as source:
        config = tomllib.load(source)
except (ImportError, OSError, ValueError):
    sys.exit(1)
sys.exit(0 if config.get("allow_login_shell") is False else 1)
PY
		then
			die 'Codex の設定で allow_login_shell = false を確認できません。表示した設定が正しい TOML で、トップレベルの値が真偽値の false か管理者に確認してもらってください。既存の設定は上書きしません。'
		fi
	fi
	for file in "$root/common/monitor/"squad-*; do
		if [[ ${file##*/} == squad-cli-lib ]]; then
			host_cli_library
		else
			host_shared_file "$file" "$agent_home/bin/$(basename "$file")" yes
		fi
	done
	if uses_runtime claude; then
		host_check_claude_auth
	fi
	if uses_runtime codex; then
		CODEX_HOME="$agent_home/codex" codex login status >/dev/null 2>&1 || die "エージェント用の Codex にログインしてください: CODEX_HOME=$agent_home/codex codex login"
	fi
	prepare_daemon
}

# プロジェクトを作るか見つけた直後、エージェント登録前に呼ぶ。
prepare_project_host() {
	[[ $# -ge 2 ]] || die 'prepare_project_host にはプロジェクト ID と、一つ以上の OWNER/REPO を渡してください。'
	local id=$1 repo file content='' previous='' removed='' escaped escaped_bin needle='{{ALLOWED_REPOS_FILE}}' bin_needle='{{AGENT_BIN_DIR}}'
	shift
	[[ $id =~ ^[A-Za-z0-9_-]+$ ]] || die 'プロジェクト ID が不正です。'
	# 全件を確認してから置き場を作る。ファイルは選択順で一行に一つとする。
	for repo in "$@"; do
		repo=$(printf '%s' "$repo" | LC_ALL=C tr '[:upper:]' '[:lower:]')
		[[ $repo =~ ^[a-z0-9][a-z0-9_.-]*/[a-z0-9_.-]+$ && ${repo#*/} != . && ${repo#*/} != .. ]] || die 'リポジトリは OWNER/REPO の形で渡してください。'
		if [[ $'\n'$content$'\n' != *$'\n'"$repo"$'\n'* ]]; then content+=${content:+$'\n'}$repo; fi
	done
	host_paths
	allowed_repos_file="$agent_home/allowed-repos.d/$id"
	project_shell_dir="$agent_home/template/shell/$id"
	[[ ! -L $allowed_repos_file ]] || die "シンボリックリンクは上書きしません: $allowed_repos_file"
	if [[ -f $allowed_repos_file ]]; then
		previous=$(cat "$allowed_repos_file") || die '前の許すリポジトリを読めませんでした。'
		while IFS= read -r repo; do
			[[ -n $repo ]] || continue
			repo=$(printf '%s' "$repo" | LC_ALL=C tr '[:upper:]' '[:lower:]')
			if [[ $'\n'$content$'\n' != *$'\n'"$repo"$'\n'* ]]; then removed+=${removed:+$'\n'}$repo; fi
		done <<<"$previous"
	fi
	# 既存の関所も含め、全選択を確認してから実際の許可を書き替える。
	# 確認用の起動ファイルは同じひな形から作り、専用の一時許可を指す。
	host_check_guards "$content" || die '関所の確認に失敗しました。従来の許可とシェル起動ファイルを保って停止します。'
	# プロジェクト登録から呼ぶ場合は、通信中の紐付け変更も最後に確認する。
	# local の印は prepare_project が付け、ホスト単体の準備では呼ばない。
	if [[ ${project_host_recheck:-no} == yes ]]; then
		project_repositories_recheck
	fi
	(umask 077; mkdir -p "$agent_home/allowed-repos.d" "$project_shell_dir") || die 'プロジェクト用のホストの置き場を作れませんでした。'
	host_write "$allowed_repos_file" "$content"
	if [[ -n $removed ]]; then
		while IFS= read -r repo; do
			ui_notice drop "$repo" "許すリポジトリから外しました" || printf '許すリポジトリから外しました: %s\n' "$repo" >&2
		done <<<"$removed"
	fi
	# 一重引用符のあるパスも、一重引用符を閉じてエスケープしてから再開する。
	escaped=${allowed_repos_file//\'/\'\\\'\'}
	escaped_bin=${agent_home//\'/\'\\\'\'}/bin
	for file in .zshenv env.sh; do
		content=$(cat "$root/common/shell/$file") || die 'シェルのひな形を読めませんでした。'
		content=${content//"$needle"/"$escaped"}
		content=${content//"$bin_needle"/"$escaped_bin"}
		if [[ -e $project_shell_dir/$file || -L $project_shell_dir/$file ]] && ! grep -qx '# multica-squad-kit-managed' "$project_shell_dir/$file"; then
			ui_notice warn "$project_shell_dir/$file" "印のない既存のファイルをそのまま使います" || ui_warning "印のない既存のファイルをそのまま使います: $project_shell_dir/$file"
			continue
		fi
		host_write "$project_shell_dir/$file" "$content"
	done
}

host_check_guards() (
	umask 077
	local content=$1 probe file escaped escaped_bin needle='{{ALLOWED_REPOS_FILE}}' bin_needle='{{AGENT_BIN_DIR}}' repo shell mode allowed shell_content
	local guard_dir dir candidate real_gh_dir='' probe_path path_dirs
	[[ -x $agent_home/bin/gh && -x $agent_home/git-hooks/pre-push ]] || die '使う関所に実行権限がありません。表示した gh と pre-push の置き場と権限を管理者に確認してもらってください。'
	guard_dir=$(cd "$agent_home/bin" && pwd) || die 'gh の関所の置き場を読めませんでした。'
	IFS=: read -r -a path_dirs <<<"$PATH"
	for dir in "${path_dirs[@]}"; do
		[[ -n $dir && -x $dir/gh ]] || continue
		candidate=$(cd "$dir" 2>/dev/null && pwd) || continue
		[[ $candidate != "$guard_dir" ]] || continue
		real_gh_dir=$candidate
		break
	done
	[[ -n $real_gh_dir ]] || die '本物の gh が関所の外の PATH に見つかりません。gh の導入と PATH を確認してください。'
	probe_path="$real_gh_dir:$PATH"
	mkdir -p "$root/tmp" || die '関所の確認の作業場所を作れませんでした。'
	probe=$(mktemp -d "$root/tmp/guard-check.XXXXXX") || die '関所の確認の作業場所を作れませんでした。'
	trap 'rm -rf -- "$probe"' EXIT
	printf '%s\n' "$content" >"$probe/allowed" || die '確認用の許可ファイルを書けませんでした。'
	: >"$probe/empty-allowed" || die '確認用の空の許可ファイルを書けませんでした。'
	escaped_bin=${agent_home//\'/\'\\\'\'}/bin
	for mode in allow deny; do
		mkdir "$probe/$mode" || die '確認用の起動ファイルの置き場を作れませんでした。'
		allowed="$probe/allowed"
		[[ $mode != deny ]] || allowed="$probe/empty-allowed"
		escaped=${allowed//\'/\'\\\'\'}
		for file in .zshenv env.sh; do
			shell_content=$(cat "$root/common/shell/$file") || die '起動ファイルのひな形を読めませんでした。'
			shell_content=${shell_content//"$needle"/"$escaped"}
			shell_content=${shell_content//"$bin_needle"/"$escaped_bin"}
			printf '%s\n' "$shell_content" >"$probe/$mode/$file" || die '確認用の起動ファイルを書けませんでした。'
		done
	done
	mkdir "$probe/repository" "$probe/empty-template" || die 'push の確認の作業場所を作れませんでした。'
	GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$probe/repository" init -q --template="$probe/empty-template" || die 'push の関所を確認する作業場所を作れませんでした。'
	cat >"$probe/check.sh" <<'CHECK' || die '関所の確認のコマンドを書けませんでした。'
set -euo pipefail
guard=$1; hook=$2; repo=$3; temporary=$4; mode=$5
if [[ $(command -v gh) != "$guard" ]]; then
 echo 'Claude の実行の順で gh が関所を選びません。ひな形の env.sh の PATH を確認してください。' >&2
 exit 1
fi
# 同じ選択先でも、空の許可なら両関所が拒否しなければならない。
# GitHub の422などの失敗や、関所自体の実行失敗は「関所で拒否した」と扱わない。
if [[ $mode == deny ]]; then
 blocked=yes
 if response=$(gh api --include --method POST "repos/$repo/git/refs" --raw-field ref=invalid 2>"$temporary/gh-deny-error"); then
  blocked=no
 elif [[ -n $response ]] || ! grep -q '^gh の関所:' "$temporary/gh-deny-error"; then
  blocked=no
 fi
 if [[ $blocked == no ]]; then
  printf 'gh が空の許可で選択先を拒否したと確認できません: %s\n' "$repo" >&2
  cat "$temporary/gh-deny-error" >&2
 fi
 if printf 'refs/heads/template-permission-check 1111111111111111111111111111111111111111 refs/heads/template-permission-check 0000000000000000000000000000000000000000\n' | "$hook" origin "https://github.com/$repo.git" >"$temporary/push-deny-output" 2>"$temporary/push-deny-error"; then
  blocked=no
  printf 'pre-push が空の許可でも選択先を通しました: %s\n' "$repo" >&2
 elif ! grep -q '^git push の関所:' "$temporary/push-deny-error"; then
  blocked=no
  printf 'pre-push の関所による拒否を確認できません: %s\n' "$repo" >&2
  cat "$temporary/push-deny-error" >&2
 fi
 if [[ $blocked == no ]]; then
  echo '表示した gh と pre-push が SQUAD_KIT_ALLOWED_REPOS を読むか、共有ホストの管理者と確認してください。固定の共有許可を増やしたり関所を迂回したりせず、manual.md の「既存の関所の確認」に従って対応してから流し直してください。' >&2
  exit 1
 fi
 exit 0
fi
# GitHub が必ず拒否する ref と、必須の sha を欠く要求で、書き込みの
# 関所を通過して GitHub の入力検証まで届くことを確認する。何も作らない。
# 正しい ref・sha に置き換えてはならない（manual.md の根拠を参照）。
if response=$(gh api --include --method POST "repos/$repo/git/refs" --raw-field ref=invalid 2>"$temporary/gh-error"); then
 echo 'gh の確認が想定外に成功しました。関所と gh の設定を管理者に確認してもらってください。' >&2
 exit 1
fi
code=$(awk '/^HTTP\/[0-9.]+ / {code=$2} END {gsub("\r","",code); print code}' <<<"$response")
if [[ $code != 422 && $code != 409 ]] || ! awk '/^\{/ {body=1} body {print}' <<<"$response" | jq -e 'type=="object" and (.message|type=="string" and length>0)' >/dev/null; then
 printf 'gh が選択先の入力検証まで届きませんでした: %s（HTTP %s）\n' "$repo" "${code:-応答なし}" >&2
 cat "$temporary/gh-error" >&2
 echo '表示した gh がプロジェクトの SQUAD_KIT_ALLOWED_REPOS を読むか、gh auth status と GitHub の権限・接続先を確認してください。既存の関所を直す場合は、同居するプロジェクトの管理者と調整し、manual.md の「既存の関所の確認」に従って流し直してください。' >&2
 exit 1
fi
# リモートへの git push はせず、実際の hook に新規更新行を渡す。
if ! printf 'refs/heads/template-permission-check 1111111111111111111111111111111111111111 refs/heads/template-permission-check 0000000000000000000000000000000000000000\n' | "$hook" origin "https://github.com/$repo.git"; then
 printf 'pre-push が選択先を拒否しました: %s\n' "$repo" >&2
 echo '表示した pre-push がプロジェクトの SQUAD_KIT_ALLOWED_REPOS を読むか確認してください。同居するプロジェクトの管理者と調整し、manual.md の「既存の関所の確認」に従ってから流し直してください。' >&2
 exit 1
fi
CHECK
	while IFS= read -r repo; do
		# 作る間の一覧には、確認しているリポジトリを添える（止まったときの ✖ にも付く）。
		ui_phase_progress 0 0 "$repo"
		# zsh では .zshenv と env.sh を別々の手順で確認する。
		for shell in /bin/zsh /bin/bash; do
			for mode in allow deny; do
				if ! (cd "$probe/repository" && PATH="$probe_path" ZDOTDIR="$probe/$mode" BASH_ENV="$probe/$mode/env.sh" "$shell" -c '[[ $(command -v gh) == "$1" ]]' -- "$agent_home/bin/gh"); then
					die "通常の gh が関所を選びません。シェル起動ファイルの PATH を確認してください: ${repo}（${shell}、${mode}）"
				fi
				if ! (cd "$probe/repository" && PATH="$probe_path" ZDOTDIR="$probe/$mode" BASH_ENV="$probe/$mode/env.sh" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$shell" -c 'export PATH="$6" && . "$BASH_ENV" && . "$4/check.sh"' -- "$agent_home/bin/gh" "$agent_home/git-hooks/pre-push" "$repo" "$probe" "$mode" "$probe_path"); then
					die "選択したリポジトリの許可と分離を確認できませんでした: ${repo}（${shell}、${mode}）"
				fi
			done
		done
		# 作る間の一覧が動いているときは、1 件ごとに出さず、手順の値にまとめる。
		ui_phase_active || printf '許可の確認: %s（gh と pre-push、bash と zsh）: 成功\n' "$repo" >&2 || die '関所の確認の結果を表示できませんでした。'
	done <<<"$1"
)

host_write() {
	local dst=$1 content=$2 temporary
	[[ ! -L $dst ]] || die "シンボリックリンクは上書きしません: $dst"
	if [[ -f $dst ]] && [[ $(cat "$dst") == "$content" ]]; then return; fi
	temporary=$(mktemp "${dst%/*}/.host.XXXXXX") || die "一時ファイルを作れません: $dst"
	if ! printf '%s\n' "$content" >"$temporary" || ! mv -f "$temporary" "$dst"; then
		rm -f -- "$temporary"
		die "ファイルを書けません: $dst"
	fi
}

read_daemon_status() {
	if daemon_status=$(mc daemon status --output json); then :; else
		jq -e '.status=="stopped" or .status=="not_running"' >/dev/null <<<"$daemon_status" || die 'デーモンの状態を取得できませんでした。'
	fi
	jq -e 'type=="object" and (.status=="running" or .status=="stopped" or .status=="not_running") and (.pid==null or (.pid|type=="number" and .>0 and floor==.))' >/dev/null <<<"$daemon_status" || die 'デーモンの状態の応答が不正です。'
	daemon_pid=$(jq -r '.pid // empty' <<<"$daemon_status")
	if [[ $(jq -r '.server_url // empty' <<<"$daemon_status") != '' ]]; then
		[[ $(jq -r '.server_url | rtrimstr("/")' <<<"$daemon_status") == "$server_url" ]] || die '別のサーバーのデーモンが動いています。設定を確認してください。'
	fi
	daemon_id=$(jq -r '.daemon_id // empty' <<<"$daemon_status")
	if [[ -z $daemon_id && -f $daemon_id_file ]]; then
		daemon_id=$(cat "$daemon_id_file") || die 'デーモン ID を読めませんでした。'
	fi
}

read_host_runtimes() {
	local observed_runtimes
	observed_runtimes=$(mc runtime list --output json) || die 'ランタイムを取得できませんでした。'
	jq -e 'type=="array" and all(.[]; (.id|type=="string") and (.owner_id|type=="string") and (.provider|type=="string") and (.status|type=="string"))' >/dev/null <<<"$observed_runtimes" || die 'ランタイムの応答が不正です。'
	claude_runtime_id=''; codex_runtime_id=''
	[[ -n $daemon_id ]] || return 0
	claude_runtime_id=$(jq -r --arg owner "$host_owner_id" --arg daemon "$daemon_id" '[.[] | select(.owner_id==$owner and .daemon_id==$daemon and .provider=="claude" and .status=="online")][0].id // empty' <<<"$observed_runtimes")
	codex_runtime_id=$(jq -r --arg owner "$host_owner_id" --arg daemon "$daemon_id" '[.[] | select(.owner_id==$owner and .daemon_id==$daemon and .provider=="codex" and .status=="online")][0].id // empty' <<<"$observed_runtimes")
}

host_runtimes_online() {
	if uses_runtime claude && [[ -z $claude_runtime_id ]]; then return 1; fi
	if uses_runtime codex && [[ -z $codex_runtime_id ]]; then return 1; fi
	return 0
}

daemon_has_agent_env() {
	local observed
	[[ -n $daemon_pid ]] || return 1
	observed=$(ps eww -o command= -p "$daemon_pid") || return 1
	[[ " $observed " == *" CODEX_HOME=$agent_home/codex "* && " $observed " == *" PATH=$agent_home/bin:"* ]]
}

prepare_daemon() {
	local profile active i
	profile=$(mc user profile get --output json) || die '実行する人の情報を取得できませんでした。'
	host_owner_id=$(jq -er '.id | select(type=="string" and length>0)' <<<"$profile") || die '実行する人の ID が不正です。'
	read_daemon_status
	read_host_runtimes
	if [[ -n $daemon_pid ]]; then
		if host_runtimes_online && daemon_has_agent_env; then return; fi
		# 止める直前に読み直す。取得不能やタスク数不明は安全とみなさない。
		read_daemon_status
		active=$(jq -er '[.active_task_count,.running_task_count,.resource_wait_task_count] | map(select(.!=null)) | select(length>0 and all(.[]; type=="number" and .>=0 and floor==.)) | max' <<<"$daemon_status") || die '実行中のタスク数が不明なため、デーモンを止めません。'
		[[ $active == 0 ]] || die '起動し直す必要がありますが、実行中のタスクがあります。終わってから流し直してください。'
		mc daemon stop || die 'デーモンを停止できませんでした。'
	elif [[ -n $claude_runtime_id || -n $codex_runtime_id ]]; then
		die 'CLI 以外のデーモンが動いています。止めてから流し直してください。'
	fi
	# IDE 等の環境を引き継がず、ホストの共有設定で一つのデーモンを起動する。
	env -i HOME="$HOME" USER="${USER:-}" SHELL=/bin/zsh PATH="$agent_home/bin:$PATH" CODEX_HOME="$agent_home/codex" MULTICA_SERVER_URL="$server_url" multica daemon start || die 'デーモンを起動できませんでした。'
	for ((i=0; i<30; i++)); do
		read_daemon_status
		read_host_runtimes
		if host_runtimes_online && daemon_has_agent_env; then return; fi
		sleep 2
	done
	die 'ランタイムがオンラインになりません。daemon status とログを確認してください。'
}
