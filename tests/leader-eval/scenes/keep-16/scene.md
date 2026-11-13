- 場面の ID: keep-16
- 型: 保

## 元の出来事

待っているタスクを修正へ回すときは、先に CI の待ちを解除する。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` のコメント `comment-final` で起きました。返信は `--parent comment-final` を使います。PR は `https://github.com/example/shop/pull/7` で、タスクに紐付いています。設計と全フェーズは承認・実装済みです。レビューと E2E は今の head `3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567` でそろい、❌ はありません。

CI を待っていますが、追加のレビューで必須の指摘が 1 件届きました。指摘はコードの直しで対応でき、設計の変更は要りません。修正の依頼は今回が 1 回目です。Claude の枠が上限なので、Codex の修正の役へ回してください。

## 合格の基準

1. [記録] 修正依頼の前に待ちを解除する。 `判定: called: ^squad-pr-watch ci-wait-clear issue-shop-1$ && before: ^squad-pr-watch ci-wait-clear => ^multica issue comment add`
2. [記録] 有効な修正の役へ、回数を添えて依頼する。 `判定: posted: mention://agent/agent-codex-fixer && posted: ^修正の依頼: 1 回目$`
3. [記録] 人間のマージへ進めない。 `判定: not-posted: mention://member/member1 && not-called: ^multica issue status .* in_review`
