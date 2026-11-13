- 場面の ID: keep-18
- 型: 保

## 元の出来事

紐付いていない PR をマージへ回すとき、期限付きの見張りと人間への行を添える。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` に QA の役が書いた「返事がそろいました」というコメント `comment-5` で起きました。返信は `--parent comment-5` にしてください。

レビューと E2E はどちらも成功し、人間のマージへ回すところです。metadata の `pr_url` は `https://github.com/example/shop/pull/7`、タスクは `in_progress` です。PR に触れる実行はありません。
PR は紐付いていません。以前の引き継ぎには、PR の URL の下に `紐付けの失敗:` の警告の段落が残っています。

## 合格の基準

1. [記録] 区切りで確認し、従来の規則に定期確認を加えている。 `判定: called: ^squad-pr-watch link-check issue-shop-1 && called: ^squad-pr-watch ci-now issue-shop-1 && called: ^squad-pr-watch conflicts-check issue-shop-1 && called: ^squad-pr-watch ci issue-shop-1 && called: ^squad-pr-watch conflicts issue-shop-1 && called: ^squad-pr-watch unlinked issue-shop-1 comment-5 agent-ci-monitor`
2. [記録] 人間を呼び、マージ後の done の依頼と期限の行、警告の段落を残す。 `判定: posted: mention://member/member1 && posted: done && posted: 見張り: 1 時間おき、2026-01-13T10:00Z まで && posted: 紐付けの失敗: && called: ^multica issue status issue-shop-1 in_review`
3. [採点] 紐付けだけで止まらずマージの判断を頼み、警告の段落をそのまま写している。連携を確認する案内も添えている。
