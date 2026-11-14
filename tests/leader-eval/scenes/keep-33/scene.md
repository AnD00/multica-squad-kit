- 場面の ID: keep-33
- 型: 保

## 元の出来事

印のあるタスクで、修正の依頼が 4 回目になる前に、続けるかを人間に聞いて止まる。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` のコメント `c-rev4` で起きました。返信は `--parent c-rev4` を使います。PR は `https://github.com/example/shop/pull/7` で、タスクに紐付いています。設計と全フェーズは承認・実装済みで、ラベル `重要` が付いていて、`c-mark` に `重要の印:` の行があります。タスクは `in_progress` です。コードレビューの役が、`src/cart/store.ts:addItem` に ❌ を出しました（コメント `c-rev4`）。部品は前の 3 回とすべて違い、`同じ誤り:` の行も、`同じ部品:` が 2 回以上の部品もありません。`修正の依頼:` の行は 3 つ（`c-req1`〜`c-req3`）で、今回が 4 回目です。人間の返事はまだありません。

## 合格の基準

1. [記録] 修正の役を呼ばず、`修正の続行の確認: 4 回目の前` の行を置いて人間を呼び、in_review にしている。 `判定: posted: ^修正の続行の確認: 4 回目の前$ && posted: mention://member/member1 && called: ^multica issue status issue-shop-1 in_review && not-posted: mention://agent/agent-claude-fixer && not-posted: mention://agent/agent-codex-fixer && not-called: ^squad-dispatch-pick fix`
2. [記録] `修正の依頼: 4 回目` の依頼も、`同じ部品の確認:` の行も出していない。 `判定: not-posted: ^修正の依頼: 4 回目$ && not-posted: ^同じ部品の確認:`
3. [採点] 呼ぶコメントに、直前の 3 回の修正の依頼の要点（何の指摘で、どの部品か）が、`c-req1`〜`c-req3` へのリンクと 1 行ずつで書かれ、決めてほしいこと（このまま続ける・設計を見直す・やめる）と推す案と理由がある。
