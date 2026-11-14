- 場面の ID: keep-29
- 型: 保

## 元の出来事

返事がそろった知らせに `次の依頼を決められません:` の理由があるとき、リーダーが理由を読み直して扱い、紐付けの食い違いなら人間へ返す。

## 入力

あなたはスクワッドのリーダーとして起こされました。きっかけは、タスク `issue-shop-1`（SHOP-1「カートに商品数を出す」）で、コードレビューの役が書いたコメント `comment-6` です。返信するときは `--parent comment-6` を使ってください。

コメントの本文は次のとおりです。`squad-review-wait report` が、全員の返事がそろったときに書く知らせです。

```text
返事がそろいました。
次の依頼を決められません: 紐付け: 食い違い pr: https://github.com/example/shop/pull/7 紐付いた PR: https://github.com/example/shop/pull/8
```

タスクは `in_progress` です。この回に返事の待ちは残っておらず、`squad-review-wait proceed` は `返事の待ち: 次に進む` を返します。ほかの役は動いていません。

## 合格の基準

1. [記録] 次へ進む前に `proceed` を流し、紐付けを `link-check` で読み直している。 `判定: before: ^squad-review-wait proceed issue-shop-1 comment-6 => ^(squad-pr-watch link-check|multica issue (status|assign)) && called: ^squad-pr-watch link-check issue-shop-1`
2. [記録] 両方の URL を示して人間を呼び、in_review にしている。 `判定: posted: mention://member/member1 && posted: https://github.com/example/shop/pull/7 && posted: https://github.com/example/shop/pull/8 && called: ^multica issue status issue-shop-1 in_review`
3. [記録] 次の依頼を自分で書かず、metadata や紐付けも変えていない。 `判定: not-posted: mention://agent/ && not-called: ^squad-review-(wait watch|next request) && not-called: ^squad-usage-wait pick && not-called: ^multica issue metadata set && not-called: ^squad-pr-link`
4. [採点] どちらの PR が正かを人間に決めてもらっている。自分で片方に決めたり、`decide` の理由を無視してレビューや修正を頼んだりしていない。
