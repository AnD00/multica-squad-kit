# 登録を始める前に、管理印なしの旧い生成ファイルだけを人へ確認する。
migrate_legacy_host() {
	host_paths
	mkdir -p "${kit_root:-$root}/tmp"
	migration_result=$(mktemp "${kit_root:-$root}/tmp/migration.XXXXXX") || die '移行の結果を保存できません。'
	python3 "${kit_root:-$root}/lib/migrate.py" "${kit_root:-$root}" "$agent_home" "$migration_result" "${project_id:-}" || die '初回の移行に失敗しました。登録前で停止します。'
}

migration_report() {
	[[ -n ${migration_result:-} && -s $migration_result ]] || return 0
	python3 "${kit_root:-$root}/lib/migrate.py" --report "$migration_result" >&2
	rm -f -- "$migration_result"
}
