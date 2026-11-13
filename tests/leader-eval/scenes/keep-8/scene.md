- 場面の ID: keep-8
- 型: 保

## 元の出来事

紐付いていない PR を受け取っても、区切りの確認を行ってレビューへ進める。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` の実装の役のコメント `comment-3` で起きました。返信は `--parent comment-3` にしてください。

最後の実装を push した引き継ぎです。承認済みのフェーズは全部そろい、レビューと QA の E2E が残っています。metadata の `pr_url` は `https://github.com/example/shop/pull/7` で、PR は紐付いていません。タスクは `in_progress`、返事を待つ回や PR に触れる実行はなく、重要の新しい判断の時機ではありません。

## 合格の基準

1. [記録] 判定とその場の CI・コンフリクトの確認を流している。 `判定: called: ^squad-pr-watch link-check issue-shop-1 && called: ^squad-pr-watch ci-now issue-shop-1 agent-orchestrator comment-3 agent-ci-monitor && called: ^squad-pr-watch conflicts-check issue-shop-1`
2. [記録] 人間を呼ばず、返事の待ちを登録してレビューと QA へ回している。 `判定: not-posted: mention://member/member1 && called: ^squad-review-wait watch issue-shop-1 comment-3 && posted: mention://agent/agent-qa && posted: mention://agent/agent-(code|ux|security|performance)-reviewer && not-called: ^squad-pr-link`
