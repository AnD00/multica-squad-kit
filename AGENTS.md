# リポジトリの指示

このファイルは `and00/multica-squad-kit` の作業の入口です。既存の決まりの詳細は、リンク先の正本を読みます。必要な指示や検証手順が未記入なら、推測で補わず不足を伝えます。

## プロジェクト概要

SquadKit は、Multica のスクワッドをプロジェクトごとに導入・更新するための原本です。利用者は、導入・更新する人、導入したプロジェクトの担当、原本を変える人です。対応する OS・ランタイムと対象外の範囲は、[README.md の対応する範囲](README.md#対応する範囲)を参照します。

設計の入口は [docs/](docs/) です。導入・更新の動作と操作は [manual.md](manual.md)、拡張との契約は [EXTENSIONS.md](EXTENSIONS.md)、役のひな形の形式は [common/agents/FORMAT](common/agents/FORMAT) が正本です。これらの契約を変えるときは、影響する利用者と互換性を設計に記し、人間の承認を受けます。

## 構成

原本の処理、配布するひな形、検証を次の場所に分けています。

| ファイル・ディレクトリ | 役割 |
| --- | --- |
| `setup.sh`、`lib/` | 質問、回答、ホスト準備、Multica への登録と導入の確認 |
| `common/` | 役・スクワッド・オートパイロット・共通スキルの原本、関所、見張り、シェルと Codex の設定 |
| `skeleton/` | 導入先で記入するリポジトリの指示、作業別のルール、プロジェクトの説明、検証スキルのひな形 |
| `vm/` | Lima・WSL の VM とゲストの準備・起動・確認 |
| `tests/` | シェルのテスト、CLI のスタブ、Python・PowerShell の補助 |
| `scripts/` | 構文確認、MANIFEST の生成、タグと Release の公開 |
| `.github/` | CI と PR テンプレート |
| `docs/` | 機能ごとの設計と判断の理由 |
| `VERSION`、`CHANGELOG.md`、`MANIFEST` | 配布する版、変更点、原本のファイル一覧とハッシュ |

`setup.sh` が `lib/` を読み、`common/` と `skeleton/` を条件と値で展開します。展開結果を Multica とホストに配置し、VM のスクリプトはゲスト内でセットアップを流します。外部との接続は `multica`・`gh` などの CLI を使い、テストではスタブに置き換えます。

## 作業の進め方と守ること

[CONTRIBUTING.md](CONTRIBUTING.md) が、変更の進め方・テスト・文書の改行・配布の正本です。承認された設計と依頼の範囲で作業し、設計を変える必要があれば実装を止めて人間に確認します。

セットアップで配置・登録される内容は、このリポジトリの原本を直します。`MANIFEST` は直接編集せず、[MANIFEST と混入の検査](CONTRIBUTING.md#manifest-と混入の検査)に従って生成します。認証情報、秘密の Webhook URL、混入検査の非公開の一覧をリポジトリや報告へ書きません。

hooks が自動で動くと仮定せず、完了の条件を自分で確かめます。マージ、タグと Release の公開、VM の実機確認は人間が行います。

## 作業別のルール

変更するファイルに当てはまるルールを、作業前にすべて読みます。対象の glob は各ルールの `paths` に記しています。

| 作業 | 対象 | ルール |
| --- | --- | --- |
| セットアップ・配布する原本・VM・CI を変える | `setup.sh`、`lib/**`、`scripts/**`、`common/**`、`vm/**`、`.github/workflows/**` | [コード](.agents/rules/code.md) |
| テストとその補助を変える | `tests/**` | [テスト](.agents/rules/tests.md) |
| 文書・指示・ひな形を変える | `**/*.md`、`common/agents/FORMAT`、`skeleton/**` | [ドキュメント](.agents/rules/docs.md) |

## 完了の条件

すべての変更で、[変更の進め方](CONTRIBUTING.md#変更の進め方)の検証を行います。実行する場所・道具・コマンド・例外・片付けは、プロジェクトの検証スキル `squadkit-verify` の `and00/multica-squad-kit` の節に従います。別のリポジトリの手順は流用しません。

実行したテストと構文確認は終了コード 0、MANIFEST は生成後にコミットした内容との差分がないことを合格の基準にします。Markdown を変えたときは markdownlint も通します。文書のパス・リンク・コマンドは実際の対象と照合します。

未実行・失敗・手順の未記入を成功として報告しません。検証スキルに定めた例外は、理由と CI で確かめる項目を報告します。VM の実機確認とリリース前の判断は、[バージョンを出す前に VM で確かめる](CONTRIBUTING.md#バージョンを出す前に-vm-で確かめる)に従います。

## Git と成果物

変更はブランチにコミットして push し、draft PR と実際に流した検証結果を渡します。既存の設計 PR があるときは同じブランチに積みます。PR の本文は [.github/pull_request_template.md](.github/pull_request_template.md) の見出しに従います。

コミットには変更した動作と理由を書きます。作業番号や進行の記録は Multica の課題に置き、PR 本文と引き継ぎは `squad-handoff` に従います。タグを動かさず、公開済みの版の修正は新しい版で配ります。[タグと Release を出す](CONTRIBUTING.md#タグと-release-を出す)操作は人間に渡します。
