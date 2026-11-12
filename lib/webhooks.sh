# Dependabot の役を残し、Webhook を使うと答えたときだけ真。
dependabot_webhook_active() { [[ " $enabled " == *' dependabot-merger '* && ${dependabot_webhook:-false} == true ]]; }

# 管理する Dependabot のオートパイロットの ID。リポジトリと担当で一つに決まらなければ偽。
dependabot_autopilot_id() {
	mc autopilot list --output json 2>/dev/null | jq -er --arg title "$(autopilot_title dependabot-merger "$1")" --arg project "$project_id" --arg agent "$2" '
		[.autopilots[] | select(.title==$title and .project_id==$project and .assignee_type=="agent" and .assignee_id==$agent)] |
		select(length==1) | .[0].id | select(type=="string" and length>0)' 2>/dev/null
}

# URL と署名の秘密はこのパイプからだけ出し、呼び出す側もパイプで受ける。
webhook_credentials() {
	mc autopilot get "$1" --show-secrets --output json 2>/dev/null |
		jq -ce --arg id "$2" '
			[.triggers[] | select(.id==$id and .kind=="webhook")] | select(length==1) | .[0] |
			if (.webhook_url|type=="string" and test("^https?://")) and
				((.has_signing_secret!=true) or (.signing_secret|type=="string" and length>0 and .!="********"))
			then {url:.webhook_url,content_type:"json",insecure_ssl:"0"} +
				(if .has_signing_secret then {secret:.signing_secret} else {} end)
			else error("取得できない認証情報") end' 2>/dev/null
}

# 失敗の理由は固定の文だけを返す。CLI の診断と応答は外へ出さない。
register_dependabot_webhook() (
	set +x
	local repo=$1 id agent current trigger_id hook_id code attempt
	local trigger=飛ばした registration=飛ばした delivery=記録なし reason=''
	webhook_result() {
		jq -nc --arg repository "$repo" --arg trigger "$trigger" --arg registration "$registration" --arg delivery "$delivery" --arg reason "$reason" '{repository:$repository,trigger:$trigger,registration:$registration,delivery:$delivery,reason:$reason}'
	}
	webhook_abort() { reason=$1; webhook_result; exit 0; }
	agent=$(jq -er '.["dependabot-merger"].id' <<<"$records") || webhook_abort 'Dependabot の担当を確認できませんでした。'
	id=$(dependabot_autopilot_id "$repo" "$agent") || webhook_abort '管理する Dependabot のオートパイロットを確認できませんでした。'
	# 通常の取得結果も必要な項目だけに絞ってから変数へ入れる。
	webhook_current() {
		mc autopilot get "$id" --output json 2>/dev/null | jq -ce --arg id "$id" --arg project "$project_id" --arg agent "$agent" '
			select(.autopilot.id==$id and .autopilot.project_id==$project and .autopilot.assignee_type=="agent" and .autopilot.assignee_id==$agent) |
			{can_write:.autopilot.can_write,triggers:[.triggers[]|{id,kind,enabled}]}' 2>/dev/null
	}
	current=$(webhook_current) || webhook_abort 'オートパイロットのトリガーを読めませんでした。'
	jq -e '.can_write==true' >/dev/null <<<"$current" || webhook_abort 'オートパイロットを編集する権限がありません。'
	trigger_id=$(jq -r '[.triggers[] | select(.kind=="webhook")][0].id // empty' <<<"$current")
	if [[ -z $trigger_id ]]; then
		mc autopilot trigger-add "$id" --kind webhook --label 'Dependabot の PR' --output json >/dev/null 2>&1 || webhook_abort 'Webhook のトリガーを作れませんでした。'
		trigger=作成
		current=$(webhook_current) || webhook_abort '作成したトリガーを読み直せませんでした。'
		trigger_id=$(jq -r '[.triggers[] | select(.kind=="webhook")][0].id // empty' <<<"$current")
		[[ -n $trigger_id ]] || webhook_abort '作成した Webhook のトリガーが見つかりません。'
	else
		trigger=既存
	fi
	jq -e --arg id "$trigger_id" 'any(.triggers[]; .id==$id and .enabled==true)' >/dev/null <<<"$current" || webhook_abort 'Webhook のトリガーが有効ではありません。持ち主が設定を確認してください。'
	code=$(gh api "repos/$repo" --jq '.permissions.admin==true' 2>/dev/null | jq -er 'select(type=="boolean")|tostring' 2>/dev/null) || webhook_abort 'GitHub のリポジトリの権限を確認できませんでした。'
	[[ $code == true ]] || webhook_abort 'GitHub のリポジトリの管理者ではありません。'
	# 一覧の読み取り権限を確認する。URL を含む応答からは件数だけを出す。
	gh api "repos/$repo/hooks" --paginate --slurp --jq 'map(length)|add' 2>/dev/null | jq -e 'select(type=="number")' >/dev/null 2>&1 || webhook_abort 'Webhook の一覧を読めません。gh の token の範囲（admin:repo_hook）を確認してください。'
	webhook_credentials "$id" "$trigger_id" | jq -e 'type=="object"' >/dev/null 2>&1 || webhook_abort 'Webhook の URL または署名の秘密を取得できませんでした。'
	hook_id=$({ webhook_credentials "$id" "$trigger_id" && gh api "repos/$repo/hooks" --paginate --slurp 2>/dev/null; } |
		jq -ser 'select(length==2) | .[0].url as $url | [.[1][][] | select(.config.url==$url)] |
			if length>1 then error("同じ宛先の複数の Webhook")
			elif length==0 then 0
			elif (.[0] | .active==true and .events==["pull_request"] and .config.content_type=="json") then .[0].id
			else -1 end |
			select(type=="number" and .>=-1 and floor==.)' 2>/dev/null) || webhook_abort '既存の Webhook と照合できませんでした。'
	[[ $hook_id != -1 ]] || webhook_abort '既存の GitHub Webhook の設定が、有効・pull_request のみ・JSON と一致しません。管理者が設定を確認してください。'
	if [[ $hook_id == 0 ]]; then
		hook_id=$(webhook_credentials "$id" "$trigger_id" |
			jq -c '{name:"web",active:true,events:["pull_request"],config:.}' 2>/dev/null |
			gh api "repos/$repo/hooks" --method POST --input - --jq '.id' 2>/dev/null |
			jq -er 'select(type=="number" and .>0 and floor==.)' 2>/dev/null) || webhook_abort 'GitHub に Webhook を登録できませんでした。'
		registration=作成
	else
		registration=既存
	fi
	# 新規は ping を最大 30 秒待つ。既存には送信せず最新の配信を読む。
	for attempt in 0 1 2 3 4 5 6; do
		code=$(gh api "repos/$repo/hooks/$hook_id/deliveries" --paginate --slurp --jq "[.[][] | select(.event==\"ping\" or \"$registration\"==\"既存\")] | sort_by(.delivered_at) | last | .status_code // 0" 2>/dev/null |
			jq -er 'select(type=="number" and .>=0 and .<=599 and floor==.)' 2>/dev/null) || { delivery=失敗; webhook_abort 'Webhook の配信履歴を読めませんでした。'; }
		[[ $code == 0 && $registration == 作成 && $attempt != 6 ]] || break
		sleep 5
	done
	if [[ $code == 2[0-9][0-9] ]]; then
		delivery="成功（HTTP ${code}）"
	elif [[ $code == 0 ]]; then
		webhook_abort 'Webhook の配信の記録がありません。'
	else
		delivery="失敗（HTTP ${code}）"
		webhook_abort 'Webhook の配信が成功していません。'
	fi
	webhook_result
)

prepare_project_webhooks() {
	local repo row reason
	# Webhook を使わない答えなら、登録を試みず、登録とフィルターのタスクも起票しない。
	if [[ " $enabled " == *' dependabot-merger '* ]] && ! dependabot_webhook_active; then
		prepare_project_webhook_leftovers
		return 0
	fi
	dependabot_webhook_active || return 0
	# 作る間の一覧の値は、登録を試すリポジトリの数。
	webhook_summary=$(jq length <<<"$selected_repositories")
	while IFS= read -r repo; do
		ui_phase_progress 0 0 "$repo"
		if ! row=$(register_dependabot_webhook "$repo"); then
			row=$(jq -nc --arg repository "$repo" '{repository:$repository,trigger:"飛ばした",registration:"飛ばした",delivery:"失敗",reason:"Webhook の登録の処理に失敗しました。"}')
		fi
		setup_webhook_rows=$(jq -c --argjson row "$row" '.+[$row]' <<<"$setup_webhook_rows")
		reason=$(jq -r '.reason' <<<"$row")
		if [[ -n $reason ]]; then queue_project_issue dependabot-webhook "$(jq -nc --arg repo "$repo" '[$repo]')" "$host_owner_id" "$repo"; fi
	done < <(jq -r '.[].repository' <<<"$selected_repositories")
}

# Webhook を使わない答えでも、前の実行で作ったトリガーは消さない。残っていれば、外すよう表示して起票する。
# 読むのは Multica のトリガーの種類だけで、GitHub と Webhook の URL には触れない。
prepare_project_webhook_leftovers() {
	local repo agent id kinds
	agent=$(jq -er '.["dependabot-merger"].id' <<<"$records") || agent=''
	while IFS= read -r repo; do
		if [[ -n $agent ]] && id=$(dependabot_autopilot_id "$repo" "$agent") &&
			kinds=$(mc autopilot get "$id" --output json 2>/dev/null | jq -ce --arg id "$id" 'select(.autopilot.id==$id) | [.triggers[].kind]' 2>/dev/null); then
			jq -e 'index("webhook")!=null' >/dev/null <<<"$kinds" || continue
			setup_webhook_leftovers=$(jq -c --arg repository "$repo" '.+[{repository:$repository,state:"残っている"}]' <<<"$setup_webhook_leftovers")
			queue_project_issue dependabot-webhook-removal "$(jq -nc --arg repo "$repo" '[$repo]')" "$host_owner_id" "$repo"
		else
			setup_webhook_leftovers=$(jq -c --arg repository "$repo" '.+[{repository:$repository,state:"確認できない"}]' <<<"$setup_webhook_leftovers")
		fi
	done < <(jq -r '.[].repository' <<<"$selected_repositories")
}

project_webhook_completion() {
	local repository trigger registration delivery reason state
	while IFS=$'\t' read -r repository state; do
		if [[ $state == 残っている ]]; then
			ui_line out warning "警告: ${repository}: Webhook を使わない答えですが、前の実行で作った Webhook のトリガーが残っています。外すよう起票しました。"
		else
			ui_line out warning "警告: ${repository}: 前の実行で作った Webhook のトリガーが残っているかを確認できませんでした。Multica の画面で確かめてください。"
		fi
	done < <(jq -r '.[] | [.repository,.state] | @tsv' <<<"${setup_webhook_leftovers:-[]}")
	[[ $(jq length <<<"${setup_webhook_rows:-[]}") != 0 ]] || return 0
	printf '%s\n' 'Webhook の登録:'
	while IFS=$'\t' read -r repository trigger registration delivery reason; do
		printf '  %s: トリガー ' "$repository"
		ui_result "$trigger"
		printf '、登録 '
		ui_result "$registration"
		printf '、配信 '
		ui_result "$delivery"
		[[ -z $reason ]] || printf '。%s' "$reason"
		printf '\n'
	done < <(jq -r '.[] | [.repository,.trigger,.registration,.delivery,.reason] | @tsv' <<<"$setup_webhook_rows")
}
