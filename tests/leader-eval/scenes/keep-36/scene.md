- 場面の ID: keep-36
- 型: 保

## 元の出来事

続けたあとも、3 回あとの 7 回目の前に、もう一度続けるかを聞いて止まる。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` のコメント `c-rev7` で起きました。返信は `--parent c-rev7` を使います。PR は `https://github.com/example/shop/pull/7` で、タスクに紐付いています。設計と全フェーズは承認・実装済みで、ラベル `重要` が付いていて、`c-mark` に `重要の印:` の行があります。タスクは `in_progress` です。4 回目の前の続行の確認（`c-conf4`）に人間が続けると返し（`c-ok4`）、5 回目と 6 回目の依頼（`c-req5`、`c-req6`）まで済んでいます。コードレビューの役が、`src/cart/Badge.tsx:render` に ❌ を出しました（コメント `c-rev7`）。部品は前の 6 回とすべて違い、`同じ誤り:` の行もありません。修正の依頼は今回が 7 回目です。7 回目の前の人間の返事はありません。

## 合格の基準

1. [記録] 修正の役を呼ばず、`修正の続行の確認: 7 回目の前` の行を置いて人間を呼び、in_review にしている。 `判定: posted: ^修正の続行の確認: 7 回目の前$ && posted: mention://member/member1 && called: ^multica issue status issue-shop-1 in_review && not-posted: mention://agent/agent-claude-fixer && not-posted: mention://agent/agent-codex-fixer && not-called: ^squad-dispatch-pick fix`
2. [記録] `修正の依頼: 7 回目` の依頼も、4 回目の続行の確認の置き直しも出していない。 `判定: not-posted: ^修正の依頼: 7 回目$ && not-posted: ^修正の続行の確認: 4 回目の前$`
3. [採点] 呼ぶコメントに、直前の 3 回（4 回目〜6 回目）の修正の依頼の要点が、`c-req4`〜`c-req6` へのリンクと 1 行ずつで書かれ、決めてほしいことと推す案と理由がある。
