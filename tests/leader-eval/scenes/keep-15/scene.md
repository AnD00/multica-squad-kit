- 場面の ID: keep-15
- 型: 保

## 元の出来事

別のコメントで先にマージを頼んだあと、終わった規則から起きても重ねない。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` のコメント `comment-final` で起きました。返信は `--parent comment-final` を使います。PR は `https://github.com/example/shop/pull/7` で、タスクに紐付いています。設計と全フェーズは承認・実装済みです。レビューと E2E は今の head `3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567` でそろい、❌ はありません。

CI 待ちの古い規則 `old-ci-rule` で起きました。待ちの記録は解除済みです。ほかのコメントで起きた実行が、今の head の CI 成功を確認してマージを依頼済みです。

## 合格の基準

1. [記録] 古い規則の ID を渡して終了を確認する。 `判定: called: ^squad-pr-watch ci-wait issue-shop-1 agent-orchestrator comment-final old-ci-rule$`
2. [記録] 依頼も状態変更も重ねない。 `判定: not-posted: mention:// && not-posted: ^マージの依頼: && not-called: ^multica issue (status|assign)`
