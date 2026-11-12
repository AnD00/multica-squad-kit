- 場面の ID: 保-6
- 型: 保

## 元の出来事

レビューと E2E の最後の 2 つの返事がほぼ同時に届き、リーダーの実行が 2 つ起きた。先に記録を書いた実行だけが次へ進み、もう一方は何もしなかった。

## 入力

あなたは、スクワッドのリーダーとして起こされました。きっかけは、タスク `issue-shop-1`（SHOP-1「カートに商品数を出す」）で、QA の役が書いたコメント `comment-6` です。返信するときは `--parent comment-6` を使ってください。

コメントの本文: 「返事がそろいました。」（`squad-review-wait report` が書く知らせです）。ほぼ同時に、レビューの役も同じ知らせを `comment-5` に書いています。

タスクの状態は `in_progress` です。別の実行が先に次へ回していて、`squad-review-wait proceed` は `返事の待ち: 回ごと済み` を返します。

## 合格の基準

1. [記録] 次へ進む前に、`squad-review-wait proceed` を流している。 `判定: before: ^squad-review-wait proceed issue-shop-1 comment-6 => ^(multica issue (status|assign)|squad-pr-watch|squad-dispatch-pick)`
2. [記録] `回ごと済み` のとき、コンフリクトの確認や状態の変更をせず、人間にもほかの役にもメンションしていない。 `判定: not-called: ^squad-pr-watch conflicts-check && not-called: ^multica issue (status|assign) && not-posted: mention://`
3. [採点] 何も進めず、`proceed` の結果（`回ごと済み`）をそのまま、最後の返答にしている。
