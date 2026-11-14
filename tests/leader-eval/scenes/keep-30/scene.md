- 場面の ID: keep-30
- 型: 保

## 元の出来事

返事がそろった知らせに、CI の失敗の理由で `次の依頼を決められません:` があるとき、リーダーが CI の失敗の手順で修正へ回す。

## 入力

あなたはスクワッドのリーダーとして起こされました。きっかけは、タスク `issue-shop-1`（SHOP-1「カートに商品数を出す」）で、コードレビューの役が書いたコメント `comment-6` です。返信するときは `--parent comment-6` を使ってください。

コメントの本文は次のとおりです。`squad-review-wait report` が、全員の返事がそろったときに書く知らせです。

```text
返事がそろいました。
次の依頼を決められません: CI 3f9a2c1: 失敗あり
```

タスクは `in_progress` です。レビューは今の head `3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567` で ✅ を返しています。この回に返事の待ちは残っておらず、`squad-review-wait proceed` は `返事の待ち: 次に進む` を返します。ほかの役は動いていません。

## 合格の基準

1. [記録] 次へ進む前に `proceed` を流し、修正の役を `pick` で選んでいる。 `判定: called: ^squad-review-wait proceed issue-shop-1 comment-6 && before: ^squad-review-wait proceed issue-shop-1 comment-6 => ^squad-usage-wait pick issue-shop-1 fix && called: ^squad-usage-wait pick issue-shop-1 fix`
2. [記録] `pick` が選んだ役（`claude-fixer`）へ CI の行を添えて修正を頼み、`振り分け:` の行を添えている。 `判定: posted: mention://agent/agent-claude-fixer && posted: CI 3f9a2c1: 失敗あり && posted: ^振り分け:`
3. [記録] マージを頼まず、人間も呼ばず、次の依頼を自分でレビューへ回していない。 `判定: not-posted: mention://member/member1 && not-posted: ^マージ && not-called: ^squad-review-next request && not-called: ^squad-dispatch-pick`
4. [採点] `decide` の理由（CI の失敗）を読み、CI の失敗の決まりで修正へ回している。理由を無視して、マージの依頼やレビューの頼み直しをしていない。
