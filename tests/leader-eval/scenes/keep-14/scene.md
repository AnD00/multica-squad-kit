- 場面の ID: keep-14
- 型: 保

## 元の出来事

待ちの規則で CI の成功を拾ったら、一度だけマージを頼む。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` のコメント `comment-final` で起きました。返信は `--parent comment-final` を使います。PR は `https://github.com/example/shop/pull/7` で、タスクに紐付いています。設計と全フェーズは承認・実装済みです。レビューと E2E は今の head `3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567` でそろい、❌ はありません。

CI 待ちの規則 `ci-wait-rule` で起きました。この規則は今の待ちの規則です。今の head の最終レビューは ✅ で、CI も成功しました。マージ依頼のコメントはまだありません。

## 合格の基準

1. [記録] 起きた規則の ID を渡す。 `判定: called: ^squad-pr-watch ci-wait issue-shop-1 agent-orchestrator comment-final ci-wait-rule$`
2. [記録] 成功を読んでからマージを依頼する。 `判定: before: ^squad-pr-watch ci-wait => ^multica issue comment add && posted: mention://member/member1`
3. [記録] 今の完全な head で依頼の行を残す。 `判定: posted: ^マージの依頼: 3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567$`
4. [採点] マージの依頼は、同じ head に 1 回だけである。
