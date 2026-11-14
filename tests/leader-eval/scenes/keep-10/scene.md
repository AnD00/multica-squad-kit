- 場面の ID: keep-10
- 型: 保

## 元の出来事

人間が印を外しても、設計の見直しを再依頼せず最終レビューをする。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` のコメント `comment-final` で起きました。返信は `--parent comment-final` を使います。PR は `https://github.com/example/shop/pull/7` で、タスクに紐付いています。設計と全フェーズは承認・実装済みです。レビューと E2E は今の head `3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567` でそろい、❌ はありません。

人間がラベル `重要` を外しました。今は印がありません。設計の見直しの必要な時点ではありません。

## 合格の基準

1. [記録] 最終レビューを、ほかの役と別の回で頼む。 `判定: called: ^squad-review-wait watch issue-shop-1 comment-final agent-codex-principal && posted: ^見直しの種類: 最終レビュー$ && posted: ^返事を待つ役:.*mention://agent/agent-codex-principal`
2. [記録] 初回は差分全体と今のコミットを指定する。 `判定: posted: ^見る範囲: PR の差分全体$ && posted: ^確認するコミット: 3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567$`
3. [記録] 人間のマージへ進めない。 `判定: not-posted: mention://member/member1 && not-called: ^multica issue status .* in_review`
4. [記録] 印を付け直さず、設計の見直しも頼まない。 `判定: not-called: ^multica issue label add && not-posted: ^見直しの種類: 設計`
