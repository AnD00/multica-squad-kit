- 場面の ID: keep-21
- 型: 保

## 元の出来事

マージ待ちの食い違いの知らせでは、判定を流し直してマージを止める。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` のマージ待ちの間に、CI の見張り役が書いた食い違いの知らせ `comment-6` で起きました。返信は `--parent comment-6` です。

タスクは `in_review` で、前回は人間にマージを頼んでいました。metadata の `pr_url` は `https://github.com/example/shop/pull/7` ですが、別の PR `https://github.com/example/shop/pull/8` が紐付きました。返事を待つ回も動いている役もありません。

## 合格の基準

1. [記録] 判定を流し直し、両方の URL を示して人間を呼んでいる。 `判定: called: ^squad-pr-watch link-check issue-shop-1 && posted: mention://member/member1 && posted: https://github.com/example/shop/pull/7 && posted: https://github.com/example/shop/pull/8`
2. [記録] in_review を保ち、修正や別のレビューへ回していない。 `判定: not-called: ^multica issue status issue-shop-1 (in_progress|done|cancelled) && not-posted: mention://agent/ && not-called: ^squad-review-(wait watch|next request) && not-called: ^multica issue metadata set`
3. [採点] マージを頼んだあとで食い違いが分かったことを説明し、どちらが正か決めるまでマージしないでほしいと頼んでいる。
