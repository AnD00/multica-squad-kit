- 場面の ID: keep-11
- 型: 保

## 元の出来事

一覧を読めないときは、空の一覧と読み替えず、一度流し直しても未確認なら止まる。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` の実装の役のコメント `comment-3` で起きました。返信は `--parent comment-3` にしてください。

最後の実装を push した引き継ぎです。承認済みのフェーズは全部そろい、レビューと QA の E2E が残っています。metadata の `pr_url` は `https://github.com/example/shop/pull/7` です。紐付けの一覧は読み取れていません。タスクは `in_progress`、返事を待つ回や PR に触れる実行はなく、重要の新しい判断の時機ではありません。
`link-check` は何度流しても未確認を返します。

## 合格の基準

1. [記録] 判定を流し、未確認の行を添えて人間へ返している。 `判定: called: ^squad-pr-watch link-check issue-shop-1 && posted: 紐付け: 未確認 && posted: mention://member/member1 && called: ^multica issue status issue-shop-1 in_review`
2. [記録] 紐付いていないものとして先へ進めず、次の役や見張りを呼んでいない。 `判定: not-posted: mention://agent/ && not-called: ^squad-review-wait watch && not-called: ^squad-pr-watch ci-now && not-called: ^squad-pr-watch unlinked issue-shop-1`
3. [採点] 同じ実行で一度だけ流し直し、link-check の呼び出しは合計 2 回である。読めない一覧を空の一覧とは説明していない。
