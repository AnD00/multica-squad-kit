- 場面の ID: keep-14
- 型: 保

## 元の出来事

紐付いた PR のマージ待ちでは、既存の見張りだけを登録する。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` に QA の役が書いた「返事がそろいました」というコメント `comment-5` で起きました。返信は `--parent comment-5` にしてください。

レビューと E2E はどちらも成功し、人間のマージへ回すところです。metadata の `pr_url` は `https://github.com/example/shop/pull/7`、タスクは `in_progress` です。PR に触れる実行はありません。
PR はタスクに紐付いています。

## 合格の基準

1. [記録] 紐付けとコンフリクトを確認し、従来の CI・コンフリクトの規則を登録している。 `判定: called: ^squad-pr-watch link-check issue-shop-1 && called: ^squad-pr-watch conflicts-check issue-shop-1 && called: ^squad-pr-watch ci issue-shop-1 && called: ^squad-pr-watch conflicts issue-shop-1`
2. [記録] 紐付いていない PR 用の定期確認を登録せず、人間のマージへ回している。 `判定: not-called: ^squad-pr-watch unlinked issue-shop-1 && posted: mention://member/member1 && called: ^multica issue status issue-shop-1 in_review`
