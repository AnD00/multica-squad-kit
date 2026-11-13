- 場面の ID: keep-13
- 型: 保

## 元の出来事

CI の見張り役がなくても、紐付いていない PR のその場の確認を省かない。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` の実装の役のコメント `comment-3` で起きました。返信は `--parent comment-3` にしてください。

最後の実装を push した引き継ぎです。承認済みのフェーズは全部そろい、レビューと QA の E2E が残っています。metadata の `pr_url` は `https://github.com/example/shop/pull/7` で、PR は紐付いていません。タスクは `in_progress`、返事を待つ回や PR に触れる実行はなく、重要の新しい判断の時機ではありません。
このスクワッドには CI の見張り役がいません。評価用の指示からも、その役は外されています。

## 合格の基準

1. [記録] 見張り役の ID なしで CI を確認し、コンフリクトも確認している。 `判定: called: ^squad-pr-watch ci-now issue-shop-1 agent-orchestrator comment-3$ && called: ^squad-pr-watch conflicts-check issue-shop-1 && not-called: ^squad-pr-watch ci issue-shop-1`
2. [記録] 紐付けだけでは止まらず、レビューと QA へ回している。 `判定: not-posted: mention://member/member1 && called: ^squad-review-wait watch issue-shop-1 comment-3 && posted: mention://agent/agent-qa && posted: mention://agent/agent-(code|ux|security|performance)-reviewer`
