# AWS CodeCommit + Terraform/Dockerfile を RHEL 9.6 運用管理サーバーで運用する設計ガイド

> 対象: AWS CodeCommit で Terraform / Dockerfile を管理し、EC2 上の RHEL 9.6「運用管理サーバー」で **承認済み PR が main にマージされたコードのみ** を実行する構成。
> 同じサーバー上で複数開発者が開発作業も行い、開発用ディレクトリと実行用ディレクトリを分離する。

---

## 0. 重要な前提（2026年6月時点の最新情報）

設計に入る前に、この構成の土台が変わった点を3つ確認する。いずれも一次情報で裏取りしている。

1. **AWS CodeCommit は 2025年11月24〜25日に GA（一般提供）へ復帰した。** 2024年7月に「新規顧客受付停止（de-emphasize）」となっていたが、顧客からの要望を受けて方針を反転し、**新規 AWS アカウントでもリポジトリ作成が再び可能**になった。現在 29 リージョンで提供され、2026年初頭に Git LFS 対応が予定されている。
   - 出典: AWS DevOps Blog「The Future of AWS CodeCommit」(2025-11-24)、CodeCommit User Guide の document history（2025-11-25 に "now available to new customers" と記載）。
   - 意味: 「CodeCommit は新規アカウントで使えない」という 2024〜2025 の前提は **もう古い**。新規構築でも採用してよい。ただし AWS は CodeCommit の機能追加には依然慎重で、GitHub/GitLab と比べ PR レビュー UI や周辺エコシステムは簡素である点は変わらない。

2. **Terraform の S3 バックエンドは「S3 ネイティブロック」が標準になった。** Terraform 1.10 で実験的に導入された `use_lockfile = true` が 1.11 で正式機能に昇格し、**DynamoDB によるロックは deprecated（将来のマイナーバージョンで削除予定）** となった。S3 の条件付き書き込みで `.tflock` オブジェクトを作ることでロックを実現する。
   - 出典: HashiCorp 公式 backend/s3 ドキュメント、AWS Prescriptive Guidance「Backend best practices」。
   - 意味: 新規は **DynamoDB ロックテーブルを作らず `use_lockfile = true` を使う**。既存の DynamoDB ロックは併用しつつ移行する。

3. **RHEL 9 では Docker Engine はサポートされない。標準は Podman である。** Red Hat は RHEL 8 の時点で docker パッケージを削除しており、RHEL 9 でも Docker は非サポート。`podman` がデフォルトのコンテナエンジン（デーモンレス、rootless 対応、OCI 準拠、デフォルト OCI ランタイムは crun）。`podman-docker` パッケージを入れると `docker` コマンドが `podman` のエイリアスになり、`/var/run/docker.sock` 互換ソケットも提供される。**Dockerfile / Containerfile の文法は両者で同一** なので、ファイル自体はそのまま使える。
   - 出典: Red Hat「Building, running, and managing containers」(RHEL 9)、「Considerations in adopting RHEL 9」。
   - 意味: 本ガイドでは「Docker build」と書かれていても **実体は `podman build`** を想定する。後述の `docker-build.sh` は podman を優先検出し docker にフォールバックするエンジン非依存設計にしている。「Docker グループに追加する危険」も RHEL 9 では基本的に発生せず、代わりに **rootless podman を使うのが正解**。

---

## 1. 全体像の要約

やりたいことを一文で言うと「**人間のレビューと承認を通った main のコードだけが、決められた1か所（runtime/main）から、追跡可能な形で AWS に適用される**」状態を、1台の RHEL 9.6 サーバー上で安全に作ること。

仕組みの骨格は次の4点に集約される。

- **唯一の信頼できる実行元 = `runtime/main`**。ここは main ブランチ専用の作業ディレクトリで、人間は直接編集しない。`sync-main.sh` だけが `git reset --hard origin/main` で書き換える。
- **開発は各自の worktree = `worktrees/<user>/<branch>`**。1つの bare リポジトリから `git worktree` で切り出すため、ディスク・履歴を共有しつつ作業ディレクトリだけ分離できる。
- **権限で実行を縛る**。`terraform plan` と `podman build`（dev タグ）は開発者が自由に行えるが、`terraform apply` は main 一致チェック＋専用ユーザー `tfexec`＋sudoers で限定する。
- **すべてに証跡を残す**。どのコミット ID を、誰が、いつ apply / build したかをログに記録し、auditd・CloudTrail と突き合わせられるようにする。

データの流れは「開発者 → worktree で開発 → push → CodeCommit で PR → レビュー承認 → main マージ → `sync-main.sh` が runtime/main を更新 → `terraform-apply.sh` / `docker-build.sh` が main コミットのみを実行 → AWS へ反映」。

この構成は **小さく始めて CI/CD へ自然に発展できる** のが利点で、後述するように将来は `terraform-apply.sh` の呼び出し元を人間から CodePipeline / GitHub Actions に置き換えるだけで移行できる。

---

## 2. 歴史的背景とこの構成が必要になった理由

なぜこんな面倒な構成にするのか。「なぜそうするのか」を理解しておくと、運用中の判断がぶれない。

**手作業構築から Infrastructure as Code (IaC) へ。** かつてサーバーは SSH で入って手でパッケージを入れ、設定ファイルを直接編集して作っていた。これは (1) 再現できない（同じ環境をもう1台作れない）、(2) 誰が何を変えたか分からない、(3) 手順書とサーバーの実態がすぐ乖離する、という問題を抱えていた。そこで「インフラの状態をコードで宣言し、ツールに収束させる」IaC が生まれた。Terraform はその代表で、**あるべき状態(.tf)** と **現状(state)** の差分を計算して AWS API を叩く。

**なぜ Terraform を Git 管理するのか。** .tf ファイルは「インフラの設計図そのもの」。設計図を個人の PC やサーバーのローカルにだけ置くと、上記の手作業時代と同じ問題に逆戻りする。Git に置けば、変更履歴・レビュー・巻き戻しが効く。さらに「誰が・なぜ・いつ」その設計変更をしたかが commit と PR に残る。

**なぜ Dockerfile を Git 管理するのか。** コンテナイメージも「手で `podman commit` して作る」と再現性がない。Dockerfile（Containerfile）はイメージのビルド手順をコード化したもので、同じ Dockerfile から同じイメージが何度でも作れる。これも設計図なので Git 管理が必須。

**なぜ Git のレビュー文化が必要か。** インフラの変更は本番障害に直結する（VPC を1つ間違えれば全社のネットワークが落ちる）。コードレビュー＝「適用前にもう1人の目を通す」仕組みは、人為ミスを最も安く防ぐ手段。Pull Request はこのレビューを制度化したもの。

**なぜ main を「唯一の実行元」とするのか。** ブランチが乱立する中で「どれが本物か」が曖昧だと、誤って未レビューのコードを本番に流す。「**本番に出てよいコードは main にだけ存在する**」という単純なルールにすれば、運用者は「main 以外は実行しない」だけを守ればよい。これが GitOps の中核思想（= Git を Single Source of Truth とする）。

**DevOps / GitOps / CI/CD / 変更管理 / 監査の関係。**
- DevOps: 開発と運用を一体で回す文化。
- GitOps: その実装の一種で、Git のコミットを「あるべき状態の宣言」とし、実環境をそこへ収束させる。
- CI/CD: Git の変更を自動でテスト(CI)・デプロイ(CD)するパイプライン。本ガイドの手動スクリプトは「人力 CD」であり、将来 CI/CD に置き換わる前段。
- 変更管理・監査: 「いつ・誰が・何を・なぜ変えたか」を残す要求。PR（なぜ・誰が）と apply ログ（いつ・何を）で満たす。

**なぜ「開発中コード」と「本番実行コード」を分離すべきか。** 開発中のコードは未完成で、壊れていたり、検証用の危険な値が入っていたりする。これが本番実行ディレクトリに混ざると事故になる。物理的にディレクトリを分け、本番実行ディレクトリには「main と完全一致したものしか入れない」ことで、開発の自由と本番の安全を両立する。

---

## 3. 登場する技術要素の役割

| 要素 | この構成での役割 | なぜ必要か |
|---|---|---|
| AWS CodeCommit | Terraform/Dockerfile の Git リモート。PR・承認ルール・main 保護を提供 | IAM と統合され、VPC 内に閉じた構成や厳格なアクセス制御がしやすい。AWS 完結で外部 SaaS 不要 |
| Git | 履歴・ブランチ・worktree の基盤 | 変更履歴とレビュー、複数作業の分離 |
| Pull Request | 変更提案＋レビュー＋承認の単位 | 適用前に第三者の目を通す |
| main ブランチ保護 | 直接 push 禁止、PR 承認必須 | 未レビューコードの混入を構造的に防ぐ |
| Terraform | インフラのあるべき状態をコード化し AWS に収束 | 再現性・差分適用・state による管理 |
| Dockerfile / Containerfile | コンテナイメージのビルド手順をコード化 | イメージの再現性 |
| EC2 | 運用管理サーバーの実体 | AWS 内部に置けば IAM ロール・VPC・SSM が使え、認証情報をディスクに置かずに済む |
| RHEL 9.6 | OS。Podman・Git・systemd・auditd・SELinux を提供 | エンタープライズの長期サポート、監査機能が充実 |
| 運用管理サーバー | 上記すべてを1か所で回す「踏み台兼実行点」 | 認証情報と実行点を1か所に集約し管理対象を絞る |

**RHEL 9.6 採用時の特徴・注意点。**
- コンテナは **Podman 標準**（Docker 非サポート）。daemonless で rootless 運用が基本。systemd と統合できる（`podman generate systemd` / Quadlet）。
- **SELinux が enforcing** 前提。コンテナのボリュームマウントで `:Z` / `:z` ラベル付けが必要になる場面がある。
- **auditd** が標準で使え、コマンド実行やファイルアクセスの監査ログが取れる。
- Git は dnf で入る安定版。Terraform は HashiCorp の yum リポジトリ、または tfenv で導入する（RHEL 標準リポジトリには無い）。
- EUS（Extended Update Support）サブスクリプションで Podman 等のマイナー更新を安定的に受けられる。

**開発環境と実行環境を同一サーバーに置くメリット・デメリット（正直に）。**

メリット: (1) サーバーが1台で済みコスト・管理が楽、(2) 開発者は本番と同じ OS・同じ Terraform/Podman バージョンで検証でき「自分の環境では動いた」問題が減る、(3) IAM ロールや CodeCommit 認証を1か所に集約できる。

デメリット（=リスク。本ガイドの主題）: (1) 開発者が誤って本番ディレクトリを触る/誤って apply する事故、(2) 開発用の壊れたコードや巨大ファイルが本番実行点の近くに存在する、(3) 開発者に与えた権限が本番実行権限に化ける危険、(4) 1台が落ちると開発も運用も止まる単一障害点、(5) 開発作業の負荷（重いビルド等）が運用に影響。

→ このデメリットを **権限分離・ディレクトリ分離・実行制御・ログ管理・承認フロー** で潰すのが以降の設計。

---

## 4. 推奨アーキテクチャ

```
                         AWS クラウド
   ┌─────────────────────────────────────────────────────┐
   │  CodeCommit (infra リポジトリ)                        │
   │    - main 保護 / 直接push禁止                          │
   │    - PR 承認ルール（1名以上、作者は自承認不可）        │
   │                                                       │
   │  S3 (tfstate, versioning+暗号化, use_lockfile)        │
   │  ECR (任意: コンテナイメージ)                          │
   │  CloudTrail / CloudWatch Logs                         │
   └───────────────▲───────────────────────┬──────────────┘
                   │ git push / PR          │ IAM ロール経由で
                   │ (HTTPS-GRC, IAM認証)    │ terraform apply / push
   ┌───────────────┴───────────────────────┴──────────────┐
   │  EC2 / RHEL 9.6  運用管理サーバー（IAMインスタンスプロファイル）│
   │                                                       │
   │  /opt/codecommit/                                     │
   │    bare/infra.git        ← 共有 bare リポジトリ        │
   │    worktrees/<user>/<br> ← 開発用（plan/dev build可）  │
   │    runtime/main          ← 実行用（applyはここのみ）   │
   │    scripts/              ← 運用スクリプト              │
   │    logs/ locks/          ← 証跡・排他制御              │
   │                                                       │
   │  ユーザー: alice, bob ... (group: codecommit-dev)     │
   │  実行専用: tfexec (runtime所有、applyはsudoで限定)     │
   │  auditd / SELinux enforcing / SSM Agent               │
   └───────────────────────────────────────────────────────┘
        ▲ 開発者は SSM Session Manager で接続（SSH鍵レス）
```

設計の要点:
- 認証情報は **EC2 インスタンスプロファイル（IAM ロール）** で供給し、アクセスキーをディスクに置かない。
- 接続は **SSM Session Manager** を第一候補にし、22番ポートを開けない。
- runtime/main は **tfexec 所有・開発者は読み取りのみ**。apply は sudoers で `tfexec` への限定 sudo のみ許可。
- state は **S3（versioning + 暗号化 + `use_lockfile`）**。

---

## 5. 推奨ディレクトリ構成

質問にあった候補案を比較する。

| 案 | 内容 | 評価 |
|---|---|---|
| `/opt/repos/` に bare | bare 置き場 | ○ 共有の起点に適切。本案でも採用 |
| `/opt/worktrees/<user>/` | 開発者別 worktree | ○ 採用。ユーザー別に分けるのが安全 |
| `/opt/runtime/main/` | main 実行専用 | ○ 採用。実行点を1か所に固定 |
| `/home/<user>/` に個別 clone | 各自フル clone | △ ディスク重複・main 同期がバラバラになりやすい。worktree に劣る |
| `/srv/terraform/` `/srv/docker/` を実行専用 | FHS 的には /srv も可 | △ 機能は同じ。/opt 配下に集約した方が管理が一元化される |

**結論（推奨構成）。** すべてを `/opt/codecommit/` 配下に集約する（`logs/` `locks/` を追加）。

```
/opt/codecommit/
├── bare/
│   └── infra.git/              # 共有 bare リポジトリ（origin の鏡）
├── worktrees/                  # 開発用（setgid, group=codecommit-dev）
│   ├── alice/
│   │   └── feature-add-vpc/    # alice 所有の worktree
│   └── bob/
│       └── feature-add-ecr/
├── runtime/
│   └── main/                   # 実行用（root/tfexec 所有、開発者は読み取りのみ）
├── scripts/                    # 運用スクリプト（root 所有 0755）
│   ├── common.sh
│   ├── setup.sh
│   ├── create-worktree.sh
│   ├── delete-worktree.sh
│   ├── sync-main.sh
│   ├── terraform-plan.sh
│   ├── terraform-apply.sh
│   └── docker-build.sh
├── logs/                       # plan/apply/build/sync の証跡
└── locks/                      # flock 用ロックファイル
```

`/opt` を選ぶ理由: FHS で「OS パッケージ管理外の追加ソフト/データ」の標準置き場であり、`/home` のようにユーザー削除で消える心配がなく、`/srv` のようにサービス公開データと混ざらない。

---

## 6. Git clone 方式と git worktree 方式の比較

**通常の `git clone`** は、リモートを丸ごと取得して `.git` ディレクトリ（全履歴）＋作業ツリー（チェックアウトされた1ブランチ分のファイル）を作る。開発者ごと・ブランチごとに clone すると、**同じ履歴が何重にもディスクへ複製**され、各 clone の main 同期がバラバラになる。

**`git worktree`** は、1つのリポジトリ（履歴は1つ）から **複数の作業ツリーを切り出す** 機能。`.git` の実体（オブジェクト・refs）は共有し、各 worktree は別ディレクトリ・別ブランチをチェックアウトできる。

**bare リポジトリ + worktree の考え方。** `bare/infra.git`（作業ツリーを持たない履歴の保管庫）を中心に置き、そこから `git worktree add` で `worktrees/alice/feature-x`（feature ブランチ）や `runtime/main`（main）を生やす。履歴は1か所、作業ディレクトリは用途ごとに分離、という理想形になる。

```
        bare/infra.git  (履歴・refs を1つだけ保持)
          ├── worktree: runtime/main           (branch: main)
          ├── worktree: worktrees/alice/feat-a (branch: feature/a)
          └── worktree: worktrees/bob/feat-b   (branch: feature/b)
```

**複数開発者・同一サーバーでの worktree の利点。**
- 履歴が1つなのでディスク効率が良く、fetch も1回で全 worktree に反映できる。
- 「main 専用ディレクトリ」を物理的に1つに固定でき、実行点が明確。
- 開発者ごとにディレクトリ＝所有者を分けられ、権限管理が素直。

**worktree の注意点。**
- **同一ブランチを複数 worktree で同時 checkout できない**（git が排他する）。これは事故防止にむしろ好都合（main は runtime に1つだけ）。
- bare リポジトリを複数ユーザーで触ると git の「dubious ownership」保護に引っかかるので、`safe.directory` を設定する（`setup.sh` で実施）。
- worktree のメタデータ（`.git/worktrees/*`）が壊れると `git worktree prune` が必要。
- ブランチ名 `feature/x` はディレクトリにそのまま使えない（`/`）ので **スラッグ化**（`feature-x`）する（`branch_to_slug`）。

**ブランチ名・ディレクトリ名・権限の設計。**
- ブランチ名: `feature/<topic>`, `fix/<topic>` 等。`validate_branch` で `..` や先頭 `-`、空白等を拒否。
- ディレクトリ名: `worktrees/<user>/<branch-slug>`。`<user>` は Linux ユーザー名（`validate_username`）。
- 権限: `worktrees/` は setgid + `codecommit-dev` グループ。`worktrees/<user>/` は当該ユーザー所有。

**個人ごと clone 方式との比較。**

| 観点 | 個人 clone | bare + worktree（推奨） |
|---|---|---|
| ディスク | ブランチ数ぶん履歴が重複 | 履歴1つ。効率的 |
| main 同期 | clone ごとにバラバラ | runtime/main 1か所で一元 |
| 実行点の明確さ | 曖昧（どの clone?） | runtime/main に固定 |
| セットアップ | 各自 clone | スクリプトで統制 |
| 学習コスト | 低い | worktree 概念の理解が必要 |

→ 同一サーバーで複数人・実行点固定の要件では **worktree が明確に優位**。

---

## 7. 複数開発者が同一サーバーで作業する場合の設計

**Linux ユーザーを開発者ごとに分ける（必須）。** alice / bob を個別アカウントにし、共通の `codecommit-dev` グループに入れる。共通ユーザー（例: `devuser` を全員で共有）は **厳禁**: 誰の操作か特定できず、auditd / shell history / sudo ログがすべて無意味になり、監査が成立しない。

**sudo 権限の制御。** 開発者には一般的な root sudo を与えない。`terraform apply` は専用ユーザー `tfexec` に切り替える限定 sudo のみ許可する（`sudoers.d/codecommit-ops` 参照）。

```
# /etc/sudoers.d/codecommit-ops（要点）
Cmnd_Alias TF_APPLY = /opt/codecommit/scripts/terraform-apply.sh ""
%tf-approvers ALL=(tfexec) NOPASSWD: TF_APPLY      # 承認者だけが apply 可能
%codecommit-dev ALL=(tfexec) NOPASSWD: /opt/codecommit/scripts/sync-main.sh ""
```

**apply を誰でも実行できないようにする。** apply 権限は「`tf-approvers` グループ所属者だけ」。開発者（`codecommit-dev`）は plan と dev build まで。これで「PR 承認」とは別に「apply 実行権限」を絞れる。

**Docker(Podman) build は許可、run/push は制限。** RHEL 9 では rootless podman が基本なので「docker グループに入れて root 相当」という危険は起きにくい。build は各自の rootless podman で自由に。**push（ECR への配布）と本番 run は tfexec 等の限定アカウント**でのみ実行する運用にする。

**ファイル所有者・グループ・umask・setgid。**
- `worktrees/` に **setgid（chmod 2775）** を付けると、配下に作られるファイルのグループが自動的に `codecommit-dev` を継承する。
- 各ユーザーの `umask 027`（他者に書き込ませない）を推奨。
- `worktrees/<user>/` は `0750`（同グループは読めるがアクセスは所有者中心）。

**ユーザー別領域。** `worktrees/alice/` `worktrees/bob/` と分け、`create-worktree.sh` が `chown <user>` する。これで「他人の作業ツリーを誤って壊す」事故を防ぐ。

**操作ログの重要性。** auditd（実行コマンド・ファイルアクセス）、各ユーザーの shell history、sudo ログ（`/var/log/secure`）、スクリプトが出す `logs/` 配下のログ。これらを併せて「誰が・いつ・何を」を再構成できる状態にする（詳細は §15）。

**開発者ごとの AWS 認証情報。**
- **原則: 個人のアクセスキーをサーバーに置かない。** EC2 インスタンスプロファイル（IAM ロール）を基本とする。
- CodeCommit への push 認証は **git-remote-codecommit（HTTPS-GRC, `codecommit::<region>://<repo>`）** を使い、IAM 認証で行う（HTTPS Git 認証情報や SSH 鍵をユーザーごとに撒くより安全で楽）。
- 開発者ごとに権限を分けたい場合は、各自が `aws sts assume-role` で個別ロールを引き受ける AWS CLI プロファイルを使う。インスタンスプロファイルの権限は最小にし、強い操作（apply）は tfexec が引き受けるロールに寄せる。

---

## 8. main ブランチ最新維持の仕組み

**runtime/main を main 専用にする。** ここには main ブランチだけがチェックアウトされ、人は編集しない。

**同期は `sync-main.sh`。** 中身は次の3手。

```
git -C runtime/main fetch origin --prune
git -C runtime/main reset --hard origin/main   # ローカルの差分を捨て origin/main に一致
git -C runtime/main clean -fdx                 # 未追跡ファイル(.terraform等)も消す
```

**cron / systemd timer / 手動。** 5分間隔の systemd timer を推奨（`systemd/codecommit-sync.timer`）。`flock` で多重起動を防止し、`logs/sync-main.log` に同期前後のコミット ID を残す。手動でも `sync-main.sh` を叩けば即同期できる。

**PR 承認 → main マージ → runtime/main 反映の流れ。** CodeCommit 側で承認ルールを満たした PR だけが main にマージされる。timer が次回起動時に `fetch + reset --hard` で runtime/main をその main に追従させる。**つまり runtime/main には「承認を通った main」しか現れない。**

**`git clean -fdx` の意味。** `-f`(強制) `-d`(ディレクトリも) `-x`(.gitignore 対象＝`.terraform/` 等も) を消す。runtime/main を **origin/main と完全に同じ状態（byte 一致）** に保つため。ここに「ローカルにしかない大事なファイル」を絶対に置かない、という規律が前提（置いたら消える＝**破壊的**。だからこそ実行専用にする）。

**実行ディレクトリで直接編集禁止の理由。** 編集すると `reset --hard` / `clean -fdx` で問答無用に消える上、「main に無いコードが本番に出る」事故になる。所有者を root/tfexec にして開発者の書き込みを物理的に防ぐ。

**実行前に必ず `git rev-parse HEAD` を記録する理由。** 「いま AWS に適用したのは厳密にどのコミットか」を後から証明するため。apply / build のログ先頭にコミット ID を必ず残す（`terraform-apply.sh` / `docker-build.sh` で実装）。インシデント時に「この障害はコミット X の適用が原因」と特定でき、巻き戻しも `git revert X` で確実にできる。

---

## 9. 実行用ディレクトリと開発用ディレクトリの分離

| 用途 | パス | 所有/権限 | 許可される操作 |
|---|---|---|---|
| 開発用 | `worktrees/<user>/<branch>` | `<user>:codecommit-dev` 2750 | `fmt`/`validate`/`plan`、dev タグの build |
| 実行用 | `runtime/main` | `root`(or `tfexec`) 開発者は読のみ | `apply`、official build、`sync` のみ |
| 履歴庫 | `bare/infra.git` | `root:codecommit-dev` | fetch/worktree 操作（スクリプト経由） |
| スクリプト | `scripts/` | `root:root` 0755 | 実行のみ（編集は管理者） |

**設計判断と「なぜ」。**
- **開発 worktree では `apply` を禁止し `plan` まで** にする（`terraform-plan.sh` は plan で完結し apply メソッドを持たない）。理由: 未レビューコードが AWS に出ないようにするため。plan は読み取り中心で安全。
- **`apply` は runtime/main のみ**（`terraform-apply.sh` が main 一致・clean を強制）。理由: 実行点を1か所に固定し、適用＝必ず承認済み main、を保証するため。
- **正式 build も main のみ**。`docker-build.sh` は runtime/main からのビルドにコミット ID タグ + `:latest` を付け、開発 worktree からは `dev-<user>-<branch>-<sha>` タグにする。理由: どのイメージが「本番昇格可能」かをタグで一目で区別するため。
- **タグ命名規則。** 本番 `myapp:<full-or-short-sha>`（+`:latest`）、開発 `myapp:dev-alice-feature-x-1a2b3c`。SHA 由来にすることで「このイメージはこの commit から作られた」が追跡できる。
- **terraform workspace / backend の関係。** 環境分離は (a) ディレクトリ分割（`envs/dev`, `envs/prod`）か (b) workspace のどちらか。本構成では **ディレクトリ分割を推奨**（workspace は state キーが同一バケット内で増え、誤適用時の影響が読みにくい）。backend は §0 の通り **S3 + `use_lockfile`**。
- **state ファイルの安全管理。** ローカルに置かない。S3（versioning ON で誤上書きから復旧可能、SSE-KMS で暗号化、パブリックアクセス全ブロック）。state には平文の機密（パスワード等）が入りうるので、バケットへのアクセスは tfexec / インスタンスロールに限定。

---

## 10. PR 承認から実行までの詳細フロー（時系列の具体例）

`feature/add-vpc` を Alice が追加し、Bob が承認して本番反映するまで。

1. **worktree 作成**（管理者または sudo 経由）
   `create-worktree.sh alice feature/add-vpc`
   → `worktrees/alice/feature-add-vpc`（origin/main から分岐、alice 所有）
2. **開発**: alice がそのディレクトリで `.tf` を編集。
3. **検証**: `terraform-plan.sh worktrees/alice/feature-add-vpc envs/prod`
   → `fmt -check` / `init` / `validate` / `plan -out=...`。ログは `logs/plan-feature-add-vpc-<sha>-<時刻>.log`。
4. **push**: alice が `git -C worktrees/alice/feature-add-vpc push origin feature/add-vpc`（HTTPS-GRC, IAM 認証）。
5. **PR 作成**: CodeCommit コンソール/CLI で `feature/add-vpc → main` の PR を作成。
6. **レビュー・承認**: Bob が差分を確認し承認。承認ルール（1名以上、作者自承認不可）を満たす。
   - ※ CodeCommit は **PR 作者が自分の PR を承認できない**。よって「1承認ルール」でも **実質的に最低2名** が必要になる（gotcha）。
7. **マージ**: 承認条件を満たした PR を main へマージ。
8. **runtime 同期**: 次回 timer（最大5分）で `sync-main.sh` が `runtime/main` を origin/main に追従。`logs/sync-main.log` に `before -> after` のコミット ID。
9. **apply**: 承認者が `sudo -u tfexec /opt/codecommit/scripts/terraform-apply.sh envs/prod`
   → branch=main 確認、HEAD==origin/main 確認、clean 確認、`init`/`validate`/`plan`/（確認プロンプト）/`apply`。`logs/apply-<sha>-<時刻>.log` に commit ID・実行者・日時・結果。
10. **（コンテナがあれば）build/push**: `docker-build.sh runtime/main myapp --push <ecr>`
    → `myapp:<sha>` + `:latest`、ECR へ push。
11. **証跡突合**: CloudTrail（AWS API 呼び出し）、auditd（OS 操作）、`logs/`（スクリプト）で一連を再構成可能。

---

## 11. 必要スクリプト一覧

| スクリプト | 役割 | 実行場所/主体 | 排他 |
|---|---|---|---|
| `common.sh` | 共有関数（ログ/検証/flock/git補助）。source 専用 | — | — |
| `setup.sh` | 初期セットアップ（冪等）。bare clone, runtime 作成, 権限 | 管理者(root) | — |
| `create-worktree.sh` | 開発 worktree 作成（origin/main から分岐） | 管理者/sudo | repo ロック |
| `delete-worktree.sh` | worktree 削除・ローカル/(任意)リモートブランチ削除 | 管理者/sudo | repo ロック |
| `sync-main.sh` | runtime/main を origin/main に強制一致 | timer/tfexec | runtime ロック |
| `terraform-plan.sh` | 開発 worktree で fmt/validate/plan（apply 不可） | 開発者 | — |
| `terraform-apply.sh` | runtime/main のみ apply（多重ガード） | tfexec(sudo) | runtime ロック |
| `docker-build.sh` | Podman/Docker でイメージ build（main=正式タグ） | 開発者/tfexec | — |

共通方針（§10 の補足指示に対応）: 全スクリプトで `set -euo pipefail`、引数チェック、明確なエラーメッセージ、ログ関数、`flock` 排他、安全なディレクトリ/入力チェック、main 以外 apply 不可、`git status --porcelain` で差分確認、`git rev-parse` でブランチ/コミット確認、`trap` でのクリーンアップを実装。すべて `shellcheck -x` をパスする。

---

## 12. 各スクリプトの実装例

以下に全スクリプトの完全なソースを示す（省略なし・そのまま実行可能・`shellcheck -x` クリーン）。各スクリプト冒頭のコメントに目的・使い方・例を記載している。動作原理と注意点は各ソースのコメントおよび §13/§16/§17 を参照。

> 設置場所は `/opt/codecommit/scripts/`。`common.sh` は **source 専用**（実行しない、0644）。他は実行可能（0755）。`setup.sh` が正しい所有者・権限で配置する。


### `scripts/common.sh`

```bash
#!/usr/bin/env bash
# common.sh - shared helpers for the CodeCommit operations scripts.
#
# This file is meant to be *sourced*, not executed:
#     source "$(dirname "$0")/common.sh"
#
# It deliberately does NOT call `set -euo pipefail` itself, because the
# calling script owns that decision. It only provides functions, constants,
# and small guards that every script reuses.
#
# shellcheck shell=bash

# ---------------------------------------------------------------------------
# Layout constants (override via environment before sourcing if needed)
# ---------------------------------------------------------------------------
: "${CC_ROOT:=/opt/codecommit}"
: "${CC_BARE:=${CC_ROOT}/bare/infra.git}"
: "${CC_WORKTREES:=${CC_ROOT}/worktrees}"
: "${CC_RUNTIME:=${CC_ROOT}/runtime/main}"
: "${CC_SCRIPTS:=${CC_ROOT}/scripts}"
: "${CC_LOGDIR:=${CC_ROOT}/logs}"
: "${CC_LOCKDIR:=${CC_ROOT}/locks}"

# Linux group that owns developer-writable areas.
: "${CC_DEV_GROUP:=codecommit-dev}"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
# All log lines go to stderr so that stdout stays clean for capturable output
# (e.g. a script that prints a path or a commit id for another script to read).
_cc_ts() { date +'%Y-%m-%dT%H:%M:%S%z'; }

log_info()  { printf '%s [INFO]  %s\n'  "$(_cc_ts)" "$*" >&2; }
log_warn()  { printf '%s [WARN]  %s\n'  "$(_cc_ts)" "$*" >&2; }
log_error() { printf '%s [ERROR] %s\n'  "$(_cc_ts)" "$*" >&2; }

# die <message...> : log an error and exit non-zero.
die() {
    log_error "$*"
    exit 1
}

# log_to_file <logfile> : mirror everything written to stdout+stderr into a
# logfile *as well as* the terminal, preserving exit codes via pipefail.
# Call this once near the top of a script after `set -euo pipefail`.
log_to_file() {
    local logfile="$1"
    mkdir -p "$(dirname "$logfile")"
    # process substitution + tee keeps console output AND appends to the file
    exec > >(tee -a "$logfile") 2>&1
}

# ---------------------------------------------------------------------------
# Pre-flight guards
# ---------------------------------------------------------------------------
# require_cmd <cmd> [cmd...] : abort unless every command is on PATH.
require_cmd() {
    local missing=0 c
    for c in "$@"; do
        if ! command -v "$c" >/dev/null 2>&1; then
            log_error "required command not found: ${c}"
            missing=1
        fi
    done
    [ "$missing" -eq 0 ] || die "missing prerequisites; aborting"
}

# require_dir <dir> : abort unless the directory exists.
require_dir() {
    [ -d "$1" ] || die "expected directory does not exist: $1"
}

# ---------------------------------------------------------------------------
# Input validation (defends against path traversal / shell-meta injection)
# ---------------------------------------------------------------------------
# A valid Linux username we are willing to create a sub-tree for.
validate_username() {
    local u="$1"
    [[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] \
        || die "invalid username: '${u}' (allowed: ^[a-z_][a-z0-9_-]{0,31}$)"
}

# A safe git branch name. Rejects path traversal, leading dashes, spaces,
# and the characters git itself forbids. Intentionally stricter than git.
validate_branch() {
    local b="$1"
    case "$b" in
        ""|-*|*..*|*" "*|*"~"*|*"^"*|*":"*|*"?"*|*"*"*|*"["*|*"\\"*|*"@{"*)
            die "invalid branch name: '${b}'" ;;
    esac
    [[ "$b" =~ ^[A-Za-z0-9._/-]+$ ]] \
        || die "invalid branch name: '${b}' (allowed chars: A-Za-z0-9._/-)"
    case "$b" in */) die "branch name must not end with '/': '${b}'" ;; esac
}

# Turn a branch name into a filesystem-safe directory slug (feature/x -> feature-x).
branch_to_slug() {
    printf '%s' "$1" | tr '/' '-'
}

# ---------------------------------------------------------------------------
# Locking (prevents concurrent runs from racing on the same repo/worktree)
# ---------------------------------------------------------------------------
# with_lock <lockname> <command...> : run command while holding an exclusive
# flock. Exits 1 if the lock cannot be taken within the timeout.
with_lock() {
    local name="$1"; shift
    local lockfile="${CC_LOCKDIR}/${name}.lock"
    mkdir -p "$CC_LOCKDIR"
    exec {lock_fd}>"$lockfile" || die "cannot open lock file: ${lockfile}"
    if ! flock -w "${CC_LOCK_TIMEOUT:-300}" "$lock_fd"; then
        die "could not acquire lock '${name}' within ${CC_LOCK_TIMEOUT:-300}s"
    fi
    "$@"
    local rc=$?
    flock -u "$lock_fd"
    return "$rc"
}

# ---------------------------------------------------------------------------
# Git helpers
# ---------------------------------------------------------------------------
# git_in <dir> <git-args...> : run git with -C against a directory.
git_in() { git -C "$1" "${@:2}"; }

# current_branch <worktree> : print the checked-out branch name.
current_branch() { git -C "$1" rev-parse --abbrev-ref HEAD; }

# head_sha <worktree> : print the full HEAD commit id.
head_sha() { git -C "$1" rev-parse HEAD; }

# short_sha <worktree> : print the abbreviated HEAD commit id.
short_sha() { git -C "$1" rev-parse --short HEAD; }

# assert_clean <worktree> : abort if there are uncommitted or untracked changes.
assert_clean() {
    local wt="$1"
    if [ -n "$(git -C "$wt" status --porcelain)" ]; then
        git -C "$wt" status --short >&2
        die "working tree is not clean: ${wt}"
    fi
}
```

### `scripts/setup.sh`

```bash
#!/usr/bin/env bash
# setup.sh - one-time (idempotent) bootstrap of the /opt/codecommit tree.
#
# Creates the directory layout, mirror-clones the CodeCommit repo as a bare
# repository, lays down the runtime/main worktree, and fixes ownership and
# permissions so that developers (group: $CC_DEV_GROUP) can work safely while
# the runtime area stays protected.
#
# Re-running is safe: every step checks whether it has already been done.
#
# Usage:
#   sudo ./setup.sh <clone-url>
#
# Example (HTTPS-GRC, recommended for CodeCommit + IAM):
#   sudo ./setup.sh codecommit::ap-northeast-1://infra
#
# Example (raw HTTPS):
#   sudo ./setup.sh https://git-codecommit.ap-northeast-1.amazonaws.com/v1/repos/infra
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

main() {
    [ "$#" -eq 1 ] || die "usage: $0 <clone-url>"
    local clone_url="$1"

    require_cmd git getent install
    log_info "bootstrapping CodeCommit ops tree under ${CC_ROOT}"

    # 1. Ensure the developer group exists (does not fail if already present).
    if ! getent group "$CC_DEV_GROUP" >/dev/null; then
        log_info "creating group ${CC_DEV_GROUP}"
        groupadd --system "$CC_DEV_GROUP"
    fi

    # 2. Directory skeleton.
    #    - root:root, mode 0755 for the top and runtime parent
    #    - worktrees/ is setgid + group-writable so each dev sub-tree inherits
    #      the shared group and a sane umask-independent group bit.
    install -d -o root -g root            -m 0755 "$CC_ROOT"
    install -d -o root -g root            -m 0755 "${CC_ROOT}/bare"
    install -d -o root -g root            -m 0755 "${CC_ROOT}/runtime"
    install -d -o root -g "$CC_DEV_GROUP" -m 2775 "$CC_WORKTREES"
    install -d -o root -g root            -m 0755 "$CC_SCRIPTS"
    install -d -o root -g "$CC_DEV_GROUP" -m 2775 "$CC_LOGDIR"
    install -d -o root -g "$CC_DEV_GROUP" -m 2775 "$CC_LOCKDIR"

    # 3. Bare clone (idempotent).
    if [ -d "${CC_BARE}" ] && git -C "${CC_BARE}" rev-parse --is-bare-repository >/dev/null 2>&1; then
        log_info "bare repository already present: ${CC_BARE}"
    else
        log_info "cloning bare repository from ${clone_url}"
        git clone --bare "$clone_url" "$CC_BARE"
        # A plain --bare clone does NOT create refs/remotes/origin/*.
        # Configure the standard fetch refspec so that 'origin/main' resolves,
        # which the runtime sync and apply guards rely on.
        git -C "$CC_BARE" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
        git -C "$CC_BARE" fetch origin --prune
    fi

    # 4. Mark shared repo paths as safe so git does not refuse cross-user access
    #    ("detected dubious ownership in repository").
    git config --system --replace-all safe.directory "$CC_BARE"     || true
    git config --system --add         safe.directory "$CC_RUNTIME"  || true
    git config --system --add         safe.directory "${CC_WORKTREES}/*" || true

    # 5. runtime/main worktree (idempotent).
    if [ -d "${CC_RUNTIME}/.git" ] || git -C "$CC_BARE" worktree list 2>/dev/null | grep -q -- "$CC_RUNTIME"; then
        log_info "runtime worktree already present: ${CC_RUNTIME}"
    else
        log_info "creating runtime worktree pinned to main: ${CC_RUNTIME}"
        # Create/refresh a local 'main' that tracks origin/main, then attach it.
        git -C "$CC_BARE" branch -f main origin/main
        git -C "$CC_BARE" worktree add "$CC_RUNTIME" main
    fi

    # 6. Lock the runtime area down: owned by root, group read-only.
    #    Developers must NEVER edit here directly; only sync-main.sh writes.
    chown -R root:root "${CC_ROOT}/runtime"
    chmod -R go-w      "${CC_ROOT}/runtime"

    # 7. Install the scripts themselves into the canonical location.
    if [ "$SCRIPT_DIR" != "$CC_SCRIPTS" ]; then
        log_info "installing scripts into ${CC_SCRIPTS}"
        install -o root -g root -m 0755 "${SCRIPT_DIR}"/*.sh "$CC_SCRIPTS"/
        # common.sh is sourced, not executed; 0644 is enough.
        install -o root -g root -m 0644 "${SCRIPT_DIR}/common.sh" "$CC_SCRIPTS/common.sh"
    fi

    log_info "setup complete."
    log_info "  bare repo : ${CC_BARE}"
    log_info "  runtime   : ${CC_RUNTIME} (branch: $(current_branch "$CC_RUNTIME"), HEAD: $(short_sha "$CC_RUNTIME"))"
    log_info "  worktrees : ${CC_WORKTREES} (group ${CC_DEV_GROUP}, setgid)"
}

main "$@"
```

### `scripts/create-worktree.sh`

```bash
#!/usr/bin/env bash
# create-worktree.sh - cut a per-developer worktree for a feature branch.
#
# A new branch is always created from the latest origin/main so that work
# starts from the trusted baseline. The worktree lives under
#   $CC_WORKTREES/<user>/<branch-slug>
# and is owned by that user (group: $CC_DEV_GROUP).
#
# Usage:
#   ./create-worktree.sh <user> <branch>
#
# Example:
#   ./create-worktree.sh alice feature/add-vpc
#   -> /opt/codecommit/worktrees/alice/feature-add-vpc  (branch feature/add-vpc)
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

create_worktree() {
    local user="$1" branch="$2"
    local slug user_dir wt_path
    slug="$(branch_to_slug "$branch")"
    user_dir="${CC_WORKTREES}/${user}"
    wt_path="${user_dir}/${slug}"

    require_cmd git install
    require_dir "$CC_BARE"

    log_info "refreshing remote refs"
    git -C "$CC_BARE" fetch origin --prune

    if [ -e "$wt_path" ]; then
        die "worktree path already exists: ${wt_path} (use delete-worktree.sh first)"
    fi

    # Per-user directory, setgid so files keep the shared group.
    install -d -o "$user" -g "$CC_DEV_GROUP" -m 2750 "$user_dir"

    if git -C "$CC_BARE" show-ref --verify --quiet "refs/heads/${branch}"; then
        # Branch already exists locally: attach a worktree to it (do NOT reset
        # it to main, the dev may have history we must not destroy).
        log_warn "local branch '${branch}' already exists; attaching existing branch"
        git -C "$CC_BARE" worktree add "$wt_path" "$branch"
    elif git -C "$CC_BARE" show-ref --verify --quiet "refs/remotes/origin/${branch}"; then
        # Branch exists on the remote: track it.
        log_info "remote branch origin/${branch} exists; checking it out"
        git -C "$CC_BARE" worktree add --track -b "$branch" "$wt_path" "origin/${branch}"
    else
        # Brand new branch off the trusted baseline.
        log_info "creating new branch '${branch}' from origin/main"
        git -C "$CC_BARE" worktree add -b "$branch" "$wt_path" origin/main
    fi

    # Hand ownership of the working files to the developer.
    chown -R "$user":"$CC_DEV_GROUP" "$wt_path"

    log_info "worktree ready:"
    log_info "  path   : ${wt_path}"
    log_info "  branch : $(current_branch "$wt_path")"
    log_info "  base   : $(short_sha "$wt_path")"
    # stdout: emit the path so callers can `cd "$(create-worktree.sh ...)"`.
    printf '%s\n' "$wt_path"
}

main() {
    [ "$#" -eq 2 ] || die "usage: $0 <user> <branch>"
    local user="$1" branch="$2"
    validate_username "$user"
    validate_branch "$branch"
    with_lock "repo" create_worktree "$user" "$branch"
}

main "$@"
```

### `scripts/delete-worktree.sh`

```bash
#!/usr/bin/env bash
# delete-worktree.sh - tear down a finished worktree (and optionally branches).
#
# By default this removes only the working directory and the local branch.
# The remote branch is left intact unless --remote is given, because deleting
# a remote branch may break an open Pull Request.
#
# Usage:
#   ./delete-worktree.sh <user> <branch> [--remote] [--force] [--yes]
#
#   --remote   also delete the branch on origin (CodeCommit)
#   --force    pass --force to `git worktree remove` (discards local changes)
#   --yes      skip the interactive confirmation prompt
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

confirm() {
    local prompt="$1"
    if [ "${ASSUME_YES:-0}" -eq 1 ]; then
        return 0
    fi
    local reply
    read -r -p "${prompt} [y/N] " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

delete_worktree() {
    local user="$1" branch="$2"
    local slug wt_path
    slug="$(branch_to_slug "$branch")"
    wt_path="${CC_WORKTREES}/${user}/${slug}"

    require_dir "$CC_BARE"

    if [ ! -e "$wt_path" ]; then
        log_warn "worktree path not found (already gone?): ${wt_path}"
    else
        # Refuse to remove a dirty worktree unless --force was given.
        if [ "${FORCE:-0}" -ne 1 ] && [ -n "$(git -C "$wt_path" status --porcelain 2>/dev/null)" ]; then
            git -C "$wt_path" status --short >&2
            die "worktree has uncommitted changes; commit/push them or re-run with --force"
        fi
        confirm "Remove worktree '${wt_path}' (branch '${branch}')?" || die "aborted by user"
        log_info "removing worktree ${wt_path}"
        if [ "${FORCE:-0}" -eq 1 ]; then
            git -C "$CC_BARE" worktree remove --force "$wt_path"
        else
            git -C "$CC_BARE" worktree remove "$wt_path"
        fi
    fi

    git -C "$CC_BARE" worktree prune

    # Delete the local branch (use -D; the branch may not be merged into the
    # bare repo's local main even though it is merged on the remote).
    if git -C "$CC_BARE" show-ref --verify --quiet "refs/heads/${branch}"; then
        log_info "deleting local branch ${branch}"
        git -C "$CC_BARE" branch -D "$branch"
    fi

    if [ "${DELETE_REMOTE:-0}" -eq 1 ]; then
        confirm "Also delete REMOTE branch origin/${branch}? This can break an open PR." \
            || die "remote deletion aborted by user"
        log_info "deleting remote branch origin/${branch}"
        git -C "$CC_BARE" push origin --delete "$branch"
    fi

    log_info "delete complete for ${user}/${branch}"
}

main() {
    local user="" branch="" arg
    DELETE_REMOTE=0; FORCE=0; ASSUME_YES=0
    for arg in "$@"; do
        case "$arg" in
            --remote) DELETE_REMOTE=1 ;;
            --force)  FORCE=1 ;;
            --yes)    ASSUME_YES=1 ;;
            -*)       die "unknown option: ${arg}" ;;
            *)
                if [ -z "$user" ]; then user="$arg"
                elif [ -z "$branch" ]; then branch="$arg"
                else die "too many positional arguments"
                fi ;;
        esac
    done
    [ -n "$user" ] && [ -n "$branch" ] || die "usage: $0 <user> <branch> [--remote] [--force] [--yes]"
    validate_username "$user"
    validate_branch "$branch"
    with_lock "repo" delete_worktree "$user" "$branch"
}

main "$@"
```

### `scripts/sync-main.sh`

```bash
#!/usr/bin/env bash
# sync-main.sh - force the runtime/main worktree to exactly match origin/main.
#
# This is the ONLY thing allowed to write into the runtime tree. It is safe to
# run from cron or a systemd timer: flock prevents overlapping runs, and the
# before/after commit ids are written to a log for audit.
#
# Behaviour:
#   git fetch origin --prune
#   git reset --hard origin/main      <- discards any drift in runtime/main
#   git clean -fdx                     <- removes untracked files (incl. .terraform)
#
# Usage:
#   ./sync-main.sh
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

do_sync() {
    require_dir "$CC_RUNTIME"
    local logfile="${CC_LOGDIR}/sync-main.log"
    log_to_file "$logfile"

    local branch before after
    branch="$(current_branch "$CC_RUNTIME")"
    if [ "$branch" != "main" ]; then
        die "runtime worktree is on '${branch}', expected 'main'; refusing to sync"
    fi

    before="$(head_sha "$CC_RUNTIME")"
    log_info "sync start: runtime at ${before}"

    git -C "$CC_RUNTIME" fetch origin --prune
    git -C "$CC_RUNTIME" reset --hard origin/main
    # -x also removes ignored files such as local .terraform/ caches so that the
    # runtime tree is byte-for-byte what is in origin/main. This is intentional
    # and destructive: nothing of value must ever live only in runtime/main.
    git -C "$CC_RUNTIME" clean -fdx

    after="$(head_sha "$CC_RUNTIME")"
    if [ "$before" = "$after" ]; then
        log_info "sync done: already up to date at ${after}"
    else
        log_info "sync done: ${before} -> ${after}"
    fi
}

main() {
    [ "$#" -eq 0 ] || die "usage: $0 (no arguments)"
    # Non-blocking-ish: short timeout so a stuck timer instance does not pile up.
    CC_LOCK_TIMEOUT="${CC_LOCK_TIMEOUT:-60}" with_lock "runtime" do_sync
}

main "$@"
```

### `scripts/terraform-plan.sh`

```bash
#!/usr/bin/env bash
# terraform-plan.sh - fmt + validate + plan inside a development worktree.
#
# This is the "safe" Terraform entrypoint developers use while iterating.
# It NEVER applies. It writes a binary plan file and a human-readable log so a
# reviewer can see exactly what was proposed.
#
# Usage:
#   ./terraform-plan.sh <worktree-dir> [tf-dir-relative-to-worktree]
#
# Example:
#   ./terraform-plan.sh /opt/codecommit/worktrees/alice/feature-add-vpc envs/dev
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

main() {
    [ "$#" -ge 1 ] && [ "$#" -le 2 ] || die "usage: $0 <worktree-dir> [tf-subdir]"
    local wt="$1" subdir="${2:-.}"
    require_cmd terraform git
    require_dir "$wt"

    # Guard: refuse to run plan against the protected runtime tree; plan there
    # is harmless but we want developers to stay in their own worktrees.
    case "$(realpath "$wt")" in
        "$(realpath "$CC_RUNTIME")"*) die "use terraform-apply.sh for the runtime tree, not plan here" ;;
    esac

    local tf_dir="${wt}/${subdir}"
    require_dir "$tf_dir"

    local branch sha stamp logfile planfile
    branch="$(current_branch "$wt")"
    sha="$(short_sha "$wt")"
    stamp="$(date +'%Y%m%d-%H%M%S')"
    logfile="${CC_LOGDIR}/plan-${branch//\//-}-${sha}-${stamp}.log"
    planfile="${tf_dir}/plan-${sha}-${stamp}.tfplan"
    log_to_file "$logfile"

    log_info "terraform plan in ${tf_dir} (branch ${branch}, ${sha})"

    pushd "$tf_dir" >/dev/null
    trap 'popd >/dev/null || true' EXIT

    terraform fmt -check -recursive || die "terraform fmt found unformatted files (run: terraform fmt -recursive)"
    # -input=false avoids hanging on a prompt under cron/CI; backend stays remote.
    terraform init -input=false -reconfigure
    terraform validate
    # Save a binary plan so apply (later, on main) could reuse an identical plan
    # if desired. Plan files may contain sensitive values: they live only inside
    # the developer's worktree and are wiped by git clean in runtime.
    terraform plan -input=false -lock-timeout=120s -out="$planfile"

    log_info "plan saved: ${planfile}"
    log_info "log saved : ${logfile}"
}

main "$@"
```

### `scripts/terraform-apply.sh`

```bash
#!/usr/bin/env bash
# terraform-apply.sh - apply ONLY the runtime/main tree, ONLY when it exactly
# matches origin/main with a clean working tree.
#
# Guards (any failure aborts before touching AWS):
#   1. target dir is the canonical runtime tree
#   2. checked-out branch is 'main'
#   3. local HEAD == origin/main (after fetch)
#   4. working tree is clean (no drift, no untracked files)
#   5. interactive confirmation (unless --auto-approve AND CC_ALLOW_AUTO=1)
#
# The applied commit id, operator, timestamp and result are logged for audit.
#
# Usage:
#   sudo -u tfexec ./terraform-apply.sh [tf-subdir] [--auto-approve]
#
# Example:
#   sudo -u tfexec ./terraform-apply.sh envs/prod
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

do_apply() {
    local subdir="$1" auto="$2"
    require_cmd terraform git
    require_dir "$CC_RUNTIME"

    local tf_dir="${CC_RUNTIME}/${subdir}"
    require_dir "$tf_dir"

    # --- Guard 2: branch must be main -------------------------------------
    local branch; branch="$(current_branch "$CC_RUNTIME")"
    [ "$branch" = "main" ] || die "runtime is on '${branch}', not 'main'; refusing to apply"

    # --- Guard 3: must equal origin/main ----------------------------------
    log_info "verifying runtime is in sync with origin/main"
    git -C "$CC_RUNTIME" fetch origin --prune
    local local_head remote_head
    local_head="$(git -C "$CC_RUNTIME" rev-parse HEAD)"
    remote_head="$(git -C "$CC_RUNTIME" rev-parse origin/main)"
    if [ "$local_head" != "$remote_head" ]; then
        die "runtime HEAD (${local_head}) != origin/main (${remote_head}); run sync-main.sh first"
    fi

    # --- Guard 4: clean working tree --------------------------------------
    assert_clean "$CC_RUNTIME"

    # --- Audit header ------------------------------------------------------
    local who stamp logfile
    who="$(id -un)${SUDO_USER:+ (via sudo from ${SUDO_USER})}"
    stamp="$(date +'%Y%m%d-%H%M%S')"
    logfile="${CC_LOGDIR}/apply-${local_head:0:12}-${stamp}.log"
    log_to_file "$logfile"
    log_info "APPLY commit=${local_head} dir=${tf_dir} operator=${who}"

    pushd "$tf_dir" >/dev/null
    trap 'popd >/dev/null || true' EXIT

    terraform init -input=false -reconfigure
    terraform validate
    terraform plan -input=false -lock-timeout=120s -out=runtime.tfplan

    if [ "$auto" -eq 1 ] && [ "${CC_ALLOW_AUTO:-0}" -eq 1 ]; then
        log_warn "auto-approve enabled (CC_ALLOW_AUTO=1)"
    else
        # Independent apply-time confirmation, separate from PR approval.
        local reply
        read -r -p "Apply commit ${local_head:0:12} to AWS? type 'apply' to proceed: " reply
        [ "$reply" = "apply" ] || die "apply not confirmed; aborting"
    fi

    terraform apply -input=false -lock-timeout=120s runtime.tfplan
    log_info "APPLY OK commit=${local_head} operator=${who}"
}

main() {
    local subdir="." auto=0 arg
    for arg in "$@"; do
        case "$arg" in
            --auto-approve) auto=1 ;;
            -*) die "unknown option: ${arg}" ;;
            *)  subdir="$arg" ;;
        esac
    done
    # Serialize applies against syncs and other applies on the runtime tree.
    with_lock "runtime" do_apply "$subdir" "$auto"
}

main "$@"
```

### `scripts/docker-build.sh`

```bash
#!/usr/bin/env bash
# docker-build.sh - build a container image from a Containerfile/Dockerfile.
#
# Engine-agnostic: prefers `podman` (the supported engine on RHEL 9) and falls
# back to `docker` if that is what is installed. The Dockerfile/Containerfile
# syntax is identical for both.
#
# Tagging policy:
#   - built from runtime/main  -> <image>:<commit-sha>  AND  <image>:latest
#   - built from a dev worktree-> <image>:dev-<user>-<branch>-<shortsha>
#
# Usage:
#   ./docker-build.sh <context-dir> <image-name> [-f <dockerfile>] [--push <registry>]
#
# Examples:
#   ./docker-build.sh /opt/codecommit/runtime/main myapp
#   ./docker-build.sh /opt/codecommit/worktrees/alice/feature-x myapp -f build/Dockerfile
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

detect_engine() {
    if command -v podman >/dev/null 2>&1; then printf 'podman\n'
    elif command -v docker >/dev/null 2>&1; then printf 'docker\n'
    else die "no container engine found (install podman)"
    fi
}

is_runtime() {
    case "$(realpath "$1")" in
        "$(realpath "$CC_RUNTIME")"*) return 0 ;;
        *) return 1 ;;
    esac
}

main() {
    local context="" image="" dockerfile="" push_registry=""
    local args=("$@")
    local i=0
    while [ "$i" -lt "${#args[@]}" ]; do
        case "${args[$i]}" in
            -f)     i=$((i+1)); dockerfile="${args[$i]}" ;;
            --push) i=$((i+1)); push_registry="${args[$i]}" ;;
            -*)     die "unknown option: ${args[$i]}" ;;
            *)
                if [ -z "$context" ]; then context="${args[$i]}"
                elif [ -z "$image" ]; then image="${args[$i]}"
                else die "too many positional arguments"
                fi ;;
        esac
        i=$((i+1))
    done
    [ -n "$context" ] && [ -n "$image" ] || die "usage: $0 <context-dir> <image-name> [-f dockerfile] [--push registry]"
    require_dir "$context"

    local engine; engine="$(detect_engine)"
    : "${dockerfile:=${context}/Dockerfile}"
    [ -f "$dockerfile" ] || dockerfile="${context}/Containerfile"
    [ -f "$dockerfile" ] || die "no Dockerfile/Containerfile at ${context}"

    local branch sha tag stamp logfile
    branch="$(current_branch "$context")"
    sha="$(short_sha "$context")"
    stamp="$(date +'%Y%m%d-%H%M%S')"

    if is_runtime "$context"; then
        [ "$branch" = "main" ] || die "runtime build must be on main (got ${branch})"
        assert_clean "$context"
        tag="${image}:${sha}"
        log_info "OFFICIAL build from runtime/main -> ${tag} (+ :latest)"
    else
        # Derive the owning user from the worktrees path layout.
        local user; user="$(realpath "$context" | sed -E "s#^$(realpath "$CC_WORKTREES")/([^/]+)/.*#\1#")"
        tag="${image}:dev-${user}-${branch//\//-}-${sha}"
        log_info "DEV build from ${context} -> ${tag}"
    fi

    logfile="${CC_LOGDIR}/build-${image}-${sha}-${stamp}.log"
    log_to_file "$logfile"
    log_info "engine=${engine} dockerfile=${dockerfile} commit=${sha}"

    "$engine" build -t "$tag" -f "$dockerfile" \
        --label "org.opencontainers.image.revision=$(head_sha "$context")" \
        --label "git.branch=${branch}" \
        "$context"

    if is_runtime "$context"; then
        "$engine" tag "$tag" "${image}:latest"
    fi

    if [ -n "$push_registry" ]; then
        # ECR example: authenticate first, then push.
        #   aws ecr get-login-password --region <r> | podman login --username AWS --password-stdin <registry>
        local remote="${push_registry}/${tag}"
        log_info "pushing ${remote}"
        "$engine" tag "$tag" "$remote"
        "$engine" push "$remote"
    fi

    log_info "build complete: ${tag}"
    printf '%s\n' "$tag"
}

main "$@"
```

---

## 13. 動作原理と動作イメージ（テキスト図）

全体の流れ:

```
開発者(alice)
  │ create-worktree.sh alice feature/add-vpc
  ▼
開発用ディレクトリ  worktrees/alice/feature-add-vpc   (branch: feature/add-vpc)
  │ terraform-plan.sh  →  fmt / validate / plan（apply はできない）
  │ docker-build.sh    →  myapp:dev-alice-feature-add-vpc-<sha>
  ▼
git push origin feature/add-vpc        (HTTPS-GRC / IAM 認証)
  │
  ▼
CodeCommit で Pull Request 作成  (feature/add-vpc → main)
  │
  ▼
レビュー・承認  (Bob が承認。作者 alice は自承認不可 = 実質2名)
  │ 承認ルールを満たす
  ▼
main へマージ        ← ここで初めて「本番に出てよいコード」になる
  │
  ▼
sync-main.sh (systemd timer, 5分間隔, flock)
  fetch → reset --hard origin/main → clean -fdx
  │ logs/sync-main.log に before→after コミットID
  ▼
runtime/main          (branch: main, origin/main と byte 一致, 開発者は読取専用)
  │ terraform-apply.sh (tfexec, sudo)  多重ガード:
  │    branch==main / HEAD==origin/main / clean / 確認プロンプト
  │ docker-build.sh runtime/main myapp  →  myapp:<sha> + :latest
  ▼
AWS 環境へ反映   (S3 state + use_lockfile / ECR / 各種リソース)
  │ logs/apply-<sha>-<時刻>.log に commit/実行者/日時/結果
  ▼
CloudTrail / CloudWatch Logs / auditd と突合して監査
```

ガードがどこで効くか（apply の関門）:

```
terraform-apply.sh 起動
  ├─ [G1] 対象は runtime/main か？           ─no→ 中止
  ├─ [G2] checkout ブランチ == main か？      ─no→ 中止
  ├─ [G3] fetch 後 HEAD == origin/main か？   ─no→ 中止（sync-main.sh を促す）
  ├─ [G4] 作業ツリーは clean か？             ─no→ 中止（差分を表示）
  ├─ [G5] 実行者は tf-approvers か？(sudoers)  ─no→ sudo 拒否
  └─ [G6] "apply" と入力したか？(確認)         ─no→ 中止
        └─ すべて通過 → terraform apply 実行 → ログ記録
```

---

## 14. セキュリティ設計

**IAM ポリシー（最小権限）。**
- EC2 インスタンスプロファイルには「state バケットの読み書き」「CodeCommit の読み（fetch）」「必要な AWS リソース操作」を最小付与。
- 強い操作（本番リソースの作成・削除）は **tfexec が assume する別ロール** に寄せ、インスタンスロール自体は弱くする。
- apply 用ロールと plan 用ロールを分け、plan は read-only に近い権限にするのが理想。

**CodeCommit アクセス権限。**
- 認証は **git-remote-codecommit（HTTPS-GRC）** + IAM。SSH 鍵や HTTPS Git 認証情報を個別配布しない。
- 開発者ロールは「push / PR 作成・承認」、運用ロールは「読み取り」を基本に分離。

**PR 承認ルール / main 保護。**
- 承認ルールテンプレートで「**1名以上の承認**」を main 向け PR に必須化。
- **main への直接 push 禁止**（ブランチに対する `GitPush` を Deny する IAM 条件、または承認ルールで実質強制）。
- 前述の通り **作者は自分の PR を承認できない**ため、1承認ルールでも実質2名が必要。承認者を `tf-approvers` 相当に限定。

**EC2 / 認証。**
- アクセスキーをディスクに置かない（インスタンスプロファイル）。
- 接続は **SSM Session Manager**（SSH ポート閉鎖、踏み台不要、操作は CloudTrail/CloudWatch に記録）。
- どうしても SSH を使う場合は鍵を IAM/SSM 管理にし、22番は特定 IP に限定。

**Terraform backend / state。**
- S3: versioning ON・SSE-KMS・パブリックアクセス全ブロック・バケットポリシーで principal 限定。
- ロックは `use_lockfile = true`（DynamoDB 不要、§0）。
- state は機密。閲覧権限を絞り、`terraform output` の機密値もログに出さない。

**コンテナ権限の危険性（RHEL 9 観点）。**
- RHEL 9 は **rootless podman** が基本。`docker` デーモン/`docker` グループ（= 実質 root 付与）を作らないこと自体が安全。
- どうしても docker を入れる場合、`docker` グループ加入は root 相当の権限付与と同義であり厳禁レベルで慎重に。
- イメージの `--privileged` 実行や `/var/run/*.sock` のマウントは原則禁止。

**sudoers の限定。** `(ALL) NOPASSWD: ALL` は厳禁。`terraform-apply.sh` への `(tfexec)` 限定 sudo のみ許可（§7・`sudoers.d/codecommit-ops`）。コマンド引数も固定する。

**実行ログの改ざん防止。**
- `logs/` は append 運用。重要ログは CloudWatch Logs に転送し、サーバー上で消されても残す。
- auditd ログは `auditd` の immutable モード（`-e 2`）で当日分の改ざんを抑止。
- S3/CloudWatch 側でログ削除権限を運用者から外す。

**CloudTrail / CloudWatch Logs / auditd 連携。** §15 参照。

**ネットワーク。** セキュリティグループは最小（SSM 利用なら 22 番不要）。VPC エンドポイント（S3/CodeCommit/SSM/CloudWatch）で AWS API をプライベート経路に。

---

## 15. 監査・ログ・証跡管理

「いつ・誰が・何を・どのコミットで」を多層で残し、相互に突合できる状態を作る。

| 層 | ログ源 | 何が分かるか |
|---|---|---|
| アプリ（本ツール） | `/opt/codecommit/logs/*.log` | plan/apply/build/sync の commit ID・実行者・日時・結果 |
| OS 操作 | auditd（`/var/log/audit/audit.log`） | 実行コマンド、ファイルアクセス、誰が何を |
| 権限昇格 | sudo ログ（`/var/log/secure`） | 誰が `sudo -u tfexec` したか |
| シェル | 各ユーザー history（集中管理推奨） | 入力コマンド列 |
| AWS API | CloudTrail | 実際に呼ばれた AWS API（apply の実体） |
| 集約 | CloudWatch Logs | 上記を集約・保全・検索 |

**実装のポイント。**
- スクリプトは `log_to_file` で `logs/` に追記しつつ標準出力にも出す。apply は **コミット ID をファイル名とログ先頭に必ず記録**。
- auditd ルール例（運用スクリプトと runtime を監視）:
  ```
  -w /opt/codecommit/runtime/main -p wa -k cc_runtime
  -w /opt/codecommit/scripts -p wa -k cc_scripts
  -a always,exit -F path=/opt/codecommit/scripts/terraform-apply.sh -F perm=x -k cc_apply
  ```
- CloudWatch Agent で `logs/`・`/var/log/secure`・`/var/log/audit/audit.log` を集約。
- 「PR の誰が承認したか」は CodeCommit / CloudTrail 側に残る。OS 側の apply ログと PR の承認記録を **コミット ID をキーに突合**できる。

---

## 16. 運用時の注意点

- **runtime/main で直接編集しない。** `reset --hard`/`clean -fdx` で消える＆未承認コードの本番流出。所有権で物理的に禁止。
- **main 以外で `terraform apply` しない。** `terraform-apply.sh` がガードするが、素の `terraform apply` を手で打たない規律も重要。
- **共通 Linux ユーザーで作業しない。** 監査が崩壊する。必ず個人アカウント。
- **docker グループに安易に追加しない。** root 相当。RHEL 9 では rootless podman を使い、そもそも docker を入れない。
- **state をローカルに置かない。** 競合・消失・機密漏洩。必ず S3 リモート + ロック。
- **`git pull` だけの運用にしない。** `pull` は merge/rebase を伴い、runtime に予期せぬローカルマージ状態を作りうる。runtime は必ず `fetch + reset --hard` で「origin/main にする」。
- **`git reset --hard` / `git clean -fdx` の使いどころ。** これらは破壊的。**runtime/main 専用**の操作と心得る。開発 worktree でうかつに打つと作業が消える。`sync-main.sh` 以外でこれらを runtime に打たない。
- **PR 承認と apply 承認を分けるか。** 推奨は **分ける**。PR 承認＝コードの正しさ、apply 承認＝「今このタイミングで本番に当ててよいか」。`tf-approvers` による sudo apply と apply 時確認プロンプトで後者を担保。
- **開発と運用実行の同居リスク。** §3 の通り。権限・ディレクトリ・ログ・実行制御・承認で低減するが、本番の重要度が上がったら **実行専用サーバーを分離**するのが本筋。
- **Terraform/Podman のバージョン固定。** `required_version` とエンジンバージョンを固定し、開発と runtime で揃える。
- **plan ファイル・ログの機密。** plan/state には機密が入りうる。`logs/`・plan ファイルの権限を絞り、不要になったものは安全に削除。

---

## 17. アンチパターン（やりがちな失敗）

1. **「とりあえず全員 wheel/docker グループ」** → 実質全員 root。最初に効かせるべき分離が崩壊。
2. **runtime/main を開発者が書き込み可能にする** → 直接編集事故・未承認コード流出。
3. **main 直 push を許す** → レビューを通らないコードが本番ソースになる。
4. **state をローカル or 暗号化なし S3** → 競合・漏洩・復旧不能。
5. **共通アカウント運用** → 監査不能。インシデント時に犯人特定も巻き戻し責任も曖昧。
6. **apply を素の `terraform apply` で手打ち** → ガードを迂回し、未同期ブランチを誤適用。
7. **`git pull` で runtime を更新** → ローカルマージ・コンフリクト解決が runtime に残留。
8. **コミット ID を記録しない apply** → 障害の原因コミット特定・巻き戻しができない。
9. **承認ルールを「1名」にして作者自承認を期待** → CodeCommit は自承認不可。実質2名要る前提を見落とす。
10. **RHEL 9 に無理やり Docker を入れて daemon 運用** → 非サポート・攻撃面増。Podman を使うべき。
11. **DynamoDB ロックを新規に作る** → deprecated。`use_lockfile` を使う。
12. **開発と本番 state を同一 workspace で混在** → 誤適用の影響範囲が読めない。環境はディレクトリ分割。

---

## 18. より良い将来構成（CI/CD への発展）

本構成は「人力 CD」であり、CI/CD への踏み台として自然に発展できる。移行の勘所:

- **CI（プラン自動化）**: PR 作成時に CodeBuild / GitHub Actions が `fmt`/`validate`/`plan` を自動実行し、結果を PR にコメント。`terraform-plan.sh` のロジックがほぼそのまま移植できる。
- **CD（適用自動化）**: main マージを契機に CodePipeline / Actions が apply。**`terraform-apply.sh` の呼び出し元を人間から CI に置き換えるだけ**で、ガード（main 一致・clean・コミット記録）の思想は流用できる。
- **承認ゲート**: CodePipeline の手動承認アクション、または Actions の Environments + required reviewers で「apply 承認」を CI 上に再現。PR 承認（コード）と apply 承認（タイミング）の二段を維持。
- **実行点の分離**: 運用管理サーバーでの apply を、CI のエフェメラルランナー（使い捨て実行環境）に移すと、サーバー常駐の認証情報・実行権限を排除でき、攻撃面が大幅に減る。
- **state/ロック**: S3 + `use_lockfile` はそのまま。並行実行が増えるなら `-lock-timeout` を調整。
- **コンテナ**: `docker-build.sh` の podman build → ECR push を CI に移し、イメージ署名（cosign）や脆弱性スキャン（trivy/inspector）を挟む。
- **ポリシー as code**: OPA/Conftest や Sentinel で「禁止リソース」「タグ必須」等を plan 段階で機械チェック。
- **CodeCommit の将来**: 2026 に Git LFS 等の機能追加が予告されている。AWS 完結を重視するなら CodeCommit + CodePipeline、エコシステム重視なら GitHub + Actions、のいずれかへ。

---

## 19. まとめ（結論）

**最も安全な構成。**
- 実行専用サーバーを開発サーバーから分離。apply は CI のエフェメラルランナー＋手動承認ゲート。
- 認証は IAM ロールのみ（キー無し）、接続は SSM、main 直 push 禁止＋PR 承認必須（実質2名）。
- state は S3（versioning+KMS+ブロック+`use_lockfile`）。rootless podman、イメージ署名・スキャン。
- 全操作を CloudTrail/auditd/CloudWatch で集約・改ざん防止。

**最も運用しやすい構成（本ガイドの主推奨）。**
- 1台の RHEL 9.6 に `/opt/codecommit/`（bare + worktrees + runtime + scripts + logs/locks）。
- 開発: 個人アカウント + `codecommit-dev` グループ + worktree。検証は `terraform-plan.sh`。
- 反映: `sync-main.sh`（systemd timer, flock）→ `terraform-apply.sh`（多重ガード, tfexec sudo）。
- 開発と運用の同居リスクは権限・ディレクトリ・ログ・承認で低減。

**最小構成で始める場合。**
- bare + `runtime/main` + 個人 worktree + 4スクリプト（`setup.sh`/`sync-main.sh`/`create-worktree.sh`/`terraform-apply.sh`）。
- timer の代わりに apply 直前に手動 `sync-main.sh`。state は S3+`use_lockfile`。
- 承認は CodeCommit の 1 承認ルール（=実質2名）から。

**将来 CI/CD へ移行する場合。**
- `terraform-plan.sh`/`terraform-apply.sh` のガードロジックを CodeBuild/Actions に移植。
- apply 呼び出しを人間→CI に置換。手動承認ゲートで apply 承認を維持。
- 実行をエフェメラルランナーへ。サーバー常駐権限を排除。

**この方式で必ず守るべきルール。**
1. **本番に出るコードは main にだけ存在する。** main 直 push 禁止、PR 承認必須。
2. **apply は runtime/main からのみ。** branch==main・HEAD==origin/main・clean を満たす時だけ。
3. **runtime/main は人が編集しない。** 更新は `sync-main.sh` の `fetch + reset --hard + clean` のみ。
4. **共通アカウント・無制限 sudo・docker グループ濫用をしない。** 個人アカウント＋限定 sudo＋rootless podman。
5. **どのコミットを適用したか必ず記録する。** apply/build ログにコミット ID・実行者・日時・結果。
6. **state はリモート＋ロック＋暗号化。** ローカル state 禁止、`use_lockfile` を使う。
7. **`reset --hard` / `clean -fdx` は runtime 専用の破壊的操作と心得る。**

---

### 付録: 同梱ファイル

```
codecommit-ops/
├── DESIGN.md                       # 本ドキュメント
├── scripts/
│   ├── common.sh                   # 共有関数（source 専用）
│   ├── setup.sh                    # 初期セットアップ（冪等）
│   ├── create-worktree.sh
│   ├── delete-worktree.sh
│   ├── sync-main.sh
│   ├── terraform-plan.sh
│   ├── terraform-apply.sh
│   └── docker-build.sh             # podman 優先のエンジン非依存
├── systemd/
│   ├── codecommit-sync.service
│   └── codecommit-sync.timer       # 5分間隔で sync-main を実行
├── sudoers.d/
│   └── codecommit-ops              # apply を tf-approvers→tfexec に限定
└── terraform/
    └── backend.tf.example          # S3 + use_lockfile（DynamoDB不要）
```

すべてのシェルスクリプトは `shellcheck -x` をパス済み。`setup.sh` は冪等で、再実行しても既存資産を壊さない。
