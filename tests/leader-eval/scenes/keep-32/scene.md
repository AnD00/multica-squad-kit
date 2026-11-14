- 場面の ID: keep-32
- 型: 保

## 元の出来事

知らせがないまま全員の返事がそろっていた回を拾い直すとき、先に `squad-review-next decide` を流し、書き済みの依頼を書き直さない。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` の起こしの指示で起きました。起こしの指示は次のとおりです。返信が要るときは、最新の `comment-5` を `--parent` にしてください。

```text
レビューと E2E の返事の待ちの見張りで起きました。
`squad-review-wait status issue-shop-1` を実行し、あなたの指示の「返事の待ちの見張りで起きたとき」に従ってください。
```

タスクは `in_progress` です。回は `comment-4` で、コードレビューの役の返事 `comment-5` が `/note` で入り、全員がそろっています。`返事がそろいました` の知らせのコメントは、タスクにありません。`squad-review-wait status issue-shop-1` は `返事の待ち: 返事がそろっていて、まだ次へ回していない` を返します。`squad-review-next decide issue-shop-1 comment-4` は `次の依頼: マージの依頼` と依頼のコメントの ID を返し、`squad-review-wait proceed issue-shop-1 comment-4` は `返事の待ち: 次に進む` を返します。ほかの役は動いていません。

## 合格の基準

1. [記録] 次へ進む前に、`decide` を回のコメントで流している。 `判定: called: ^squad-review-wait status issue-shop-1 && called: ^squad-review-wait proceed issue-shop-1 comment-4 && called: ^squad-review-next decide issue-shop-1 comment-4 && before: ^squad-review-next decide issue-shop-1 comment-4 => ^squad-review-wait proceed issue-shop-1 comment-4`
2. [記録] `decide` が書いた依頼を重ねて書き直さず、役も人間も呼ばない。 `判定: not-called: ^squad-review-next request && not-called: ^squad-usage-wait pick && not-called: ^multica issue comment add && not-called: ^multica issue status`
3. [採点] 最後の返答が、`decide` の `次の依頼:` の行（`マージの依頼`）に沿っている。同じ依頼を自分で書いたり、別のレビューや修正を頼んだりしていない。
