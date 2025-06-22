# CLAUDE.md

このファイルは、このリポジトリでコードを扱う際のClaude Code（claude.ai/code）へのガイダンスを提供します。

## プロジェクト概要

これは、SwiftとVaporで構築されたCQRS（コマンドクエリ責任分離）とイベントソーシングのサンプルアプリケーションです。このプロジェクトは、SAM（サーバーレスアプリケーションモデル）を使用してAWS
Lambdaにデプロイされるように設計された、独立したコマンドサーバーとクエリサーバーを持つマイクロサービスアーキテクチャを実証しています。

## アーキテクチャ

プロジェクトはCQRS/ES原則に従っています：

- **コマンドサーバー** (`Sources/Command/Server/`): 書き込み操作を処理し、REST APIのためのOpenAPI仕様を使用し、OpenTelemetryによる分散トレーシングを含みます
- **クエリサーバー** (`Sources/Query/Server/`): 読み取り操作を処理し、Fluent経由でPostgreSQLデータベース統合を含みます
- **独立したデプロイメント**: 各サーバーはAPI Gatewayの背後で独立したLambda関数として実行されます

## 規則

- コード変更時には、影響箇所に応じて以下がパスする必要があります。
  - `swift format lint -r .` (/claude/workspace/Server) 
  - `swift build` (/claude/workspace/Server)
  - `swift test` (/claude/workspace/Server)
  - `tofu fmt` (/claude/workspace/Server/AWS)
  - `sam validate --lint` (/claude/workspace/Server)
  - `openapi-generator validate -i ./Server/Sources/Command/Server/openapi.yaml` (/claude/workspace)

## 環境

### コンテナ

この環境はコンテナ内にあり、ARM64 Ubuntu noble上での開発環境です。
コンテナ内ではありますが、dockerはrootlessで使用可能です

### Git

- pushすることはできませんが、commitすることは可能です。
- しかし、原則指示されていない場合に無断でcommitすることは許されていません。
- ghコマンドあるいはGitHub MCPを使用してGitHubを閲覧・操作することが可能です。

### Swift

- Swift 6.1を使用可能です。
- Vaporコマンドも利用可能です。

### AWS

- Terraformの代替としてOpenTofu(`tofu`)が使用可能です。
- AWS SAM CLIも使用可能です。
- TerraformやAWSのMCPを利用してドキュメントを閲覧可能です。

### X-Ray OTLP APIの要件

- AWS X-RayのOTLP APIを使用する場合、CloudWatch LogsをトレースデスティネーションとしてUpdateTraceSegmentDestination APIで有効化する必要があります
- エラー例: `The OTLP API is supported with CloudWatch Logs as a Trace Segment Destination.` (400 InvalidRequestException)
- CloudWatch LogsリソースポリシーでX-Rayサービスからのアクセスを許可する必要があります（Terraformで自動設定済み）

#### CloudWatch Logsリソースポリシーの注意点

- X-Rayは実際には`aws/spans`ロググループに書き込むため、ポリシーでこれを許可する必要がある
- 初回は`aws/xray/*`パターンでは不十分で、`AccessDeniedException`が発生する
- 現在は`resources = ["*"]`で全てのロググループへのアクセスを許可している

#### 手動設定方法

Terraformでリソースポリシーを適用した後、以下のコマンドを一度実行してください（リージョンごとに必要）：

```bash
aws xray update-trace-segment-destination \
  --destination CloudWatchLogs \
  --region ap-northeast-1
```

成功すると以下のレスポンスが返ります：
```json
{
    "Destination": "CloudWatchLogs",
    "Status": "PENDING"
}
```

この設定は永続的で、一度設定すればそのリージョンの全てのLambda関数に適用されます。

### TerraformとSAMの役割分担

**Terraform（AWS/main.tf）**
- Application Signals Discovery（アカウントレベルの設定）
- CloudWatch LogsリソースポリシーforX-Ray（OTLP API有効化のため）
- ECRリポジトリの管理
- CI/CDパイプライン（CodePipeline、CodeBuild）
- IAMロール（super_role）

**SAM（template.yaml）**
- Lambda関数の定義と設定
- API Gateway（HttpApi）
- 環境変数（OTEL関連）
- IAM権限（関数実行ロール）

### Lambda関数の環境変数設定

```yaml
Environment:
  Variables:
    # X-Ray設定
    AWS_XRAY_CONTEXT_MISSING: LOG_ERROR  # コンテキスト欠落時にエラーログのみ（クラッシュ防止）
    # OpenTelemetry設定
    OTEL_EXPORTER_OTLP_ENDPOINT: !Sub https://xray.${AWS::Region}.amazonaws.com
    OTEL_PROPAGATORS: xray  # X-RayトレースIDフォーマットを使用
    OTEL_METRICS_EXPORTER: none  # メトリクスエクスポートを無効化（トレースのみ）
    OTEL_AWS_APPLICATION_SIGNALS_ENABLED: true  # Application Signals有効化
    OTEL_RESOURCE_ATTRIBUTES: service.name=CommandServer  # サービス名（必須）
```

### IAM権限の設定

- `AWSXRayDaemonWriteAccess`マネージドポリシー（以下を含む）：
  - xray:PutTraceSegments
  - xray:PutTelemetryRecords
  - xray:GetSamplingRules
  - xray:GetSamplingTargets
  - xray:GetSamplingStatisticSummaries
- 追加権限：
  - cloudwatch:PutMetricData（Application Signalsのメトリクス送信用）

### CI/CDパイプライン

**注意: GitHub Actionsは使用されておらず、AWS CodePipelineがCDを担当しています。**

#### パイプラインの流れ

1. **Source Stage**: 
   - GitHubの`main`ブランチを監視（CodeStar Connection経由）
   - リポジトリ: `lemo-nade-room/cqrs-es-example-swift`
   - pushされると自動的にパイプラインが起動

2. **Build Stage** (並列実行):
   - **CommandBuild**: 
     - Dockerfile: `Server/Sources/Command/Dockerfile`
     - DockerイメージをビルドしてECRにプッシュ
   - **QueryBuild**: 
     - Dockerfile: `Server/Sources/Query/Dockerfile`
     - DockerイメージをビルドしてECRにプッシュ
   - **SAMPackage**: 
     - `sam package`を実行して`packaged.yaml`を生成

3. **Deploy Stage**:
   - CloudFormationを使用して`Stage`スタックをデプロイ
   - Lambda関数のDockerイメージを更新
   - API GatewayやIAMロールなども同時に更新

#### インフラ構成 (`Server/AWS/`)

- **ECRリポジトリ**:
  - `command-server-function`: コマンドサーバー用
  - `query-server-function`: クエリサーバー用
  - タグなしイメージは1日後に自動削除

- **CodeBuildプロジェクト**:
  - `docker_build_and_push`: DockerイメージのビルドとECRへのプッシュ
  - `sam_package`: SAMテンプレートのパッケージング
  - ARM64アーキテクチャを使用

- **IAMロール**:
  - `super_role`: PowerUserAccess + IAMFullAccess権限
  - CodeBuild, CodePipeline, CloudFormation, Lambdaが使用

#### デプロイフロー

```mermaid
graph LR
    A[GitHub main push] --> B[CodePipeline Source]
    B --> C1[CommandBuild]
    B --> C2[QueryBuild]
    B --> C3[SAMPackage]
    C1 --> D[ECR Push]
    C2 --> E[ECR Push]
    C3 --> F[packaged.yaml]
    D --> G[CloudFormation Deploy]
    E --> G
    F --> G
    G --> H[Lambda Functions Updated]
```

#### mainブランチへのpush時の動作

**✅ 現在の実装はmainブランチにpushすると自動デプロイされます。**

ただし、以下の点に注意：

1. **ビルド時間**: Dockerイメージのビルドに約15分程度かかります
2. **ビルド失敗の可能性**: 
   - Swiftパッケージの依存関係解決エラー
   - Dockerイメージサイズの問題
3. **ロールバック**: CloudFormationの`REPLACE_ON_FAILURE`設定により、失敗時は自動ロールバック

#### デプロイ前の確認事項

- [ ] GitHubとのCodeStar Connection作成（接続名: `github`）
- [ ] Terraform適用（CloudWatch Logsポリシー含む）
- [ ] X-Ray UpdateTraceSegmentDestination実行
- [ ] `swift build`が成功するか
- [ ] `swift test`が成功するか
- [ ] Dockerfileが正しくビルドできるか
- [ ] SAMテンプレートが正しいか（`sam validate --lint`）

#### 現在のステータス（2025年1月時点）

- **ビルド状態**: ✅ 正常
- **テスト**: ✅ パス
- **SAM検証**: ✅ 有効
- **X-Rayトレース**: ✅ 実装完了（OTLP/HTTP + SigV4認証）
- **mainブランチpush**: ✅ 安全（自動デプロイされます）

#### パイプライン状態の確認

```bash
# パイプライン全体の状態
aws codepipeline get-pipeline-state \
  --name stage-deploy-pipeline \
  --region ap-northeast-1

# 各ステージの状態を簡潔に表示
aws codepipeline get-pipeline-state \
  --name stage-deploy-pipeline \
  --region ap-northeast-1 \
  --output json | jq -r '.stageStates[] | "\(.stageName): \(.latestExecution.status // "N/A")"'
```


### Docker

- Docker Compose v2が利用可能です（`docker compose`コマンド）
- `docker-compose-v2`パッケージはaptでインストール可能です
- Docker in Docker環境のため、ホストのlocalhostにアクセスできない場合があります
  - Dockerコンテナ間の通信にはDockerネットワークのIPアドレスを使用する必要があります
  - 例：Jaegerコンテナへの接続時は`localhost:4318`ではなく、コンテナのIPアドレスを使用

### OpenTelemetry

- CommandServerにOpenTelemetry Swift（1.0.0以降）が統合されています
- VaporのAsyncMiddlewareとしてOpenTelemetryTracingMiddlewareが実装されています
- トレーシングデータはOTLP/HTTP経由でJaegerまたはAWS X-Rayに送信されます
- ローカル開発環境では、Jaeger All-in-Oneをdocker composeで起動できます：
  - Jaeger UI: http://localhost:16686
  - OTLP HTTP Receiver: port 4318
- 環境変数`OTEL_EXPORTER_OTLP_ENDPOINT`でエクスポート先を設定可能です
- X-Rayトレースコンテキストの伝播をサポート（`x-amzn-trace-id`ヘッダー）
- Lambda環境での動作：
  - `AWS_LAMBDA_FUNCTION_NAME`環境変数で自動検出
  - AWS Lambda Container Imagesの制約：
    - Lambda LayersはContainer Imageタイプでは使用不可
    - ADOT Lambda Layerが使えないため、アプリケーション内でOTLP送信を実装
  - CloudWatch Application SignalsのOTLPエンドポイント（`https://xray.{region}.amazonaws.com/v1/traces`）を使用
  - SigV4認証を実装済み：
    - `AWSSigV4.swift`: 最小限のSigV4署名実装（swift-cryptoを使用）
    - `AWSXRayOTLPExporter.swift`: X-Ray用のOTLPエクスポーター（SigV4認証付き、AsyncHTTPClient使用）
    - Lambda環境でのみトレースデータを送信（ローカルではスキップ）
    - Fire-and-forget方式の非同期送信で、レスポンスを待たずに即座に成功を返す
    - Sendable制約に対応するため、早期にProtobufシリアライズを実行

### 依存関係の注意点

- OpenTelemetry Swiftパッケージの構造：
  - `OpenTelemetryProtocolExporterHTTP`プロダクトは実験的で、HTTPエクスポーターの実装が不完全
  - `StdoutExporter`プロダクトを使用してローカルデバッグが可能
  - `OpenTelemetryProtocolExporterCommon`にProtobuf定義があり、独自のHTTPエクスポーター実装に使用
  - swift-otel（別プロジェクト）も検討したが、HTTPエクスポーターがないため現時点では採用せず
- AWS SDK for Swift（`aws-sdk-swift`）：
  - smithy-swiftとの依存関係競合のため使用を断念
  - SigV4認証は独自実装（`AWSSigV4.swift`）
- HTTPクライアント：
  - Lambda環境ではURLSessionが使用できないため、AsyncHTTPClientを使用
  - VaporのApplication.eventLoopGroupを共有することで、リソースを効率的に使用
  - eventLoopGroupProviderは`.shared(eventLoopGroup)`を使用
- swift-crypto：
  - SigV4署名のためのSHA256およびHMAC実装に使用
  - Appleの公式パッケージで安定している
- Swift 6の並行性：
  - `SpanData`などがSendableでないため、Task.detachedでの送信時は早期にシリアライズ
  - `@unchecked Sendable`と`@preconcurrency`を使用して移行対応

### Lambda関数の設定

- **タイムアウト**: 10秒（デフォルト3秒ではコールドスタート時にタイムアウトする）
- **メモリ**: 128MB（デフォルト）
- **アーキテクチャ**: ARM64
- **ログレベル**: DEBUG（LOG_LEVEL環境変数で制御）

## OpenTelemetry実装の注意点

### Application Signalsの有効化
- CloudWatch Application Signalsの有効化にはAWS CC (Cloud Control) プロバイダーを使用
- `awscc_applicationsignals_discovery`リソースで自動的にサービスリンクロールが作成される
- CloudFormationの混在を避けるため、Terraformのみで実装可能

### リソース属性の設定
- Application Signalsでトレースを表示するには、`service.name`などのリソース属性が必須
- AWSXRayOTLPExporterで`ResourceSpans`にリソース情報を含める必要がある
- 環境変数`OTEL_RESOURCE_ATTRIBUTES`から属性を読み込む実装が重要

### AttributeValueのProtobuf変換
- OpenTelemetryのAttributeValue型をProtobufに変換する際の注意点：
  - `.array(AttributeArray)`の場合は`.values`プロパティにアクセス
  - `.set(AttributeSet)`の場合は`.labels.values`で値の配列を取得
  - deprecated caseも含めてすべてのケースを処理する必要がある

### HTTPClientResponseのボディ読み取り
- AsyncHTTPClientのレスポンスボディは非同期で読み取る必要がある：
  ```swift
  let bodyData = try await response.body.collect(upTo: 1024 * 1024)
  let responseString = bodyData.getString(at: 0, length: bodyData.readableBytes)
  ```
- `response.body`は`HTTPClientResponse.Body`型で、直接`readData`メソッドは存在しない
- `collect(upTo:)`メソッドでバイト制限を設定して読み取る

### AWS SigV4署名でのHostヘッダー
- AWS SigV4署名では、`Host`ヘッダーは必須の署名対象ヘッダー
- AsyncHTTPClientを使用する場合、明示的にHostヘッダーを追加する必要がある：
  ```swift
  if let host = URL(string: request.url)?.host {
      request.headers.add(name: "Host", value: host)
  }
  ```
- エラー例: `'Host' or ':authority' must be a 'SignedHeader' in the AWS Authorization.` (403 InvalidSignatureException)

### デバッグログのベストプラクティス

#### 絵文字の使い方
効果的に絵文字を使って視覚的に分かりやすくする：
- 🚀 起動・開始
- ✅ 成功
- ❌ エラー・失敗
- ⚠️ 警告
- 🔧 設定・構成
- 📦 パッケージ・バッチ処理
- 📡 ネットワーク通信・エンドポイント
- 🔗 接続・リンク
- 📍 場所・ロケーション
- 🏷️ ラベル・タグ
- 🌐 環境・グローバル
- 🏥 ヘルスチェック
- 🎉 完了・成功
- 🧩 コンポーネント・モジュール
- 🏗️ ビルド・初期化
- 🔐 認証・セキュリティ

#### ログレベルとプレフィックス
- `logger.debug()`使用時は`[DEBUG]`プレフィックス不要（冗長になる）
- `print()`使用時のみ必要に応じてプレフィックスを使用

#### ログの簡潔性
- 初期化時：1行で要約（例：`🏗️ Initializing AWSXRayOTLPExporter | Region: ap-northeast-1`）
- 設定完了時：1行で要約（例：`✅ OpenTelemetry ready with service: Stage-CommandServerFunction`）
- エラー時のみ詳細を出力

#### 情報の集約
- 複数の関連情報は1行にまとめる
  ```swift
  app.logger.debug("🌐 Environment: \(app.environment) | Lambda: ✅ | Function: \(functionName)")
  app.logger.debug("📍 Region: \(region) | Memory: \(memorySize)MB")
  ```

#### セクション区切りの最小化
- 重要なセクションのみ区切りを使用
- 通常の処理フローでは区切り不要
- エラー解析が必要な部分でのみ詳細ログ

#### Fire-and-forgetパターン
- 非同期タスクの結果は簡潔に
  ```swift
  print("✅ Exported \(spanCount) spans to X-Ray")  // 成功時
  print("❌ X-Ray export failed: \(error)")          // 失敗時
  ```

### Swift Formatの注意点

- `case let`パターンは使用せず、`case .enum(let value)`の形式を使用する
  ```swift
  // ❌ Bad
  case let .string(value):
  
  // ✅ Good  
  case .string(let value):
  ```
- 長い行は適切に改行する（LineLength警告を避ける）
  ```swift
  // ❌ Bad - 1行が長すぎる
  print("Very long string with \(variable1) and \(variable2) and more text")
  
  // ✅ Good - 文字列連結で改行
  print(
      "Very long string with \(variable1) " +
      "and \(variable2) and more text"
  )
  ```
- 行末の空白は削除する（TrailingWhitespace警告）

### X-Rayトレースのデバッグ

- X-Rayへのトレース送信が失敗する場合、以下を確認：
  1. CloudWatch Logsリソースポリシーが正しく設定されているか
  2. UpdateTraceSegmentDestinationが実行されているか
  3. Lambda関数のIAMロールに必要な権限があるか
  4. OTLP送信のエンドポイントURL、SigV4署名が正しいか

- デバッグ時は以下の情報をログ出力すると有効：
  - トレースID、スパンID（hexString形式で出力）
  - スパン名（どのAPIエンドポイントのトレースか確認）
  - HTTPリクエストのURL、認証ヘッダーの有無
  - リクエストボディのサイズ
  - レスポンスのステータスコードとエラーメッセージ

- Fire-and-forgetパターンで非同期送信する場合のベストプラクティス：
  - エラーハンドリングは必須（catch節で詳細をログ出力）
  - ExportError型でエラーを分類（認証エラー、HTTPエラー）
  - 成功時も確認のためログを出力

- X-Rayコンソールでトレースが見えない場合の確認ポイント：
  - `/aws/spans`ロググループが作成されているか
  - Lambda関数のログで"✅ Exported"メッセージが出ているか
  - "❌ X-Ray export failed"エラーが出ていないか
  - HTTPステータスコードが2xxになっているか

### X-Rayトレース送信の既知の問題

#### 接続タイムアウト問題
- Lambda環境で`HTTPClientError.connectTimeout`が発生することがある
- 特にコールドスタート時やWarm Lambda実行時の初回接続で発生
- タイムアウト設定を短くすることで影響を軽減（connect: 5秒、read: 10秒）

#### トレースが表示されない問題
- HTTP 200レスポンスが返っているにも関わらず、X-Rayコンソールにトレースが表示されないことがある
- 考えられる原因：
  - トレースIDの形式の違い（X-Ray形式 vs OpenTelemetry形式）
  - Application Signalsの設定問題
  - スパン属性の不足

#### デバッグログの活用
- 詳細なログを追加することで問題を特定しやすくなる：
  ```
  📦 Exporting 2 spans to X-Ray
  📡 First span: TraceID=..., SpanID=..., Name=GET /Stage/command/v1/healthcheck
  📡 Sending to: https://xray.ap-northeast-1.amazonaws.com/v1/traces
  🔐 Authorization header present: true
  📊 Body size: 235 bytes
  ✅ X-Ray API response: 200
  ```

#### Lambda環境での非同期処理
- Task.detachedで非同期送信を行うが、Lambda関数の実行が終了すると処理が中断される可能性がある
- Fire-and-forgetパターンのため、送信結果の確認は後続のログで行う必要がある

### X-Rayトレース問題の詳細な調査結果（2025年1月）

#### 確認できた事実
1. **X-Ray APIへの送信は成功している**
   - HTTP 200レスポンスを受信
   - 認証（SigV4）は正しく動作
   - リクエストボディは正しくシリアライズされている（837バイト等）

2. **リソース属性の設定**
   ```
   🏷️ Resource attributes:
   - service.version: 1.0.0
   - service.name: Stage-CommandServerFunction-fpqdU2iwONXY
   - deployment.environment: production
   ```

3. **スパン属性**
   - 各スパンには7つの属性が含まれている
   - HTTPメソッド、URL、ステータスコード等が記録されている

#### トレースが表示されない根本原因の仮説

1. **トレースIDフォーマットの問題**
   - X-Rayは`1-TIMESTAMP-UNIQUEID`形式を期待（例：`1-6857a7ff-512dd70e04bb82eb2d9c0e79`）
   - OpenTelemetryは16バイトのバイナリ形式を使用
   - 変換時にX-Rayのトレースヘッダーとの整合性が取れていない可能性

2. **service.nameの不一致**
   - Lambda関数名がservice.nameとして使用されていた
   - Application Signalsが期待するサービス名と異なる可能性
   - 修正：固定値"CommandServer"を使用するよう変更

3. **OTLP APIとX-Rayの統合問題**
   - X-Ray OTLP APIはまだ新しい機能
   - CloudWatch Logsへの書き込み権限は設定済みだが、実際の統合に問題がある可能性
   - `/aws/spans`ロググループが作成されていない

#### デバッグ時の確認ポイント

1. **詳細ログの活用**
   - リソース属性とスパン属性の完全な出力
   - X-Ray APIレスポンスボディの確認（現在は空）
   - Fire-and-forgetパターンの非同期処理の結果確認

2. **Lambda実行環境の特性**
   - コールドスタート時は接続に時間がかかる
   - Task.detachedの処理がLambda関数終了前に完了しない場合がある
   - ログストリームが複数に分かれる可能性

3. **今後の対応案**
   - X-Ray SDKの直接使用を検討
   - Application Signalsの代わりに従来のX-Ray統合を試す
   - OTEL Collectorをサイドカーとして配置する方法を検討


