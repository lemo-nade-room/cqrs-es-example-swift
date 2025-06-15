# 作業進捗とコンテキスト

## 現在の状況（2025-06-15 更新）

### 完了した作業

#### 1. X-Ray OTelエクスポート問題の調査と修正
- **問題**: Lambda環境でX-Rayへのトレースエクスポートが失敗（400エラー）
- **原因**: 
  - X-RayがOTLP形式を受け付けるが、X-Ray特有のトレースIDフォーマットを要求
  - 標準的なW3CトレースIDではなく、X-Rayフォーマット（`1-{timestamp}-{random}`）が必要

#### 2. 実装した修正

##### a) XRayIDGenerator（新規作成）
- ファイル: `Sources/Command/Server/OTel/XRayIDGenerator.swift`
- 簡易実装（TraceIDの内部構造へのアクセス制限のため）
- 将来的により正確な実装が必要

##### b) XRayOTelSpanExporter（改善）
- デバッグログの追加
  - リクエストヘッダー、パス、URL
  - エラー時のレスポンスボディ
  - リクエストペイロードの詳細（16進ダンプ）
- HTTPヘッダーの追加
  - `Accept: application/x-protobuf`
  - `User-Agent: swift-otel/1.0`
  - `X-Amzn-Xray-Format: otlp` (新規追加)

##### c) OTelFlushMiddleware（ログ追加）
- フラッシュ処理の開始/完了ログ
- Lambda環境でのスパンエクスポート完了確認用

##### d) configure.swift（修正）
- `OTelRandomIDGenerator` → `XRayIDGenerator` に変更
- デバッグ関数 `debugXRayRequest()` の呼び出しを追加

#### 3. Lambda設定の更新
- **template.yaml**:
  - X-Ray権限を明示的に追加（`AWSXRayDaemonWriteAccess`ポリシー）
  - `xray:PutTraceSegments`と`xray:PutTelemetryRecords`の権限を追加
  - 環境変数`AWS_XRAY_CONTEXT_MISSING: LOG_ERROR`を追加
  - ※ `_X_AMZN_TRACE_ID`は予約された環境変数のため削除

#### 4. Swiftビルドエラーの修正
- **testXRayEndpoint.swift**: トップレベル実行コードのため削除
- **debugXRayRequest.swift**: String初期化とLogger型の修正
- **XRayOTelSpanExporter.swift**: ByteStreamの型に合わせたswitch文の修正
- **validateXRayEndpoint.sh**: Swiftソースディレクトリから削除
- **XRayIDGenerator.swift**: 未使用変数の警告を修正

### 判明した問題

#### 1. Lambda環境
- **症状**: X-Ray OTLPエンドポイントから400エラー
- **ログ分析結果**:
  - リクエストは送信されている
  - AWS SigV4署名は成功
  - レスポンスがHTML（エラーページ）で返ってくる
  - `awselb/2.0`からのレスポンス（ロードバランサー経由？）

#### 2. ローカル環境
- **症状**: AWS CRTライブラリでクラッシュ
- **エラー**: `aws_hash_table_is_valid(map)` でアサーション失敗
- **原因**: AWS SDK/CRTライブラリの互換性問題の可能性

### 作成したドキュメント
1. `xray-otel-investigation-report.md` - 初期調査レポート
2. `xray-otel-investigation-report-solution.md` - 解決策の提案
3. `xray-otel-final-solution.md` - 最終的な実装内容
4. `log-events-viewer-result.csv` - Lambda実行ログ（1回目）
5. `log-events-viewer-result2.csv` - Lambda実行ログ（2回目）

## 次のステップ

### 1. Lambda環境での再テスト（優先度：高）
```bash
# デプロイ
cd Server
sam build
sam deploy

# CloudWatchログを確認
# 特に以下の新しいデバッグログに注目：
# - [X-Ray Debug] 環境変数の詳細
# - [X-Ray] Request body (first 200 bytes in hex): リクエストペイロードの内容
# - [X-Ray] Error response headers: エラー時のレスポンスヘッダー
```

### 2. 400エラーの根本原因特定
今回追加したデバッグ情報から以下を確認：
- Lambda実行環境の詳細（環境変数、トレースID形式）
- リクエストペイロードの実際の内容
- エラーレスポンスの詳細ヘッダー

### 3. 考えられる解決策

#### a) X-Ray OTLPエンドポイントの正確な仕様確認
- AWS Supportへの問い合わせ
- X-Ray OTLP仕様ドキュメントの詳細確認
- 必要に応じて別のエンドポイントパスを試す

#### b) リクエストフォーマットの調整
- Content-Typeの変更（`application/octet-stream`など）
- 追加のX-Ray固有ヘッダーの確認

#### c) ネットワーク設定の確認
- Lambda VPC設定の確認
- X-Ray VPCエンドポイントの必要性
- セキュリティグループ/NACLの設定

### 4. 代替実装の検討（必要に応じて）
- AWS Distro for OpenTelemetry (ADOT) Lambdaレイヤーの使用
- X-Ray Daemonを介したトレース送信
- カスタムX-Rayセグメント実装

## 技術的な課題

### 1. TraceID構造の制限
- W3CTraceContextライブラリのTraceIDは内部構造へのアクセスが制限
- `bytes`プロパティの型が不明確
- X-Rayフォーマットへの正確な変換が困難

### 2. X-Ray OTLP エンドポイントの仕様
- 2024年11月にリリースされた新機能
- ドキュメントが少ない
- 正確な要件が不明確

### 3. Swift エコシステムの課題
- OpenTelemetry Swiftの成熟度
- AWS SDK for Swiftとの統合
- サンプルコードの不足

## 推奨アクション

1. **短期的**: 現在の実装でLambdaにデプロイし、詳細なエラーメッセージを取得
2. **中期的**: エラーメッセージに基づいて修正を実施
3. **長期的**: より堅牢な実装（ADOT使用など）を検討

## 参考情報

- X-Ray OTLP エンドポイント: `https://xray.{region}.amazonaws.com/v1/traces`
- X-Ray トレースIDフォーマット: `1-{8桁16進数タイムスタンプ}-{24桁16進数ランダム}`
- 必要な権限: `xray:PutTraceSegments`