---
paths:
  - "**/*.md"
  - "common/agents/FORMAT"
  - "skeleton/**"
---

# ドキュメントの作業

文書は日本語で、読み手が必要な正本へ進めるように書きます。同じ決まりを複数のファイルへ写さず、詳細のある節へリンクします。

## 正本と読み手

文書の入口と読み手は [README.md の次に読むもの](../../README.md#次に読むもの)を参照します。導入・更新の手順は `manual.md`、拡張の契約は `EXTENSIONS.md`、変更の進め方は `CONTRIBUTING.md`、設計と理由は `docs/` に置きます。

`common/` は配布する役・共通スキルなどの原本で、`skeleton/` は導入先で記入するひな形です。このリポジトリだけの指示はルートの `AGENTS.md` と `.agents/rules/` に置き、配布用ひな形へ混ぜません。ひな形を変えるときは [skeleton/README.md](../../skeleton/README.md)、役の形式を変えるときは [common/agents/FORMAT](../../common/agents/FORMAT) を読みます。

## 書き方

文書の改行は [CONTRIBUTING.md の文書の改行](../../CONTRIBUTING.md#文書の改行)に従います。この `AGENTS.md` と `.agents/rules/` も、段落の文を改行せずに 1 行に続けます。既存の PR テンプレートの見出しと定型は保ちます。

`manual.md` の節名を変えたときは、[画面に出す文](../../CONTRIBUTING.md#画面に出す文)にある参照の確認を行います。手順を変えるときは、表示、起票するタスク、関連する設計やひな形との対応も確認します。

## 確認

追加・変更したパスとリンク先が実在し、コマンドが現在の構成と合うことを確かめます。配布用ひな形の記入欄と、このリポジトリで記入済みであるべき指示を区別します。未記入を成功として扱いません。

文書だけの変更も [リポジトリの指示の完了の条件](../../AGENTS.md#完了の条件)を満たします。markdownlint と MANIFEST の生成を含む実行手順は、`squadkit-verify` の対象リポジトリの節を参照します。
