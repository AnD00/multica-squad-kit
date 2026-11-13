- 場面の ID: keep-8
- 型: 保

## 元の出来事

印のないタスクにも最終レビューを頼み、失敗実行を系統の数に入れない。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` のコメント `comment-final` で起きました。返信は `--parent comment-final` を使います。PR は `https://github.com/example/shop/pull/7` で、タスクに紐付いています。設計と全フェーズは承認・実装済みです。レビューと E2E は今の head `3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567` でそろい、❌ はありません。

ラベル `重要` はありません。Claude の実装が 1 回成功し、Codex の修正は変更を残さず 2 回失敗しました。最終レビューはまだありません。

## 合格の基準

1. [記録] 最終レビューを、ほかの役と別の回で頼む。 `判定: called: ^squad-review-wait watch issue-shop-1 comment-final agent-codex-principal && posted: ^見直しの種類: 最終レビュー$ && posted: ^返事を待つ役:.*mention://agent/agent-codex-principal`
2. [記録] 初回は差分全体と今のコミットを指定する。 `判定: posted: ^見る範囲: PR の差分全体$ && posted: ^確認するコミット: 3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567$`
3. [記録] 人間のマージへ進めない。 `判定: not-posted: mention://member/member1 && not-called: ^multica issue status .* in_review`
4. [記録] 成功した実装の Claude と違う系統を選ぶ。 `判定: called: ^multica issue runs issue-shop-1 && called: ^squad-dispatch-pick principal Claude$ && not-called: ^squad-dispatch-pick principal Codex$`
