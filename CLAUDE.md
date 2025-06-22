# CLAUDE.md

このファイルは、このリポジトリでコードを扱う際のClaude Code（claude.ai/code）へのガイダンスを提供します。

## 重要な注意事項

### .envファイルについて
**絶対に編集・削除してはいけないファイル:**
- `/claude/workspace/.env` - Claude Codeが正常に動作するために必要な環境変数が含まれています
- プロジェクトルートの`.env` - 同様に重要な設定が含まれています

これらのファイルにはGitHub連携などClaude Codeの動作に必要な認証情報が含まれているため、変更すると機能が正常に動作しなくなります。

## プロジェクト概要

SwiftとVaporで構築されたCQRS（コマンドクエリ責任分離）とイベントソーシングのサンプルアプリケーションです。AWS Lambdaにデプロイされ、独立したコマンドサーバーとクエリサーバーを持つマイクロサービスアーキテクチャを実証しています。

### アーキテクチャ

- **コマンドサーバー** (`Sources/Command/Server/`): 書き込み操作を処理、OpenAPI仕様使用、OpenTelemetryトレーシング実装
- **クエリサーバー** (`Sources/Query/Server/`): 読み取り操作を処理、Fluent経由でPostgreSQLと統合
- **独立したデプロイメント**: 各サーバーはAPI Gatewayの背後で独立したLambda関数として実行

## 開発環境

### 必須ツール
- Swift 6.1
- Docker Compose v2（`docker compose`コマンド）
- OpenTofu（Terraformの代替）
- AWS SAM CLI
- GitHub MCPおよびAWS MCP（ドキュメント閲覧用）

### コード品質チェック
コード変更時は以下のコマンドがパスする必要があります：

```bash
# Swift関連
swift format lint -r .     # (/claude/workspace/Server)
swift build               # (/claude/workspace/Server)
swift test                # (/claude/workspace/Server) - 12テスト

# インフラ関連
tofu fmt                  # (/claude/workspace/Server/AWS)
sam validate --lint       # (/claude/workspace/Server)

# OpenAPI
openapi-generator validate -i ./Server/Sources/Command/Server/openapi.yaml
```

### Swift Formatの注意点
- `case .enum(let value)`形式を使用（`case let`は避ける）
- 長い行は適切に改行（100文字制限）
- `.swift-format`で`ReplaceForEachWithForLoop: false`を設定済み（SpanAttributes対応）

## CI/CDパイプライン

**AWS CodePipeline**を使用（GitHub Actionsは使用していません）

### デプロイフロー
1. **Source**: GitHubの`main`ブランチを監視
2. **Build**: 並列でDockerイメージビルドとSAMパッケージング
3. **Deploy**: CloudFormationで`Stage`スタックをデプロイ

**注意**: mainブランチへのpushで自動デプロイが実行されます（ビルド時間：約15分）

### 現在のステータス（2025年1月）
- ✅ ビルド状態：正常
- ✅ テスト：12テストすべてパス
- ✅ X-Rayトレース：OTLP/HTTP + SigV4認証で実装完了
- ✅ swift-distributed-tracing：1.0.0準拠で実装完了

## OpenTelemetryとトレーシング

### 実装概要
- **swift-distributed-tracing 1.0.0**準拠
- OpenTelemetryとのブリッジ実装（`DistributedTracingAdapter.swift`）
- Vaporミドルウェア統合（`DistributedTracingMiddleware.swift`）
- @unchecked Sendableを使わない設計（structとactorベース）

### Lambda環境での動作
- AWS X-Ray OTLPエンドポイント使用：`https://xray.{region}.amazonaws.com/v1/traces`
- SigV4認証の独自実装（AWS SDKとの依存関係競合を回避）
- Fire-and-forget方式の非同期送信
- service.nameは固定値`"CommandServer"`を使用

### ローカル開発環境（Jaeger）
- JaegerコンテナでOTLP/HTTPエンドポイントを提供（ポート4318）
- `OTEL_EXPORTER_OTLP_ENDPOINT=http://172.17.0.1:4318`で接続（Dockerコンテナ内から）
- JaegerOTLPExporter実装でローカルトレーシングをサポート
- Jaeger UI: http://localhost:16686
- 起動方法：`docker compose up -d` (Server/compose.yaml)

### 必要な設定

#### 1. X-Ray OTLP有効化（リージョンごとに一度だけ実行）
```bash
aws xray update-trace-segment-destination \
  --destination CloudWatchLogs \
  --region ap-northeast-1
```

#### 2. 環境変数（SAM template.yaml）
```yaml
Environment:
  Variables:
    AWS_XRAY_CONTEXT_MISSING: LOG_ERROR
    OTEL_EXPORTER_OTLP_ENDPOINT: !Sub https://xray.${AWS::Region}.amazonaws.com
    OTEL_PROPAGATORS: xray
    OTEL_METRICS_EXPORTER: none
    OTEL_AWS_APPLICATION_SIGNALS_ENABLED: true
    OTEL_RESOURCE_ATTRIBUTES: service.name=CommandServer
```

### トレースのデバッグ
成功時のログ例：
```
📦 Exporting 2 spans to X-Ray
✅ X-Ray API response: 200
✅ Exported 2 spans to X-Ray successfully
```

トレースIDは32文字の16進数形式（例：`6857c002177f7ce15f64b8fa78ecf4d9`）

## インフラ構成

### Terraform（AWS/main.tf）
- Application Signals Discovery
- CloudWatch LogsリソースポリシーforX-Ray
- ECRリポジトリ
- CodePipeline、CodeBuild
- IAMロール（super_role）

### SAM（template.yaml）
- Lambda関数定義
- API Gateway（HttpApi）
- 環境変数
- IAM権限（実行ロール）

## 重要な実装詳細

### 依存関係
- **swift-distributed-tracing**: Apple公式の分散トレーシング標準API
- **OpenTelemetry Swift**: トレーシングバックエンド実装
- **AsyncHTTPClient**: Lambda環境でのHTTP通信（URLSession非対応のため）
- **swift-crypto**: SigV4署名実装用

### 既知の問題と対策
1. **接続タイムアウト**: コールドスタート時に発生可能性あり
2. **Hostヘッダー**: AsyncHTTPClient使用時は明示的に追加が必要
3. **Lambda実行時間**: Task.detached処理が中断される可能性

### Vaporとトレーシングの統合
1. **Vapor標準機能の活用**
   - VaporのTracingMiddlewareを使用（カスタム実装は不要）
   - Request.serviceContextが標準で提供されている
   - ServiceContext.withValueでコンテキスト伝播を実現
   
2. **X-Rayヘッダーの処理**
   - InstrumentationSystem.Instrumentのextractメソッドで実装
   - Extractorプロトコルを使用してヘッダーから値を取得
   - キャストではなくExtractorのメソッドを使用すること
   
3. **ミドルウェアの順序**
   ```swift
   app.traceAutoPropagation = true  // トレースの自動伝搬を有効化
   app.middleware.use(TracingMiddleware())  // Vaporの標準
   app.middleware.use(VaporRequestMiddleware())  // ServiceContext伝播用
   ```
   
4. **X-RayトレースIDの伝搬**
   - X-Ray形式（`1-XXXXXXXX-YYYYYYYY`）とOpenTelemetry形式の変換が必要
   - XRayContextに元のX-Ray形式を保存して一貫性を保つ
   - `withSpan`でコンテキストを明示的に渡すことが重要
   - 大文字小文字両方のX-Rayヘッダーに対応（`X-Amzn-Trace-Id`、`x-amzn-trace-id`）

### デバッグログのベストプラクティス
- 絵文字を効果的に使用（🚀起動、✅成功、❌エラー、📦バッチ処理など）
- 1行で情報を集約して可読性向上
- Fire-and-forgetパターンでは結果を簡潔にログ出力