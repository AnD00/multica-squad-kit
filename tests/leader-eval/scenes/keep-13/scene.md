- 場面の ID: keep-13
- 型: 保

## 元の出来事

最終レビューが通っても CI が未確認なら待つ。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` のコメント `comment-final` で起きました。返信は `--parent comment-final` を使います。PR は `https://github.com/example/shop/pull/7` で、タスクに紐付いています。設計と全フェーズは承認・実装済みです。レビューと E2E は今の head `3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567` でそろい、❌ はありません。

今の head の最終レビューは ✅ です。CI は未確認です。マージの依頼はまだありません。

## 合格の基準

1. [記録] CI の待ちを流す。 `判定: called: ^squad-pr-watch ci-wait issue-shop-1 agent-orchestrator comment-final`
2. [記録] 待っている状態を記録する。 `判定: posted: CI 3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567: 未確認`
3. [記録] 人間のマージへ進めない。 `判定: not-posted: mention://member/member1 && not-called: ^multica issue status .* in_review`
4. [記録] マージの依頼を出さない。 `判定: not-posted: ^マージの依頼: && not-posted: mention://agent/agent-.*principal`
