# CQRS ES Example Swift

SwiftとVaporで構築されたCQRS（コマンドクエリ責任分離）とイベントソーシングのサンプルアプリケーションです。AWS Lambda上で動作し、OpenTelemetryによる分散トレーシングをサポートしています。

## アーキテクチャ

- **コマンドサーバー**: 書き込み操作を処理（`Sources/Command/Server/`）
- **クエリサーバー**: 読み取り操作を処理（`Sources/Query/Server/`）
- **インフラ**: Terraform + SAMによるハイブリッド構成
- **CI/CD**: AWS CodePipelineによる自動デプロイ

## 前提条件

### 1. AWSアカウントとツール
- AWSアカウントと認証情報の設定
- AWS CLI（設定済み）
- AWS SAM CLI
- Terraform または OpenTofu（tofu）
- Docker

### 2. GitHub接続の作成（初回のみ）

AWS CodePipelineがGitHubリポジトリにアクセスするための接続を作成します：

1. AWSコンソールにログイン
2. CodePipelineサービスを開く
3. 左メニューから「設定」→「接続」を選択
4. 「接続を作成」をクリック
5. 以下の設定で作成：
   - プロバイダー: GitHub
   - 接続名: `github`（この名前は重要）
   - GitHubアプリをインストールして認証
6. 接続が「利用可能」ステータスになることを確認

## デプロイ手順

### 1. Terraformでインフラ構築

```bash
cd Server/AWS
tofu init
tofu plan
tofu apply
```

これにより以下が作成されます：
- ECRリポジトリ（Dockerイメージ用）
- CodePipeline（CI/CD）
- CodeBuildプロジェクト
- CloudWatch Logsリソースポリシー（X-Ray OTLP用）
- Application Signals設定

### 2. X-Ray OTLPの有効化（初回のみ）

```bash
aws xray update-trace-segment-destination \
  --destination CloudWatchLogs \
  --region ap-northeast-1
```

**注意**: リージョンごとに一度だけ実行が必要です。

### 3. ローカルでのビルドとテスト

```bash
# Swiftプロジェクトのビルド
cd Server
swift build

# テストの実行
swift test

# フォーマットチェック
swift format lint -r .

# SAMテンプレートの検証
sam validate --lint
```

### 4. デプロイ

mainブランチにpushすると自動的にデプロイが開始されます：

```bash
git add .
git commit -m "Deploy changes"
git push origin main
```

**デプロイプロセス**：
1. CodePipelineが変更を検出
2. DockerイメージをビルドしてECRにプッシュ（約15分）
3. SAMでLambda関数をデプロイ
4. API Gatewayエンドポイントが更新

## ローカル開発

### Swiftでの開発

```bash
cd Server
swift build
swift run CommandServer  # ポート3001で起動
swift run QueryServer    # ポート3002で起動
```

### OpenTelemetryトレーシング（ローカル）

```bash
# Jaeger All-in-Oneを起動
docker compose up -d jaeger

# 環境変数を設定してサーバーを起動
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318 swift run CommandServer
```

Jaeger UI: http://localhost:16686

## デプロイ後の確認

### APIエンドポイントの取得

```bash
aws cloudformation describe-stacks \
  --stack-name Stage \
  --query 'Stacks[0].Outputs[?OutputKey==`ServerHttpApiUrl`].OutputValue' \
  --output text
```

### ログの確認

```bash
# CommandServerのログ
aws logs tail /aws/lambda/Stage-CommandServerFunction --follow

# QueryServerのログ
aws logs tail /aws/lambda/Stage-QueryServerFunction --follow
```

### X-Rayトレースの確認

1. AWS X-Rayコンソールを開く
2. サービスマップで「CommandServer」または「QueryServer」を確認
3. トレースリストでリクエストの詳細を確認

## トラブルシューティング

### X-Ray OTLPエラー

エラー: `The OTLP API is supported with CloudWatch Logs as a Trace Segment Destination`

→ 「X-Ray OTLPの有効化」セクションのコマンドを実行してください。

### デプロイエラー

1. CloudFormationコンソールでスタック「Stage」のイベントを確認
2. CodePipelineコンソールでビルドログを確認
3. ECRにDockerイメージが正しくプッシュされているか確認

### 認証エラー

エラー: `ExpiredToken`

→ AWS認証情報を更新してください。

## リソースの削除

```bash
# SAMスタックの削除
sam delete --stack-name Stage

# Terraformリソースの削除
cd Server/AWS
tofu destroy
```

**注意**: ECRリポジトリにイメージが残っている場合は、先に削除する必要があります。