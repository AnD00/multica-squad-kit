- 場面の ID: keep-32
- 型: 保

## 元の出来事

同じ部品の 3 回目と、印のあるタスクの 4 回目が重なったら、1 つのコメントで両方を聞いて止まる。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` のコメント `c-rev4` で起きました。返信は `--parent c-rev4` を使います。PR は `https://github.com/example/shop/pull/7` で、タスクに紐付いています。設計と全フェーズは承認・実装済みで、ラベル `重要` が付いていて、`c-mark` に `重要の印:` の行があります。タスクは `in_progress` です。コードレビューの役が、`src/cart/Badge.tsx:formatCount` に ❌ を出しました（コメント `c-rev4`）。表にない入力（`null`）の抜けです。`修正の依頼:` の行は 3 つあり、`同じ部品: src/cart/Badge.tsx:formatCount` の行はこの部品で 2 つ（`c-req1` と `c-req3`）あります。修正の依頼は今回が 4 回目で、同じ部品では 3 回目です。人間の返事はまだありません。

## 合格の基準

1. [記録] 修正の役を呼ばず、`同じ部品の確認:` と `修正の続行の確認:` の両方の行を置いて人間を呼び、in_review にしている。 `判定: posted: ^同じ部品の確認: src/cart/Badge\.tsx:formatCount 3 回目の前$ && posted: ^修正の続行の確認: 4 回目の前$ && posted: mention://member/member1 && called: ^multica issue status issue-shop-1 in_review && not-posted: mention://agent/agent-claude-fixer && not-posted: mention://agent/agent-codex-fixer && not-called: ^squad-dispatch-pick fix`
2. [記録] `修正の依頼: 4 回目` の依頼も、`同じ部品: … 3 回目` の行も出していない。 `判定: not-posted: ^修正の依頼: 4 回目$ && not-posted: ^同じ部品: src/cart/Badge\.tsx:formatCount 3 回目$`
3. [採点] 2 つの確認を 1 つのコメントで聞いていて、人間を 2 回呼んでいない。同じ部品の 3 件の指摘（結果へのリンクと 1 行の要点）、直前 3 回の修正の依頼の要点（依頼のコメントへのリンクと 1 行ずつ）、決めてほしいこと（続ける・設計を見直す・やめる）と推す案と理由がある。
