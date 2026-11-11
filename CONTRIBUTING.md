# 変更の進め方

原本への変更は PR にし、人のレビューと CI を通す。  
マージ、配るタグの作成と移動の判断は人間が行う。

エージェントは draft PR と検証結果を渡す。  
タグは動かさず、修正は新しいタグにする。

変更はブランチに積んで PR にする。  
PR を出す前に、原本のルートで次を流す。

```bash
bash scripts/check.sh
bash scripts/manifest.sh
bash tests/run.sh tests/webhooks-test.sh     # 関連テスト。選び方は下に書く
npx markdownlint-cli2 '**/*.md' '#tmp/**'    # Markdown を変えたとき
SQUAD_KIT_FORBIDDEN_FILE=/path/outside/terms.txt bash tests/check-content.sh
```

手元では、変更の大きさによらず、構文の確認、MANIFEST の作り直し、関連テスト、Markdown を変えたときの markdownlint を流す。  
テストの全件は、PR の CI が macOS と Ubuntu で流す。

関連テストは、変えたテストのファイルと、変えたファイルの名前（パスの最後の部分）を含むテストのファイルである。  
`MANIFEST` は、作り直すと毎回変わるので、変えたファイルに数えない。  
`README.md`、`manual.md`、`CONTRIBUTING.md` を変えたときは、`tests/doc-lines-test.sh` も流す。  
関連テストが 1 本も選べないときは、選べなかったことを PR の確認に書き、CI で確かめる。

次のどれかに当たるときは、関連テストの代わりに、手元で `bash tests/run.sh` の全件を流す。

| 条件 | 当たるファイル |
| --- | --- |
| テストの仕組み | `tests/run.sh`、`tests/run-one.sh`、`tests/run-hook.sh` |
| 多くのテストが共有するスタブと補助 | `tests/` の直下で、名前に `fixture` か `lib` を含み、`-test.sh` で終わらないファイル。`tests/fixtures/` の下のすべて |
| 多くのテストが読む共通の部品 | `setup.sh`、`lib/ui.sh`、`lib/check.sh`、`lib/project.sh`、`lib/render.sh`、`common/monitor/squad-cli-lib` |
| CI の定義 | `.github/workflows/` の下のすべて |
| 数と自信 | 関連テストが 10 本を超えるとき。または、選び方に自信が持てないとき（名前を含まずに読み込まれるファイルを変えたときなど） |

手元で流さなかった全件は、PR の確認に「CI で確かめる」と書く。  
エージェントは、検証スキルの同じ条件に従う。  
条件を変えるときは、検証スキルとそろえる。

## 原本と正本

原本は、この配布するキット（`multica-squad-kit` とそのファイル）だけを指す。  
正本は、決まりや情報の拠り所になる一つの場所を指す。  
正本は、原本の中にも、導入先のプロジェクトにもある。

文書や指示で「原本」と書くのは、このキットを指すときだけにする。  
決まりや情報の拠り所を指すときは「正本」と書く。

## テストを流す

`bash tests/run.sh` は、`tests/*-test.sh` を並べて流す。  
すべて通れば 0、1 本でも失敗すれば 1 で終わる。  
手元では、[変更の進め方](#変更の進め方)に従って関連テストを選んで流す。  
全件は CI が流す。

```bash
bash tests/run.sh                            # 並べて流す
SQUAD_KIT_TEST_JOBS=4 bash tests/run.sh      # 並列数を 4 にする
SQUAD_KIT_TEST_JOBS=1 bash tests/run.sh      # 1 本ずつ流す
bash tests/run.sh tests/project-create-test.sh   # 選んだファイルだけ流す
SQUAD_KIT_TEST_SHARD=2/4 bash tests/run.sh   # 4 つに分けた 2 つ目だけ流す
```

並列数は、指定しなければ論理 CPU の数になる。  
1 本ずつ流しても、起こす順と出力は並べたときと同じで、途中で失敗しても最後まで流す。  
並べたときだけ失敗するかを確かめるときに使う。

CI は、テストをシャードごとのジョブに分けて流す。

失敗したファイルのログは最後にまとめて出て、失敗した場所と直前に通ったケースが添えられる。  
流している間の出力を見たいときは、`bash tests/project-create-test.sh` のようにファイルを直接流す。

仕組みは、`tests/run.sh` の冒頭のコメントを参照する。

### コンフリクトを解消したときに流すテスト

コンフリクトを解消したときは、テスト全体を手元で流さず、関わるテストだけを流す。  
テスト全体は CI で確かめる。

関わるテストは、衝突したファイルと PR が変えたファイルのそれぞれについて、次の和にする。

1. 変えたテストのファイル（`tests/*-test.sh`）そのもの
2. ファイルの名前から拡張子を除いた語を含むテストのファイル（`grep -lF -- <語> tests/*-test.sh`）
3. テストの補助（`tests/*-lib.sh` など）を変えたときは、それを読み込むテストのファイル。2 の探し方で当たる

テストは、確かめるスクリプトや文書を名前で読むので、名前で探せば当たる。  
どれにも当たらないファイルは、関わるテストがないと報告し、CI で確かめる。

選んだファイルを流し、あわせて静的な確認と `MANIFEST` の確認を流す。

```bash
bash tests/run.sh <選んだファイル>
bash scripts/check.sh
bash scripts/manifest.sh && git diff --exit-code -- MANIFEST
```

### テスト 1 本ごとの時間の上限

`tests/run.sh` は、テストのファイル 1 本に 300 秒の上限を設ける。  
超えたファイルは、`done TIMEOUT <ファイル> <上限>s` を出して止め、時間切れの失敗として扱う。  
上限は、環境変数 `SQUAD_KIT_TEST_TIMEOUT` に秒数で指定して変えられる。

```bash
SQUAD_KIT_TEST_TIMEOUT=600 bash tests/run.sh tests/release-test.sh   # 上限を 600 秒にする
```

止まったテストは、流し直さずに失敗として扱う。  
流し直しても通るなら、並べたときだけ起きる不具合や、負荷による遅れを隠すため。  
原因を直すか、テストのファイルを分ける。

### テストを書く決まり

テストは、ファイルごとに別の `HOME` と `TMPDIR` で流れる。  
テストのファイルは、次を守る。

- 一時ファイルとディレクトリは、置き場所を明示して作る。
  - `tmp/` の下に `mktemp -d` で作った自分のディレクトリか、`mktemp "$TMPDIR/名前.XXXXXX"` のように `TMPDIR` の下に作る。
  - 置き場所を指定しない `mktemp` と `mktemp -t` は使わない
- `HOME` の下の利用者の設定に頼らない。
  - Git の名前とメールが要るときは、`git -c user.name=… -c user.email=…` で渡す
- 原本の `tmp/` 以外のファイルを書き換えない。
  - 決まった名前のファイルを共有の場所に作らず、プロセスを名前で止めない
- テストのファイルを足したら、`tests/test-weights` に重み（macOS の CI での秒数の目安）を書く。
  - 重みのないファイルがあると `tests/test-runner-test.sh` が失敗する。分けたファイルを足したときと、CI の秒数が目安から 2 倍以上ずれたときは、`tests/run.sh` の `==== PASS` の行の秒数を写して直す
- CLI の出力のデータは実物から取る。取り方とバージョンの記録は [CLI の実物の見本](tests/fixtures/cli/README.md)に従い、CLI のバージョンを上げたら取り直す
- 見張りが読む欄は、先に `common/monitor/squad-cli-lib` の約束に必須・条件付き・省略可能の分類を書く。`// 既定値` や `--compact` で欄の欠けを隠さない
- 見張りのテストは、整形の前と後で同じ動作になることを確かめる。終了コード・標準出力・CLI のコマンドと引数を比べる

## テストで確かめる範囲

自動テストで確かめる範囲は、macOS と Ubuntu 24.04 のセットアップ・再実行、導入の確認、Webhook の登録・配信確認、起票、関所の許可と拒否、見張り、シェル設定と時刻の読み取り、VM を作るスクリプトの引数と閉じ込めの設定である。  
実行の始めの確認と、ランタイムのコマンドの組み立てをまねた PATH の復元も確かめる。  
入口のスクリプト（`install.sh`）の確かめと展開、README の 1 行のコマンドの擬似端末での実行、配布物を作るスクリプト、発行のコマンド（`scripts/release.sh`）、発行のワークフローの定義の決まりも確かめる。  
CI でも両 OS に同じテストを流す。  
外部 CLI とサーバー、`limactl` と `wsl.exe` はスタブを使う。  
発行のワークフローの実行と、本物の GitHub での証明の確かめは、最初のバージョンを出すときに人が確かめる。

認証済みのデーモン・ランタイムの実行と、WSL 実機の動作は、VM を使わない普段のユーザーでは未確認である。  
WSL 2 は Linux との互換性と各ツールの公式対応に基づく対応である。

Mac の Lima の VM と WSL の専用のディストリは、[バージョンを出す前に VM で確かめる](#バージョンを出す前に-vm-で確かめる)で人が実機で確かめる。

## 画面に出す文

セットアップの画面に出す文は、`manual.md` の[表示の色と印](manual.md#表示の色と印)の種類のどれかに当てる。  
色の制御文字を直接書かず、種類ごとの色と、色を付けるかの判定を一か所にまとめた `lib/ui.sh` の関数で出す。

印（`質問`、`警告:`、`エラー:`）は、色の有無によらず同じ文字を出す。  
コマンド置換で受け取る文や、タスク・答え・ログに入る文は、色を付けずに作る。

色の判定は `tests/ui-test.sh` で、疑似端末と、色を付けない各条件の両方を確かめる。

`lib/` やエージェントの指示は、`manual.md` の節を名前やリンクで指している。  
節の名前を変えるときは、`grep -rn 'manual.md' .` で参照を探して合わせる。

起票するタスクの本文（`common/setup-issues.json`）は、取り出したタグの `manual.md` の節へリンクする。

## 文書の改行

`README.md`、`manual.md`、`CONTRIBUTING.md` の段落は、1 行に 1 文で書く。  
同じ段落の途中の行は、末尾に半角空白 2 つを付けて改行し、段落の最後の行には付けない。  
箇条書き、番号付きの項目、表のセルは、1 項目に複数の文を続けてよい。

ほかの文書（`EXTENSIONS.md`、`CHANGELOG.md`、`docs/`、`skeleton/`、`common/`）は、段落の文を改行せずに 1 行に続ける。

3 つの文書の段落は、`tests/doc-lines-test.sh` で確かめる。  
括弧（「」、（））とバッククォートの中の「。」は、文の終わりに数えない。

## MANIFEST と混入の検査

`MANIFEST` はファイル不足と改変を、登録前に検出するために残す。  
変更したらスクリプトで作り直す。

CI は同じ生成をして差分がないか確かめる。  
Git の管理領域と `tmp/` は一覧から除く。

混入の検査の一覧は、公開リポジトリに置かない。  
管理者が Repository Secret `FORBIDDEN_TERMS` に一行一語で設定する。

CI は一時ファイルへ渡し、値や検出した行を表示しない。  
一覧が空のときは失敗する。

fork の PR には Secret が渡らないので、信頼できる内容を管理者が確認して同じリポジトリのブランチへ取り込み、検査を通す。  
未確認の PR のコードに Secret を渡さない。

## バージョンを出す前に VM で確かめる

VM を作るスクリプト（`vm/lima.sh` と `vm/wsl.ps1`）と、中で流すセットアップは、スタブを使う自動テストでは、実機の動作を確かめきれない。  
バージョンを出す前に、人が Mac と Windows の実機で次を確かめ、結果をバージョンを上げる PR に書く。

`manual.md` の「閉じ込めて動かす」の手順を使う。  
まだタグがないバージョンを確かめるので、中では確かめるコミットを取り出して `bash setup.sh --no-checkout` で流す。

1. スクリプトで VM を作り、中でセットアップを最後まで流す
2. 中のエージェントが、許したリポジトリの checkout と PR の作成までできる。関所のディレクトリを含まない PATH でセットアップの外からデーモンを起動し直した状態でも、Claude と Codex のエージェントの実行で `command -v gh` が関所の `gh` を返し、`squad-dispatch-pick`・`squad-pr-watch`・`squad-review-wait` が名前で解決する
3. `verify` が通る。中で MySQL のコンテナを立てたあとも通る
4. VM を止めて起動し直し、中に入らずに、デーモンがオンラインになってタスクが動く。WSL では、窓をすべて閉じたあとも動く
5. VM を消したあと、ホストのホームに、セットアップが書いたファイル（`~/.multica-agent`、`~/.multica`、`~/multica_workspaces`）がない

Mac は Lima、Windows は WSL の専用のディストリで、それぞれ確かめる。  
片方の実機が使えないときは、確かめなかった側と理由を PR に書き、そのままバージョンを出すかを人が決める。

## タグと Release を出す

人間が、バージョンを上げる PR のマージのあとに、原本のリポジトリのルートで次を流す。  
タグの名前は `VERSION` から読む。  
`gh` は 2.102.0 以上が要る。

```bash
git switch main
git pull --ff-only origin main
bash scripts/release.sh
```

コマンドは、公開の前に、バージョン、タグを付けるコミット、Release の本文（`CHANGELOG.md` のそのバージョンの節）を出して、確認を求める。  
確認は端末で答えるので、端末から流す。  
パイプや自動の実行では、公開されない。

`y` を答えたときだけ、注釈付きのタグを作って `origin` に push し、下書きの Release を作る。  
そのあと、配布物を作るワークフローの終わりを待ち、配布物と証明を確かめて、確かめが通ったときだけ公開する。

止まったときは、出た理由に従って直してから、流し直す。  
未公開のコミットがあるときや、`VERSION` と `CHANGELOG.md` の先頭のバージョンが違うときは、変更を PR でレビュー・マージしてからやり直す。

下書きの作成、ワークフロー、公開のどこで失敗したときも、同じコマンドを流し直す。  
タグは作り直さず、続きから進む。

配布物の確かめで止まったときは、流し直さない。  
下書きの配布物を GitHub の画面で見て、差し替えられていないかを調べる。

発行済みのタグは動かさない。  
修正は新しいタグで配る。

### リポジトリの設定

README の 1 行のコマンドは、入口のスクリプト（`install.sh`）を確かめずに流す。  
入口は公開した Release にあるので、公開したあとに差し替えられると、そのまま流れてしまう。  
これを防ぐため、リポジトリの管理者が、公開したあとの Release の配布物とタグを差し替えられない次の 2 つを設定する。  
この変更を入れた最初のバージョンを出す前に行う。  
不変の Release は、有効にしたあとに公開した Release にだけ効くため。

| 設定 | 値 |
| --- | --- |
| Settings → Releases の「Enable release immutability」 | 有効にする |
| タグの ruleset（Target tags は `v*`） | 「Restrict updates」と「Restrict deletions」を有効にし、「Restrict creations」は付けない。bypass の一覧は空にする |

ruleset は、タグを作ることを止めない。  
`scripts/release.sh` が、タグを push できるようにするため。

設定のあと、最初のバージョンを出したら、公開済みの Release とそのタグが、差し替えられないことを確かめる。  
`V` には、公開したバージョンのタグを入れる。

```bash
V=v1.8.0
D=$(mktemp -d)
gh release download "$V" --repo AnD00/multica-squad-kit --pattern SHA256SUMS --dir "$D"
gh release upload "$V" "$D/SHA256SUMS" --repo AnD00/multica-squad-kit --clobber
git push --force origin "refs/tags/$V^{commit}:refs/tags/$V"
```

どちらも、拒まれれば設定が効いている。  
通ってしまったら、設定が効いていないので、直す。  
`git push` が通ったときは、`git push --force origin "refs/tags/$V:refs/tags/$V"` で、注釈付きのタグに戻す。
