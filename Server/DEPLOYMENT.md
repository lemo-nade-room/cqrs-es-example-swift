# X-Ray統合デプロイガイド

## 現在の実装状況

### ✅ 実装済み
- OpenTelemetry Swift統合
- AWS SigV4認証実装
- X-Ray OTLPエクスポーター構造
- Lambda環境検出
- AsyncHTTPClientベースの実装

### ⚠️ 制限事項
- トレースデータの実際の送信は未実装（プレースホルダー状態）
- Lambda環境では "Would export X spans" のログが出力される
- ローカル環境では自動的にスキップ

## デプロイ手順

### 1. 事前準備

```bash
# AWS CLIの設定確認
aws configure list

# SAMの初期化（初回のみ）
cd /claude/workspace/Server
sam init
```

### 2. ビルドとデプロイ

```bash
# ビルド
sam build

# デプロイ（初回）
sam deploy --guided

# デプロイ（2回目以降）
sam deploy
```

### 3. デプロイ時の設定

初回デプロイ時に以下を設定：
- Stack Name: `cqrs-event-sourcing-sample`
- AWS Region: `ap-northeast-1`（または任意のリージョン）
- Confirm changes before deploy: `Y`
- Allow SAM CLI IAM role creation: `Y`

### 4. 必要なIAMポリシー

Lambda実行ロールに以下の権限が必要：

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "xray:PutTraceSegments",
                "xray:PutTelemetryRecords"
            ],
            "Resource": "*"
        }
    ]
}
```

## 動作確認

### CloudWatch Logsでの確認

```bash
# Lambda関数のログを確認
aws logs tail /aws/lambda/CommandServer --follow

# 期待されるログ
# - "Configuring OpenTelemetry for Lambda environment"
# - "Would export X spans to X-Ray endpoint: https://xray.ap-northeast-1.amazonaws.com/v1/traces"
```

### API Gatewayでのテスト

```bash
# エンドポイントURLを取得
aws cloudformation describe-stacks \
  --stack-name cqrs-event-sourcing-sample \
  --query 'Stacks[0].Outputs[?OutputKey==`CommandApi`].OutputValue' \
  --output text

# テストリクエスト
curl -X POST https://[API-ID].execute-api.[REGION].amazonaws.com/Prod/command \
  -H "Content-Type: application/json" \
  -d '{"test": "data"}'
```

## トラブルシューティング

### よくある問題

1. **Lambda関数がタイムアウトする**
   - template.yamlでTimeoutを増やす（デフォルト: 30秒）

2. **メモリ不足エラー**
   - MemorySizeを増やす（推奨: 512MB以上）

3. **認証エラー**
   - IAMロールの権限を確認
   - 環境変数AWS_REGION が設定されているか確認

### デバッグモード

環境変数で詳細ログを有効化：

```yaml
Environment:
  Variables:
    LOG_LEVEL: DEBUG
    OTEL_LOG_LEVEL: debug
```

## 次のステップ

### Phase 1: 基本動作確認（現在可能）
- [ ] デプロイ実行
- [ ] CloudWatch Logsでログ確認
- [ ] API Gateway経由でのリクエストテスト

### Phase 2: トレース送信実装
- [ ] SyncExportAdapterの統合
- [ ] 実際のHTTP送信実装
- [ ] X-Rayコンソールでのトレース確認

### Phase 3: 本番対応
- [ ] バッチ処理の実装
- [ ] エラーハンドリング強化
- [ ] パフォーマンス最適化