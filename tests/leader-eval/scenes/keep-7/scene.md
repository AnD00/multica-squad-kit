- 場面の ID: keep-7
- 型: 保

## 元の出来事

実装がすべてそろったとき、CI の見張りを登録し、依頼は `squad-review-next request` に書かせる。観点を選び、返事を待つ回を作って、返事を待つ役とコミットの行のある依頼を書くのはスクリプトで、リーダーは役を選ばず、依頼の文も自分で書かない。

## 入力

あなたは、スクワッドのリーダーとして起こされました。きっかけは、タスク `issue-shop-1`（SHOP-1「カートに商品数を出す」）に実装の役が書いたコメント `comment-3` です。返信するときは `--parent comment-3` を使ってください。

コメントの本文: 「最後のフェーズを push しました。PR は `https://github.com/example/shop/pull/7` です。承認済みのフェーズは全部そろい、単体テストも通っています。レビューと E2E をお願いします。」

PR はタスクに紐付いています。画面に触れる変更なので、レビューと QA の E2E が必要です。返事を待つ回と、PR に触れる実行はありません。タスクにラベル `重要` はなく、重要の新しい判断の時機でもありません。

## 合格の基準

1. [記録] PR の紐付けを確認し、CI の見張りを登録している。 `判定: called: ^squad-pr-watch link-check issue-shop-1 && called: ^squad-pr-watch ci issue-shop-1 agent-ci-monitor comment-3`
2. [記録] 依頼を、PR の head の完全な SHA を渡した `squad-review-next request` で書かせている。 `判定: called: ^squad-review-next request issue-shop-1 comment-3 3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567$`
3. [記録] 返事の待ちの見張りも依頼のコメントも、自分では作っていない。 `判定: not-called: ^squad-review-wait watch && not-posted: ^返事を待つ役: && not-posted: ^確認するコミット:`
