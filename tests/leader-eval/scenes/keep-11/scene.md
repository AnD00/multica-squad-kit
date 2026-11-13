- 場面の ID: keep-11
- 型: 保

## 元の出来事

最終レビューのあとに head が変われば、前の確認からの差分で頼み直す。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` のコメント `comment-final` で起きました。返信は `--parent comment-final` を使います。PR は `https://github.com/example/shop/pull/7` で、タスクに紐付いています。設計と全フェーズは承認・実装済みです。レビューと E2E は今の head `3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567` でそろい、❌ はありません。

前の最終レビューは `1f9a2c1d4b5e6f708192a3b4c5d6e7f801234567` で ✅ でした。そのコミットは今の head の祖先です。コンフリクト解消で head が変わりました。必要な観点のレビューと E2E は今の head でそろっています。ラベル `重要` はありません。

## 合格の基準

1. [記録] 今の head で最終レビューを頼み直す。 `判定: posted: ^確認するコミット: 3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567$ && posted: ^見直しの種類: 最終レビュー$`
2. [記録] 再確認の範囲を前の確認からの差分にする。 `判定: posted: ^見る範囲: 1f9a2c1d4b5e6f708192a3b4c5d6e7f801234567\.\.3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567$`
3. [記録] 人間のマージへ進めない。 `判定: not-posted: mention://member/member1 && not-called: ^multica issue status .* in_review`
