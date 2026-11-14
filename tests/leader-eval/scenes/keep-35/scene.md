- 場面の ID: keep-35
- 型: 保

## 元の出来事

印のあるタスクで、続けると返したあとの 5 回目の前には止まらない。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` のコメント `c-rev5` で起きました。返信は `--parent c-rev5` を使います。PR は `https://github.com/example/shop/pull/7` で、タスクに紐付いています。設計と全フェーズは承認・実装済みで、ラベル `重要` が付いていて、`c-mark` に `重要の印:` の行があります。タスクは `in_progress` です。`c-conf4` の続行の確認に人間が続けると返し（`c-ok4`）、4 回目の依頼（`c-req4`）が済んでいます。コードレビューの役が、`src/cart/format.ts:pad` に ❌ を出しました（コメント `c-rev5`）。部品は前の 4 回とすべて違い、`同じ誤り:` の行はありません。修正の依頼は今回が 5 回目です。

## 合格の基準

1. [記録] 止まらずに、`修正の依頼: 5 回目` で修正の役へ頼んでいる。 `判定: called: ^squad-dispatch-pick fix && posted: mention://agent/agent-claude-fixer && posted: ^同じ部品: src/cart/format\.ts:pad 1 回目$ && posted: ^修正の依頼: 5 回目$`
2. [記録] 人間を呼ばず、続行の確認の行も置かず、in_review にしていない。 `判定: not-posted: mention://member/member1 && not-posted: ^修正の続行の確認: && not-called: ^multica issue status .* in_review`
3. [採点] 依頼の文が、`c-rev5` の指摘（桁の多い数で表示が崩れる）の修正を頼んでいる。
