# GitHub Actions のサプライチェーン攻撃を防ぐ

原本のリポジトリの main と GitHub Actions を、乗っ取られたアクションや、外からの指示で動いたエージェントの変更から守る。この文書は、ワークフロー・検査のスクリプト・リポジトリの設定の変更と、その理由を書く。管理者が設定画面で行う手順は、実装で `CONTRIBUTING.md` の「リポジトリの設定」へ移す（[利用者向けの文書の変更](#利用者向けの文書の変更)）。

## 目的と範囲

2026-11-13 の点検で、main に PR と CI の必須の設定がないこと、アクションをタグで参照していること、秘密の語の一覧が同じリポジトリの PR の CI に渡ることが分かった。エージェントは人間の管理者の認証で動くので、外からの指示を受けたエージェントが、main を直接書き換えたり、一覧を持ち出したりできる。次の 6 つを目的にする。

1. main への直接の push を止め、Checks のすべてのジョブが通るまで PR をマージさせない（R1・S1）
2. すべての `uses:` を 40 桁の SHA で固定し、タグや枝の参照を残さない（R2・S2）
3. Dependabot が、アクションの更新の PR を定期的に出す（R3・S3）
4. 秘密の語の一覧を、main にマージ済みの検査のコードにだけ渡す。公開の内容の検査は PR の CI で続ける（R4）
5. すべての checkout で認証情報を残さない（R5）
6. 依存の既知の脆弱性と、危ないワークフローの書き方を、PR と定期の両方で見つけ、GitHub の画面で見せる（R6・S4）

次は対象にしない。

- エージェント専用のアカウント、承認の必須、GitHub App、環境ごとのトークンの分離
- CODEOWNERS、不変の Release、`v*` のタグの保護（タグと Release は [リポジトリの設定](../CONTRIBUTING.md#リポジトリの設定) で扱う）
- 点検で見た以外の侵害の痕跡の調査と、多要素認証

## 守るものと脅威

守るものは、main の中身、配布物、秘密の語の一覧の 3 つである。脅威ごとの今の状態と、防ぐ目的は次のとおり。

| 脅威 | 今の状態 | 防ぐ目的 |
| --- | --- | --- |
| エージェントが誤って、または外からの指示で main へ直接 push する | ruleset は削除と force push だけを止める | 1 |
| CI が落ちたままの変更をマージする | 必須のチェックがない | 1 |
| 参照するアクションのタグが、乗っ取られて差し替えられる | `check.yml` の 5 か所がタグの参照 | 2・3・6 |
| 古いアクションの既知の脆弱性に気づかない | Dependabot の警告が無効。SHA で固定すると、有効にしても警告の対象から外れる | 3・6 |
| 同じリポジトリの PR が検査のスクリプトを書き換え、一覧を持ち出す | 一覧は Repository Secret で、PR の CI に渡る | 4 |
| 取り出したあとの手順が、残ったトークンを使う | `check.yml` の 2 つの checkout が認証を残す | 5 |
| ワークフローに、式の埋め込みや信頼できない checkout が入る | 検出の仕組みがない | 6 |

## main の保護

既存の ruleset に、PR の必須と、必須のチェックを足す。必須のチェックは、Checks のすべてのジョブの結果をまとめるジョブ `checks-passed` の 1 つだけにする。

### まとめのジョブ

`check.yml` に、ほかのすべてのジョブを `needs` に並べたジョブを足す。`if: always()` で、前のジョブが失敗・取り消し・飛ばしのときも動き、結果がすべて `success` のときだけ通る。

```yaml
  checks-passed:
    if: always()
    needs: [scripts, assets, content]
    runs-on: ubuntu-24.04
    timeout-minutes: 5
    steps:
      - name: Require every job to succeed
        env:
          RESULTS: ${{ join(needs.*.result, ' ') }}
        run: |
          for result in $RESULTS; do
            if [ "$result" != success ]; then
              echo "成功していないジョブがあります: $RESULTS" >&2
              exit 1
            fi
          done
```

`scripts` のジョブの名前は、OS とシャードの組で決まる（[ワークフローの変更](ci.md#ワークフローの変更)）。シャードの数を変えるたびに ruleset を直さずに済むよう、必須にするのはこのジョブだけにする。ワークフローの決まりのテストが、`needs` にほかのすべてのジョブがあることを確かめる。ジョブを足して `needs` に入れ忘れると、テストが落ちる。

### ruleset の中身

既存の ruleset `base-barnch-rules`（対象は既定のブランチ）を、次の中身にする。名前の綴りは今のまま変えない。

| ルール | 値 | 防ぐもの |
| --- | --- | --- |
| Restrict deletions | 今のまま有効 | main の削除 |
| Block force pushes | 今のまま有効 | 履歴の書き換え |
| Require a pull request before merging | 有効。Required approvals は 0。ほかの小項目はすべて無効 | PR を通らない直接の push |
| Require status checks to pass | 有効。`checks-passed` を、ソースを GitHub Actions に限って足す。「Require branches to be up to date before merging」は無効 | CI が落ちた変更のマージ |
| Bypass list | 空 | 管理者を含む、決まりの迂回 |

チェックのソースを GitHub Actions に限るのは、同じ名前のコミットの状態を、ほかのトークンから書いて通すことを防ぐため。「up to date」を無効にするのは、マージのたびにほかの PR の取り込み直しを求めないため。マージのあとの main は、push の実行で確かめる。

承認は必須にしない。人間が 1 人で運用し、承認の必須は対象の外であるため。

### 保護の限り

手順書には、次の 1 文をそのまま書く。

> この保護は、管理者の権限を持つエージェントなら ruleset ごと外せるので、誤った push と、外からの指示による直接の push を止めるだけである。

エージェントは人間の管理者の `gh` の認証で動くので、ruleset の変更の API も呼べる。外す操作を止めるには、エージェント専用の権限の低いアカウントが要るが、対象の外である。

## アクションの固定と更新

すべてのワークフローの `uses:` を、40 桁のコミットの SHA と、`# vX.Y.Z` の注記で書く。注記は、Dependabot が更新の PR でバージョンを読み、書き換えるのに使う。

```yaml
      - uses: actions/checkout@<40 桁の SHA> # vX.Y.Z
```

固定するバージョンは、実装の時点の最新のリリースにする。`actions/checkout` は、`release-assets.yml` と同じバージョンにそろえる。今の `check.yml` は `actions/checkout@v4`、`actions/cache/restore@v4`、`actions/cache/save@v4` を 5 か所で参照する。SHA は、タグが指すコミットを `gh api repos/<OWNER>/<REPO>/commits/<タグ> --jq .sha` で読む。

### Dependabot の更新

`.github/dependabot.yml` を足し、GitHub Actions の依存を毎週確かめる。

```yaml
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
    cooldown:
      default-days: 7
    groups:
      actions:
        patterns: ['*']
```

`cooldown` で、出てから 7 日たったリリースだけを提案させる。乗っ取られたリリースは、多くが数日のうちに見つかって取り下げられるため。既知の脆弱性を直すセキュリティの更新は、この待ちを受けない。`groups` で、同じ週の更新を 1 つの PR にまとめ、マージの手間を減らす。

Dependabot の PR は、ほかの PR と同じく Checks を通してから人間がマージする。Dependabot の PR の CI には Secret が渡らないが、PR の CI はもう秘密の語の一覧を使わないので、通る（[秘密の語の検査](#秘密の語の検査)）。

### SHA の固定の強制

リポジトリの設定で、SHA で固定していないアクションを使うワークフローを、GitHub が失敗にする（S2）。固定していない参照を足した PR は、ワークフローが始まらずに失敗する。`checks-passed` が成功しないので、マージもできない。

この設定は、すべてのワークフローの固定が main に入ってから有効にする。先に有効にすると、main とすべての PR の Checks が始まらなくなる。再利用のワークフロー（`uses:` でワークフローを呼ぶもの）は、この設定の外でタグを使えるが、原本は使っていない。ワークフローの決まりのテストが、すべての `uses:` を手元でも確かめる。

## 秘密の語の検査

検査を、PR で流す公開の検査と、main で流す秘密の語の検査に分ける。一覧は、main だけが使える Environment の Secret に移し、PR とほかのブランチのワークフローからは読めなくする。

### 公開の検査

`tests/check-content.sh` に `--public` を足す。一覧を読まず、UUID の混入とシンボリックリンクだけを数える。

```bash
bash tests/check-content.sh --public [検査する木]
```

結果は `PASS content: 公開の検査で混入 0 件（秘密の語は見ていない）` と出し、一覧を使ったときと読み分けられるようにする。`--public` を付けないときは今までどおり一覧を必須にし、一覧がないまま通ることはない。`check.yml` の `content` のジョブは、Secret を参照せず、`--public` で流す。

### 秘密の語の検査のワークフロー

`.github/workflows/private-terms.yml` を足す。main への push、毎週の定期、手での実行で動き、Environment `private-terms` の Secret を使う。

```yaml
name: Private terms
on:
  push:
    branches: [main]
  schedule:
    - cron: '17 3 * * 1'
  workflow_dispatch:
permissions:
  contents: read
jobs:
  private-terms:
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    environment: private-terms
    steps:
      - uses: actions/checkout@<40 桁の SHA> # vX.Y.Z
        with:
          persist-credentials: false
      - name: Check private terms
        env:
          FORBIDDEN_TERMS: ${{ secrets.FORBIDDEN_TERMS }}
        run: |
          umask 077
          mkdir -p tmp
          printf '%s\n' "$FORBIDDEN_TERMS" > tmp/forbidden.txt
          SQUAD_KIT_FORBIDDEN_FILE="$PWD/tmp/forbidden.txt" bash tests/check-content.sh
```

Environment は、Deployment branches を `main` のブランチだけに限る。GitHub は、この決まりをワークフローの実行の ref と照らす。PR の実行の ref は `refs/pull/<番号>/merge`、ほかのブランチへの push や手での実行の ref はそのブランチなので、どれも Environment を使えず、ジョブが始まらない。PR やブランチでワークフローや検査のスクリプトを書き換えても、Secret に届くのは、レビューを経て main に入ったコードだけになる。

一覧は Repository Secret から消す。Repository Secret は、Environment を使わないジョブにも渡るため。定期の実行は、Secret の一覧に語を足したとき、main の今の中身を確かめ直すために置く。足した直後に確かめたいときは、手で実行する。

ジョブが Environment を使うたびに、GitHub は配置（deployment）の記録を 1 件作り、リポジトリの画面に出る。検査の記録として害はないので、そのままにする。

### 検出の時点

秘密の語は、マージの直後に、main への push の実行で見つける（受け入れ条件 6）。マージの前に見つけるには、PR の head の木を、Secret を使える実行で読むことになり、R4 の分離を崩すため（[検出の時点の案](#検出の時点の案)）。

語が main に入ったら、`Private terms` の実行が失敗し、GitHub が失敗を知らせる。見つけた人は、語を除く PR を作ってマージする。main の履歴には語が残るが、push した時点で同じブランチは公開されているので、マージの前に見つけても公開は防げない。

配布物に語を入れないため、`CONTRIBUTING.md` の「タグと Release を出す」に、発行の前に main の最後の `Private terms` の実行が成功していることを確かめる 1 文を足す。

## 認証情報を残さない

すべての `actions/checkout` に `persist-credentials: false` を付ける。取り出したあとの手順は、どれも Git の認証を使わないため。今は `check.yml` の `scripts` と `content` の checkout が既定のまま認証を残している。

例外を作るときは、`persist-credentials: true` の行のすぐ上に、`# 認証情報を残す理由:` で始まるコメントで理由を書く。ワークフローの決まりのテストは、この形の例外だけを通す。今は例外はない。

## 脆弱性と危ないワークフローの検出

`.github/workflows/scan.yml` を足し、CodeQL の解析と、固定したアクションの既知の脆弱性の検査を流す。どちらも PR、main への push、毎週の 3 つで動き、結果はリポジトリの Security の画面の Code scanning と、PR のチェックと注記に出る。

| 検出するもの | 道具 | 動くとき | 結果を見る場所 |
| --- | --- | --- | --- |
| 危ないワークフローの書き方（式の埋め込み、信頼できない checkout、強すぎる権限など） | CodeQL の `actions` | PR、main への push、毎週 | Security → Code scanning、PR の注記 |
| Python の検査とスクリプトの危ない書き方 | CodeQL の `python` | 同上 | 同上 |
| SHA で固定したアクションの既知の脆弱性と、注記のバージョンと SHA の食い違い | `tests/check-action-advisories.py` | 同上 | 同上（ツールの名前 `action-advisories`）、`Scan` の失敗 |

```yaml
name: Scan
on:
  pull_request:
  push:
    branches: [main]
  schedule:
    - cron: '23 4 * * 1'
permissions:
  contents: read
jobs:
  codeql:
    runs-on: ubuntu-24.04
    timeout-minutes: 15
    permissions:
      contents: read
      security-events: write
    strategy:
      fail-fast: false
      matrix:
        language: [actions, python]
    steps:
      - uses: actions/checkout@<40 桁の SHA> # vX.Y.Z
        with:
          persist-credentials: false
      - uses: github/codeql-action/init@<40 桁の SHA> # vX.Y.Z
        with:
          languages: ${{ matrix.language }}
          build-mode: none
      - uses: github/codeql-action/analyze@<40 桁の SHA> # vX.Y.Z
        with:
          category: /language:${{ matrix.language }}
  action-advisories:
    runs-on: ubuntu-24.04
    timeout-minutes: 5
    permissions:
      contents: read
      security-events: write
    steps:
      - uses: actions/checkout@<40 桁の SHA> # vX.Y.Z
        with:
          persist-credentials: false
      - name: Look up advisories for pinned actions
        env:
          GH_TOKEN: ${{ github.token }}
        run: python3 -I tests/check-action-advisories.py --sarif action-advisories.sarif .github/workflows
      - if: always()
        uses: github/codeql-action/upload-sarif@<40 桁の SHA> # vX.Y.Z
        with:
          sarif_file: action-advisories.sarif
          category: action-advisories
```

CodeQL は、GitHub の既定の設定（default setup）ではなく、リポジトリのワークフローで流す。既定の設定が SHA の固定の強制（S2）のもとで動くかは文書に書かれておらず、固定したワークフローなら確実に動き、決まりのテストでも確かめられるため（[検出の道具の案](#検出の道具の案)）。シェルのスクリプトは CodeQL が対象にしないので、今までどおり `scripts/check.sh` の構文の検査とレビューで見る。

`Scan` は Checks に入れず、必須のチェックにしない。必須にするのは Checks のジョブと決めているため。検出は PR の画面に出るので、レビューとマージの判断で見る。

### 固定したアクションの既知の脆弱性

SHA で固定したアクションは、Dependabot の警告の対象にならない。GitHub の文書は、警告を作るのはセマンティック バージョニングで参照するアクションだけで、SHA で固定したものには作らないと書いている（[Monitoring the actions in your workflows](https://docs.github.com/en/actions/reference/security/secure-use#monitoring-the-actions-in-your-workflows)）。そこで、`# vX.Y.Z` の注記をバージョンとして使い、GitHub Advisory Database を `action-advisories` のジョブで引く。

`tests/check-action-advisories.py` は、標準ライブラリだけで書き、GitHub の API は `gh api` で呼ぶ。渡したディレクトリのワークフローを読み、次の順に確かめる。

1. すべての `uses:` を `OWNER/REPO[/PATH]@<40 桁の SHA> # vX.Y.Z` として読む。`./` で始まる手元のアクションは飛ばし、形の合わないものは検出にする
2. `gh api repos/OWNER/REPO/commits/vX.Y.Z --jq .sha` で、注記のタグが指すコミットを読む。固定した SHA と違えば「注記のバージョンと SHA の食い違い」として検出にする。注記が偽りだと、バージョンで引いた結果を信じられないため。固定のあとでタグが付け替えられたときも、ここで見つかる
3. `gh api -X GET /advisories -f ecosystem=actions -f affects=OWNER/REPO@X.Y.Z` で、そのバージョンに効く審査済みの勧告を引く。`affects` は `,` でつないで 1 回にまとめる。`PATH` のあるアクション（`github/codeql-action/init` など）は、`OWNER/REPO` の名前で引く
4. 検出を SARIF に書く。場所はワークフローのファイルと `uses:` の行、規則の ID は勧告の GHSA の ID か `version-mismatch` にする。ジョブの要約にも同じ表を書く

終了コードは、検出なしが 0、検出ありが 1、API を読めなかったなど検査できなかったときが 2 にする。読めなかった結果を検出なしとして通さないため。検出ありでも SARIF を登録できるよう、登録の手順は `if: always()` で流す。

結果は、3 つの場所で見る。

| 動くとき | 見る場所 |
| --- | --- |
| PR | PR のチェック `Scan / action-advisories` の失敗と、変えた `uses:` の行の Code scanning の注記 |
| main への push と毎週 | Security → Code scanning の一覧で、ツールを `action-advisories` に絞る。毎週の実行の失敗は、Actions → Scan に出る |
| 直したあと | 次の実行で、同じ警告が Code scanning で Fixed になる |

毎週の実行が、固定したあとに公表された脆弱性を見つける。PR は、持ち込んだバージョンと、そのときの勧告を確かめる。直し方は、直ったバージョンの SHA と注記に書き換える PR で、Dependabot の更新の PR がそれを出すことも多い。

## 設定の手順

管理者が、GitHub の設定画面で次の順に行う。実装で `CONTRIBUTING.md` の「リポジトリの設定」へ移す。各手順の確かめ方は、`gh` が管理者の認証でログインした端末で流す。

順序は、Secret の移し替え、マージ、ruleset、強制の順にする。Environment は、使うワークフローがマージされる前に作る。ない名前の Environment を参照すると、GitHub が保護のない Environment を作り、Repository Secret を使ってしまうため。SHA の固定の強制は、固定が main に入ってからにする。

| 手順 | 時点 | 要件 |
| --- | --- | --- |
| 1. Environment を作り、一覧を移す | この変更のマージの前 | R4（設計で足した設定） |
| 2. Repository Secret を消す | マージの後 | R4 |
| 3. ruleset を足す | マージの後 | S1 |
| 4. SHA の固定を強制する | マージの後 | S2 |
| 5. Dependabot を有効にする | マージの後 | S3 |
| 6. コードの解析を確かめる | マージの後 | S4 |

### 1. Environment を作り、一覧を移す

1. リポジトリの Settings → Environments → New environment で、名前に `private-terms` を入れ、Configure environment を押す
2. Deployment branches and tags で「Selected branches and tags」を選び、Add deployment branch or tag rule で、Ref type を Branch、パターンを `main` にして Add rule を押す
3. Required reviewers と Wait timer は付けない
4. Environment secrets の Add environment secret で、名前を `FORBIDDEN_TERMS`、値を今の一覧（一行一語）にして保存する

確かめ方: 次の 3 つの出力を見る。1 つ目は `["branch:main"]` になり、2 つ目は `FORBIDDEN_TERMS` を含む。Secret の値は出ない。

```bash
gh api repos/AnD00/multica-squad-kit/environments/private-terms/deployment-branch-policies --jq '[.branch_policies[] | .type + ":" + .name]'
gh secret list --repo AnD00/multica-squad-kit --env private-terms
gh api repos/AnD00/multica-squad-kit/environments/private-terms --jq '.deployment_branch_policy'
```

3 つ目は `{"custom_branch_policies":true,"protected_branches":false}` になる。

### 2. Repository Secret を消す

この変更のマージのあと、Settings → Secrets and variables → Actions の Repository secrets で、`FORBIDDEN_TERMS` の削除のボタンを押して消す。

確かめ方: 1 つ目のコマンドの出力に `FORBIDDEN_TERMS` がない。2 つ目で `Private terms` を main で手で流し、3 つ目の結論が `success` になる。

```bash
gh secret list --repo AnD00/multica-squad-kit
gh workflow run private-terms.yml --repo AnD00/multica-squad-kit --ref main
gh run list --repo AnD00/multica-squad-kit --workflow private-terms.yml --limit 1 --json conclusion,headBranch,event
```

結論が出るまで数分かかる。`failure` なら、実行のログで、Environment の Secret が空でないか、語が混入していないかを見る。ログに語の値は出ない。

### 3. ruleset を足す

1. Settings → Rules → Rulesets で `base-barnch-rules` を開く
2. Bypass list が空であることを見る。空でなければ、すべて外す
3. Branch rules の「Restrict deletions」と「Block force pushes」が有効のままであることを見る
4. 「Require a pull request before merging」を有効にし、Required approvals を 0 にする。その下の小項目はすべて無効のままにする
5. 「Require status checks to pass」を有効にし、「Require branches to be up to date before merging」は無効のままにする
6. Add checks で `checks-passed` を入れて選び、ソースを GitHub Actions にする
7. Save changes を押す

確かめ方: 次の出力が、それぞれ `["deletion","non_fast_forward","pull_request","required_status_checks"]`、`[]`、`0`、`checks-passed` を含む 1 件になる。

```bash
R=repos/AnD00/multica-squad-kit/rulesets/26677466
gh api "$R" --jq '[.rules[].type] | sort'
gh api "$R" --jq '.bypass_actors'
gh api "$R" --jq '.rules[] | select(.type == "pull_request") | .parameters.required_approving_review_count'
gh api "$R" --jq '.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks'
```

動作は、次の 2 つで確かめる。

1. 原本の手元で、main から空のコミットを作り、main へ直接 push する。`GH013` の決まりの違反で拒まれれば効いている

    ```bash
    git switch --detach origin/main
    git commit --allow-empty -m 'ruleset の確かめ'
    git push origin HEAD:main
    git switch -
    ```

    通ってしまったら、空のコミットが main に残る。害はないので残し、手順 3 をやり直す。

2. 次の PR で、Checks が終わる前の `gh pr view <PR> --json mergeStateStatus` が `BLOCKED` になり、終わって通ったあとは承認なしでマージできる

### 4. SHA の固定を強制する

1. Settings → Actions → General の Actions permissions で、「Require actions to be pinned to a full-length commit SHA」を有効にする
2. Save を押す

確かめ方: 1 つ目の出力が `true` になる。そのあと、main の `Checks`、`Scan`、`Private terms` の最新の実行が `success` のままであることを、2 つ目で見る。

```bash
gh api repos/AnD00/multica-squad-kit/actions/permissions --jq '.sha_pinning_required'
for w in check.yml scan.yml private-terms.yml; do gh run list --repo AnD00/multica-squad-kit --workflow "$w" --branch main --limit 1 --json workflowName,conclusion; done
```

強制が効くことは、`actions/checkout@v4` の手順を足した確かめ用の PR を作り、Checks が始まらずに失敗することで見る。確かめたら、その PR はマージせずに閉じ、ブランチを消す。

### 5. Dependabot を有効にする

1. Settings の Security の欄にある「Advanced Security」（画面によっては「Code security」）を開く
2. Dependency graph が有効であることを見る。公開のリポジトリでは常に有効である
3. 「Dependabot alerts」の Enable を押す
4. 「Dependabot security updates」の Enable を押す

確かめ方: 1 つ目が 403 ではなく、件数（0 でもよい）を返す。2 つ目が `true` を返す。

```bash
gh api 'repos/AnD00/multica-squad-kit/dependabot/alerts?per_page=100' --jq 'length'
gh api repos/AnD00/multica-squad-kit/automated-security-fixes --jq '.enabled'
```

あわせて、Insights → Dependency graph → Dependabot に `.github/dependabot.yml` の `github-actions` が並び、最後の確かめの時刻にエラーがないことを見る。

SHA で固定したアクションには、Dependabot の警告もセキュリティの更新も出ない。原本の依存は固定したアクションだけなので、警告の一覧は 0 件のままでよい。固定したアクションの脆弱性は、`Scan` の `action-advisories` が見つける（[固定したアクションの既知の脆弱性](#固定したアクションの既知の脆弱性)）。

### 6. コードの解析を確かめる

1. 手順 5 と同じ画面の「Code scanning」で、CodeQL analysis の既定の設定（Default）を有効にしない。有効だと、ワークフローからの CodeQL の結果の登録が拒まれる
2. Security → Code scanning を開き、Tool の絞り込みに `CodeQL` と `action-advisories` の 2 つが並ぶことを見る
3. 開いた警告がないことを見る。あれば、固定したアクションの警告は直ったバージョンの SHA へ上げる PR で、CodeQL の警告は書き方を直す PR で片付ける

確かめ方: 次の出力に、`/language:actions`、`/language:python`、`action-advisories` の 3 つの解析が、`refs/heads/main` で、main への push の後の時刻で並ぶ。

```bash
gh api 'repos/AnD00/multica-squad-kit/code-scanning/analyses?ref=refs/heads/main&per_page=20' --jq '.[] | [.category, .tool.name, .created_at] | @tsv'
```

定期の実行は、最初の月曜のあとに確かめる。Actions → Scan と Actions → Private terms に、イベントが `schedule` の実行が出て、`Scan` の `action-advisories` のジョブが成功していることを見る。次の出力の先頭が `schedule success` になる。

```bash
gh run list --repo AnD00/multica-squad-kit --workflow scan.yml --event schedule --limit 1 --json event,conclusion --jq '.[] | [.event, .conclusion] | @tsv'
```

検出が動くことは、受け入れ条件 8 の確かめ用の PR で確かめる（[確かめ方](#確かめ方)）。

## 変えるファイル

| ファイル | 変更 | 目的 |
| --- | --- | --- |
| `.github/workflows/check.yml` | `uses:` を SHA で固定、checkout に `persist-credentials: false`、`content` を `--public` に、`checks-passed` を足す | 1・2・4・5 |
| `.github/workflows/private-terms.yml` | 新しく足す | 4 |
| `.github/workflows/scan.yml` | 新しく足す。CodeQL と `action-advisories` のジョブ | 6 |
| `tests/check-action-advisories.py` | 新しく足す。固定したアクションの勧告と、注記と SHA の食い違いを見つける | 6 |
| `tests/action-advisories-test.sh`・`tests/fixtures/action-advisories/` | 新しく足す。`gh` の応答を記録した写しで、検出・非検出・食い違い・読めないときを確かめる | 6 |
| `.github/dependabot.yml` | 新しく足す | 3 |
| `tests/check-content.sh`・`tests/check-content.py` | `--public` を足す | 4 |
| `tests/content-test.sh` | `--public` が一覧なしで UUID とリンクを見つけ、語は見ないことを確かめる | 4 |
| `tests/workflow-rules-test.sh` | 新しく足す。ワークフローの決まりを読んで確かめる | 1〜6 |
| `docs/ci.md` | 必須のチェックが `checks-passed` だけであることを書く | 1 |
| `CONTRIBUTING.md`・`CHANGELOG.md`・`MANIFEST` | [利用者向けの文書の変更](#利用者向けの文書の変更) | 全部 |

`tests/workflow-rules-test.sh` は、`.github/workflows/` のすべてのファイルと `.github/dependabot.yml` を、`release-workflow-test.sh` と同じく行で読む。確かめる決まりは次のとおり。壊した写しを拒むことも、同じテストで確かめる。

- すべての `uses:` が `@<40 桁の SHA> # vX.Y.Z` の形である
- `actions/checkout` の数と `persist-credentials: false` の数が合う。例外は、理由のコメントのすぐ下の `persist-credentials: true` だけを通す
- `checks-passed` が `if: always()` を持ち、`needs` が `check.yml` のほかのすべてのジョブと一致する
- `secrets.` を参照するのは `private-terms.yml` だけで、そのジョブは `environment: private-terms` を持つ
- `private-terms.yml` のきっかけが、main への push、`schedule`、`workflow_dispatch` だけである
- どのワークフローも `pull_request_target` と `workflow_run` を使わない
- `check.yml` の `content` が `--public` で流す
- `dependabot.yml` が `github-actions` を対象にする
- `scan.yml` の `codeql` と `action-advisories` が、PR、main への push、`schedule` で動き、`action-advisories` の SARIF を `if: always()` で登録する

`release-workflow-test.sh` が確かめる発行のワークフローの決まりは、今のまま残す。

## 利用者向けの文書の変更

原本を変える人と管理者が読む `CONTRIBUTING.md` を、次のとおり変える。

- 「リポジトリの設定」に、[設定の手順](#設定の手順)の 1〜6 と確かめ方を移す。[保護の限り](#保護の限り)の 1 文もそのまま書く。この文書の「設定の手順」は、移した先へのリンクと順序の理由だけに縮める
- 「MANIFEST と混入の検査」の、一覧を Repository Secret に置く説明を、Environment `private-terms` に置き main の実行だけが読む説明に替える。PR の CI は公開の検査だけを流し、秘密の語はマージの直後に見つかることを書く
- 手元の検査の例に、一覧を持たない人向けの `bash tests/check-content.sh --public` を足す
- 「タグと Release を出す」に、発行の前に main の最後の `Private terms` の実行が成功していることを確かめる 1 文を足す

`CHANGELOG.md` の次のバージョンの節に、原本を変える人に効く変更（main の PR の必須、CI の必須のチェック、秘密の語の検査がマージの直後になること）を書く。導入した各プロジェクトの動作は変わらない。

## 確かめ方

受け入れ条件ごとの確かめ方は次のとおり。設定のあとの確かめは、[設定の手順](#設定の手順)の確かめ方で人間が行う。

| 受け入れ条件 | 確かめ方 | 時点 |
| --- | --- | --- |
| 1. 直接の push が拒まれ、Checks が通るまでマージできず、承認なしでマージできる | 手順 3 の動作の確かめ | 手順 3 のあと |
| 2. 保護の限りの 1 文が手順書にある | `CONTRIBUTING.md` の「リポジトリの設定」を読む | レビュー |
| 3. タグの参照が残らず、強制のあとはタグの参照を足した PR が落ちる | `workflow-rules-test.sh`、手順 4 の確かめ用の PR | CI と手順 4 のあと |
| 4. Dependabot が `github-actions` を対象にし、警告の API が一覧を返す | `workflow-rules-test.sh`、手順 5 の確かめ方 | CI と手順 5 のあと |
| 5. 検査のスクリプトを書き換えた同じリポジトリの PR に一覧が渡らない | 下の確かめ用の PR | 手順 2 のあと |
| 6. 秘密の語をマージの直後に見つける | [検出の時点](#検出の時点)、`workflow-rules-test.sh` のきっかけの確かめ、手順 2 の実行 | レビューと手順 2 のあと |
| 7. 認証を残す checkout がなく、例外に理由がある | `workflow-rules-test.sh` | CI |
| 8. 検出が PR と定期の両方で動き、画面で見える | `action-advisories-test.sh`、下の確かめ用の PR、手順 6 の確かめ方 | CI、マージの前、手順 6 のあと |
| 9. 手順 1〜6 を上から流すと、調べ物なしで終わり、各手順に確かめ方がある | 管理者が手順を流し、詰まった所を記録する | マージの後 |

受け入れ条件 5 の確かめ用の PR は、同じリポジトリのブランチで、次の 2 つの変更を入れて作る。どちらも値ではなく長さだけを出し、マージせずに閉じ、ブランチを消す。

1. `check.yml` の `content` に、`env: FORBIDDEN_TERMS: ${{ secrets.FORBIDDEN_TERMS }}` と、その長さを出す手順を足す。出る長さが 0 になる
2. `private-terms.yml` のきっかけに `pull_request` を足す。`private-terms` のジョブが、Environment の決まりで始まらない

受け入れ条件 8 の確かめ用の PR は、この変更の PR の head から、同じリポジトリのブランチで作る。例には、勧告 [GHSA-cxww-7g56-2vh6](https://github.com/advisories/GHSA-cxww-7g56-2vh6) の `actions/download-artifact` を使う。効くのは 4.0.0 以上 4.1.3 未満で、4.1.3 で直っている。

| バージョン | SHA | 期待する結果 |
| --- | --- | --- |
| v4.1.2（脆弱） | `eaceaf801fd36c7dee90939fad912460b18a1ffe` | 検出する |
| v4.1.3（直ったもの） | `87c55149d96e628cc2ef7e6fc2aab372015aec85` | 検出しない |

1. `.github/workflows/advisory-probe.yml` を足す。きっかけは `workflow_dispatch` だけにし、手順に `actions/download-artifact@eaceaf801fd36c7dee90939fad912460b18a1ffe # v4.1.2` を 1 つ置く。手で流さないので、アクションは動かない
2. PR を draft で作る。`Scan / action-advisories` が失敗し、要約に `GHSA-cxww-7g56-2vh6` が出る。PR の Files changed で、その `uses:` の行に Code scanning の注記が出る
3. 同じ行を `@87c55149d96e628cc2ef7e6fc2aab372015aec85 # v4.1.3` に書き換えて push する。`Scan / action-advisories` が成功し、注記が消える
4. 注記を `# v4.1.3` のまま、SHA を v4.1.2 のものに戻して push する。`version-mismatch` で失敗する
5. PR をマージせずに閉じ、ブランチを消す

SHA は、手順の前に `gh api repos/actions/download-artifact/commits/v4.1.2 --jq .sha` と `v4.1.3` で読み直し、表と合うことを見る。勧告は `gh api -X GET /advisories -f ecosystem=actions -f affects=actions/download-artifact@4.1.2 --jq '.[].ghsa_id'` が `GHSA-cxww-7g56-2vh6` を返し、`@4.1.3` が空を返すことで見る。`action-advisories-test.sh` は、この 2 つの応答の写しで、同じ検出と非検出を CI で確かめる。

## 残る危うさ

- 管理者の権限を持つエージェントは、ruleset、Environment、Actions の設定を外せる。[保護の限り](#保護の限り)のとおり、止めるのは誤りと外からの指示による直接の操作だけである
- 秘密の語は、main の履歴に入ってから見つかる。見つけるまでに `release.sh` で発行すると、配布物に入る。発行の前の確かめは手順書の 1 文に頼る。続けて、`release.sh` が `Private terms` の結果を確かめるようにする案がある
- 同じリポジトリの PR のワークフローは、`permissions:` で書き込みの権限を求められる。main は ruleset で守られるが、ほかのブランチや Security の警告は書き換えられる。権限の分離は対象の外である
- SHA の固定の強制が、Dependabot の更新の実行に効くかは、GitHub の文書に書かれていない。手順 5 で Dependabot の最後の確かめにエラーがないことを見る。エラーなら、強制を無効にせず、Dependabot の画面のエラーを人間が確かめる
- `Scan` は必須でないので、検出があってもマージはできる。検出の多さを見てから、必須にするかを決める
- `action-advisories` は、GitHub Advisory Database の審査済みの勧告だけを見る。公表から審査までの間と、勧告のない乗っ取りは見つけない。乗っ取りは、SHA の固定と Dependabot の `cooldown` で防ぐ

## 検討した案

### 検出の時点の案

| 案 | 良い点 | 悪い点 |
| --- | --- | --- |
| マージの直後に、main の push の実行で見つける（選んだ案） | Secret を使う実行は、main のコードだけを読む。特権のきっかけがいらない | 語は main の履歴に入る。語を除く PR が要る |
| マージの前に、`pull_request_target` で main の検査を PR の head の木にかける | 語が main に入らない | 信頼できない木を、Secret のある実行で取り出す。CodeQL の信頼できない checkout の警告になる。fork の PR は承認なしで流れ、通るか落ちるかで語を当てる試しに使える |
| マージの前に、管理者が手元で一覧を使って流す | Secret を CI に置かない | 人の手順に頼り、忘れると見つからない。エージェントの PR は手元で流せない |

`pull_request_target` は、ワークフローの定義を base から読むので、検査のコードは main のものになる。それでも、Secret のある実行に PR の head の木を取り出す点は変わらない。検査が中身を読むだけでも、PR が足したファイルの名前やリンクが、検査のスクリプトの動きを変える余地が残る。マージの前に見つけても、push したブランチはすでに公開されているので、公開を防ぐ効果は小さい。

### 一覧の置き場所の案

| 案 | 採らない理由 |
| --- | --- |
| Repository Secret のまま、Checks の `content` を main の push だけで流す | 同じリポジトリのブランチに、push で動くワークフローを足せば、Repository Secret を読める |
| Repository Secret のまま、`if:` で PR では渡さない | `if:` は PR が書き換えるワークフローの中にあり、外せる |
| Environment に置き、Required reviewers で人の承認を挟む | main の push のたびに承認が要る。ブランチの限定だけで、PR とブランチからは読めなくなる |

### 必須のチェックの案

| 案 | 採らない理由 |
| --- | --- |
| Checks のすべてのジョブの名前を ruleset に並べる | シャードの数を変えるたびに ruleset を直す。直し忘れると、なくなった名前を待ってマージできなくなるか、足したシャードが必須から漏れる |
| ワークフローの名前 `Checks` を必須にする | ruleset が必須にできるのはジョブのチェックの名前で、ワークフローの名前ではない |

### 検出の道具の案

| 案 | 採らない理由 |
| --- | --- |
| CodeQL の既定の設定（default setup） | 設定画面だけで済むが、SHA の固定の強制のもとで動くかが文書にない。設定がリポジトリになく、テストで確かめられない |
| dependency-review-action を PR で流す | PR でしか動かず、固定のあとに公表された脆弱性を毎週は見ない。SHA で固定したアクションを見るかは文書に書かれておらず、Dependabot の警告は SHA の固定を対象にしない |
| Dependabot の警告に任せる | SHA で固定したアクションには警告を作らないと、GitHub の文書にある |
| タグの参照に戻し、Dependabot の警告を使う | R2 の SHA の固定と両立しない |
| zizmor などの外の検査の道具を足す | zizmor にも固定したアクションの勧告を引く検査があるが、足した道具そのものが新しい依存になる。勧告は `gh api` と標準ライブラリの短いスクリプトで引ける。式の埋め込みと信頼できない checkout は、CodeQL の `actions` が見る |
