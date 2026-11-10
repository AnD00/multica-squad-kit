# multica-squad-kit

Multica のスクワッドを、プロジェクトごとに導入して更新するための原本です。  
`bash setup.sh` で質問に答えると、役ごとのエージェント、スクワッド、オートパイロット、共通スキル、ホストの関所と見張りがそろいます。  
人間に残る作業は、対象のプロジェクトに issue として起票されます。

## 必要なもの

- macOS か Linux（WSL 2 を含む）の、導入する人のアカウント
- `multica`、`jq`、`gh`、Python 3.11 以上、Git などの標準の道具
- エージェントのランタイムとして、`claude`（Claude Code）と `codex` の一方または両方
- 導入先の Multica のワークスペースと、そこで GitHub 連携を許可したプロジェクトのリポジトリ

詳しい条件と Linux での入れ方は [受け取る人の準備](manual.md#受け取る人の準備) にあります。

## クイックスタート

1. 道具を入れて、Multica と GitHub にログインします。Claude Code と Codex は、利用する組織の手順で入れます。macOS の例です。

   ```bash
   brew install multica-ai/tap/multica jq gh python
   multica login
   gh auth login
   ```

2. 原本を clone し、[Releases](https://github.com/AnD00/multica-squad-kit/releases) の最新のタグを取り出して、セットアップを流します。`<tag>` は使うタグの名前に置き換えます。

   ```bash
   git clone https://github.com/AnD00/multica-squad-kit.git
   cd multica-squad-kit
   git fetch origin --tags
   git checkout --detach <tag>
   bash setup.sh
   ```

3. 質問に答えます。最初の拡張のディレクトリは、使わなければ Enter です。ワークスペースは番号で選び、ほかは既定値でよければ Enter で進めます。最後に答えの一覧を確かめて `yes` と答えます。各質問の意味は [質問への答え方](manual.md#質問への答え方) にあります。
4. エージェント用のログインが済んでいないと、セットアップは止まってログインのコマンドを表示します。表示どおりにログインして、同じコマンドを流し直します。
5. 完了の表示で、導入の確認と起票した issue を確かめます。起票された「プロジェクトの説明と検証スキルを記入する」と「スクワッドの動きを試す」を先に片付け、終わったら「OWNER/REPO に AGENTS.md と作業別のルールを置く」を todo にしてスクワッドへ渡します。

完了の表示と起票される issue の一覧は [導入後に自動で行うことと、起票する issue](manual.md#導入後に自動で行うことと起票する-issue) にあります。

## 更新する

新しいタグを取り出して、同じ答えでセットアップを流し直します。  
前回の答えが既定になるので、ワークスペースの番号のほかは Enter で進められます。  
途中で止まったときも、直してから同じように流し直します。

```bash
git fetch origin --tags
git checkout --detach <tag>
bash setup.sh
```

新しい版の通知を受けるには、GitHub でこのリポジトリの Watch を「Custom」の「Releases」にします。  
詳しくは [更新と、途中で止まったあとの再実行](manual.md#更新と途中で止まったあとの再実行) を参照してください。

ZIP で導入済みの場合は、人がその関所・見張り・シェル設定と、対象プロジェクトの保存済み回答を消してから入れ直してください。  
回答の既定の保存先は `~/.multica-agent/template/answers/<workspace-id>/<project-key>.json` です。

対象の確認と手順は [導入済みの配布物を入れ直す](manual.md#導入済みの配布物を入れ直す) を参照してください。

## 次に読むもの

| 読む人 | 文書 |
| --- | --- |
| 導入・更新する人 | [導入と更新](manual.md)。準備から、質問の答え方、起票される issue、止まったときまで |
| 導入したプロジェクトの担当 | [プロジェクトごとの指示の書き方](skeleton/README.md)。起票された issue で記入するひな形 |
| プロジェクトの拡張を作る人 | [拡張の形式](EXTENSIONS.md) |
| この原本を変える人 | [変更の進め方](CONTRIBUTING.md)。設計の理由は [docs/](docs/) |
| 変更点を知りたい人 | [CHANGELOG.md](CHANGELOG.md) |

## 対応する範囲

macOS と Linux（WSL 2 を含む）、標準の bash・zsh、Claude Code と Codex の一方または両方、GitHub、日本語での利用に対応します。  
WSL 1、WSL を使わない Windows、英語、GitHub 以外は対象外です。

Webhook は既定では使わず、Dependabot の PR は週次のスケジュールだけで扱います。  
Dependabot の役を残して Webhook を使うと答えたときだけ、セットアップが Webhook を登録して配信を確かめます。

自動テストで確かめる範囲と、人が実機で確かめる範囲は [テストで確かめる範囲](CONTRIBUTING.md#テストで確かめる範囲) にあります。

## 閉じ込めて動かす

普段のユーザーでセットアップすると、エージェントはそのユーザーで動くので、ホームの SSH の鍵や、普段の `gh` と Git の認証も読めます。  
これを避けたいときは、軽い VM を作って、その中でクイックスタートを流します。

VM はホームを共有しないので、中のエージェントはホストのファイルを読めません。  
VM を消せば、ホストはセットアップの前に戻ります。  
ネットワークは閉じ込めません。

Mac は Lima 1.0.0 以上、Windows は WSL 2.6.1 以上を使い、原本の clone で次を流します。  
割くリソースの目安は、CPU 4、メモリ 8 GiB、ディスク 100 GiB です。

```bash
bash vm/lima.sh create
```

```powershell
powershell -ExecutionPolicy Bypass -File vm\wsl.ps1 create
```

中への入り方、止め方・消し方は [閉じ込めて動かす](manual.md#閉じ込めて動かす) に、設計は [docs/vm.md](docs/vm.md) にあります。
