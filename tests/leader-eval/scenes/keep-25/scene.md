- 場面の ID: keep-25
- 型: 保

## 元の出来事

待ちの規則で起きたとき、最新の待ちの記録に前の回があれば、`ci-wait` を直接流さず `decide` に任せる。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` のコメント `comment-final` で起きました。返信は `--parent comment-final` を使います。PR は `https://github.com/example/shop/pull/7` で、タスクに紐付いています。設計と全フェーズは承認・実装済みです。レビューと E2E は今の head `3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567` でそろい、❌ はありません。

CI 待ちの規則 `ci-wait-rule` で起きました。この規則は今の待ちの規則です。今の head の最終レビューは ✅ です。タスクのコメントに、最新の `マージの前の CI の待ち:` の記録 `ci-wait-note` があり、`前の回: principal-done` と書いてあります。マージ依頼のコメントはまだありません。

## 合格の基準

1. [記録] 前の回の ID と起きた規則の ID を渡して `decide` を流す。 `判定: called: ^squad-review-next decide issue-shop-1 principal-done ci-wait-rule$`
2. [記録] `ci-wait` を直接流さず、マージの依頼を自分で書かない。 `判定: not-called: ^squad-pr-watch ci-wait && not-posted: ^マージの依頼: && not-posted: mention://member/member1`
3. [採点] `decide` が出した `次の依頼:` の行（`マージの依頼`）を、最後の返答にしている。自分でマージの依頼や CI の確認を足していない。
