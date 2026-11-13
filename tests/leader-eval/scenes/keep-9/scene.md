- 場面の ID: keep-9
- 型: 保

## 元の出来事

文書だけの変更でも、設計した系統と違う系統へ最終レビューを頼む。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` のコメント `comment-final` で起きました。返信は `--parent comment-final` を使います。PR は `https://github.com/example/shop/pull/7` で、タスクに紐付いています。設計と全フェーズは承認・実装済みです。レビューと E2E は今の head `3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567` でそろい、❌ はありません。

文書だけの変更です。実装と修正の実行はありません。設計の役のモデルは gpt-6.1-sol です。ラベル `重要` と最終レビューの結果はありません。

## 合格の基準

1. [記録] 設計の役のモデルを確認し、Codex と違う系統を選ぶ。 `判定: called: ^multica agent get agent-designer && called: ^squad-dispatch-pick principal Codex$`
2. [記録] 文書の最終レビューを Claude の別の回で頼む。 `判定: called: ^squad-review-wait watch .*agent-claude-principal && posted: ^見直しの種類: 最終レビュー$ && posted: ^見る範囲: PR の差分全体$`
3. [記録] 人間のマージへ進めない。 `判定: not-posted: mention://member/member1 && not-called: ^multica issue status .* in_review`
