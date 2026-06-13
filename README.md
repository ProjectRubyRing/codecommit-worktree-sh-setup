# codecommit-ops

RHEL 9.6 の EC2「運用管理サーバー」上で、AWS CodeCommit の Terraform/Dockerfile を
**承認済み PR が main にマージされたコードだけ** 実行するための運用一式。

- `DESIGN.md` — 設計ガイド全文（全19章 + 最新情報の前提、テキスト図、全スクリプト埋め込み）
- `scripts/` — 実行スクリプト（すべて `shellcheck -x` パス済み、`set -euo pipefail`）
- `systemd/` — `sync-main` を5分間隔で回すタイマー
- `sudoers.d/` — apply を `tf-approvers → tfexec` に限定する例
- `terraform/backend.tf.example` — S3 ネイティブロック（`use_lockfile`、DynamoDB 不要）

## クイックスタート

```bash
# 1) スクリプトを設置（root で一度だけ。冪等）
sudo ./scripts/setup.sh codecommit::ap-northeast-1://infra

# 2) 自動同期を有効化
sudo cp systemd/codecommit-sync.* /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now codecommit-sync.timer

# 3) apply の限定 sudo を設定
sudo install -m 0440 sudoers.d/codecommit-ops /etc/sudoers.d/codecommit-ops

# 開発者の流れ
sudo /opt/codecommit/scripts/create-worktree.sh alice feature/add-vpc
/opt/codecommit/scripts/terraform-plan.sh /opt/codecommit/worktrees/alice/feature-add-vpc envs/prod
# (push → CodeCommit で PR → 承認 → main マージ)
# 承認者が本番反映
sudo -u tfexec /opt/codecommit/scripts/terraform-apply.sh envs/prod
```

## 重要な前提（2026-06 時点）
- AWS CodeCommit は 2025-11 に GA 復帰。新規アカウントでも利用可。
- Terraform S3 backend は `use_lockfile`（ネイティブロック）が標準。DynamoDB ロックは deprecated。
- RHEL 9 では Docker 非サポート。Podman（rootless）が標準。Dockerfile はそのまま使える。

詳細・根拠・注意点・アンチパターンは `DESIGN.md` を参照。
