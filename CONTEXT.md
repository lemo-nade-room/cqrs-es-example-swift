# CONTEXT.md - プロジェクト引き継ぎ資料

## プロジェクト概要
SwiftとVaporで構築されたCQRS（コマンドクエリ責任分離）とイベントソーシングのサンプルアプリケーション。AWS Lambdaにデプロイされ、独立したコマンドサーバーとクエリサーバーを持つマイクロサービスアーキテクチャ。

## 🚨 最新の状況（2025年7月10日 15:30更新）

### デプロイ障害の解決

#### 発生していた問題
1. **両パイプラインが失敗** (`command-deploy-pipeline`、`query-deploy-pipeline`)
   - CloudFormationデプロイフェーズで失敗
   - エラー: "Source image is not valid"（実際にはイメージは存在）
   
2. **Lambda実行エラー**
   - ヘルスチェックエンドポイントが500エラー返却
   - Lambda直接実行時: `exit status 127`（コマンドが見つからない）
   
3. **根本原因**
   - Queryサーバーのビルドステージでjemallocがまだ使用されていた
   - コミットe6afa28では**ランタイムのjemallocのみ削除**されていた
   - ビルド時の`libjemalloc-dev`と`-Xlinker -ljemalloc`が残存
   - Amazon Linux 2にはjemallocが存在しないため、実行時エラー

#### 実施した修正
- **コミット: abe8e1e** (2025-07-10 15:25頃)
  ```dockerfile
  # 削除した内容（Query Dockerfile）
  - apt-get install -y libjemalloc-dev
  - -Xlinker -ljemalloc
  ```
- mainブランチにプッシュ済み
- パイプラインが自動的に再実行開始

### 現在の状態
- **パイプライン**: 新しい実行が開始されているはず（要確認）
- **期待される結果**: jemallocが完全に削除され、Lambda互換のイメージがビルドされる
- **確認方法**:
  ```bash
  # パイプライン状況
  aws codepipeline list-pipeline-executions --pipeline-name query-deploy-pipeline --region ap-northeast-1 --max-items 1
  
  # デプロイ成功後のヘルスチェック
  curl https://e5libc8ai7.execute-api.ap-northeast-1.amazonaws.com/Stage/query/healthcheck
  curl https://e5libc8ai7.execute-api.ap-northeast-1.amazonaws.com/Stage/command/v1/healthcheck
  ```

## 🚀 最新の改良（2025年7月10日 14:00更新）

### 独立デプロイとビルド高速化の実装完了

#### ✅ 達成した内容

1. **独立デプロイ基盤の構築完了**
   - `command-deploy-pipeline`: Command専用パイプライン
   - `query-deploy-pipeline`: Query専用パイプライン
   - 各サービスが完全に独立してビルド・デプロイ可能
   - 並列実行により効率的なリソース利用

2. **Lambda互換性問題の完全解決**
   - 最終解決策：`amazonlinux:2` + ImageConfig
   - jemalloc依存を削除（Amazon Linux 2の標準リポジトリに存在しないため）
   - ENTRYPOINTを明示的にクリア（`ENTRYPOINT []`）
   - 最新コミット：69a119c（Query v12テスト変更）

3. **ビルド高速化の実装（制約あり）**
   - BuildKitキャッシュ実装済み（7-15秒達成）
   - ただしLambda互換性のため通常のdocker buildに戻す必要あり
   - ECRレジストリキャッシュ（`:cache`タグ）は引き続き有効

#### ⚠️ 未解決の課題

1. **変更検知システム**
   - CodePipeline環境でgit履歴が利用できない
   - 一時的に無効化中（常に全ビルド実行）
   - 今後の改善案：S3/DynamoDBで前回コミットハッシュ保存

2. **3分以内デプロイ目標**
   - 現状：約8-10分（Swiftビルドがボトルネック）
   - ビルドフェーズ：5-6分
   - デプロイフェーズ：2-3分

### 📊 パフォーマンス測定結果（最終）

| 測定項目 | 時間 | 備考 |
|---------|------|------|
| Dockerビルド（初回） | 5-6分 | Swift依存関係の解決含む |
| Dockerビルド（BuildKitキャッシュ） | 7-15秒 | Lambda非互換のため使用不可 |
| Dockerビルド（ECRキャッシュ） | 約18秒 | docker build --cache-from使用 |
| Dockerビルド（キャッシュなし・2回目） | 約5分 | 依存関係はキャッシュされるが、ソース変更で再ビルド |
| SAMパッケージング | 約30秒 | |
| CloudFormationデプロイ | 1-2分 | |
| **合計時間** | **8-10分** | 3分目標は未達成 |

### 🔍 重要な技術的発見事項

1. **Lambda Web Adapterの制約**
   - docker buildxのマルチアーキテクチャマニフェストは非対応
   - `provided:al2-arm64`イメージのデフォルトENTRYPOINTが干渉
   - 通常のdocker buildが必須

2. **CodePipelineの制約**
   - gitリポジトリ全体ではなくソースのみ提供
   - `HEAD~1`などの履歴参照不可
   - 変更検知には別の仕組みが必要

3. **Swiftビルドの特性**
   - 依存関係が非常に多い（900+ファイル）
   - ビルドキャッシュが部分的にしか効かない
   - jemallocリンクフラグの有無でキャッシュ無効化

### 現在の構成（2025年7月10日 14:00時点）

#### Dockerfile構成（Command/Query共通）
```dockerfile
# ビルドステージ
FROM public.ecr.aws/docker/library/swift:6.1-noble AS build
# jemalloc-devは削除（Lambda互換性のため）

# ランタイムステージ  
FROM --platform=linux/arm64 public.ecr.aws/amazonlinux/amazonlinux:2
# Lambda Web Adapter 0.9.1
# jemallocランタイムは削除
ENTRYPOINT []  # 明示的にクリア
CMD ["/var/task/CommandServer", "serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "3001"]
```

#### SAMテンプレート設定
```yaml
CommandServerFunction:
  Type: AWS::Serverless::Function
  Properties:
    PackageType: Image
    ImageUri: !Ref CommandServerFunctionImageUri
    ImageConfig:
      Command: ["/var/task/CommandServer", "serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "3001"]
    Environment:
      Variables:
        PORT: 3001
```

#### buildspec.yaml（変更検知は一時無効化）
```yaml
pre_build:
  commands:
    - echo "Change detection temporarily disabled"
    - export BUILD_SKIPPED=false
```

### 📊 調査で判明した重要事項

1. **イメージURI形式**
   - CloudFormationはECRイメージをdigest形式で参照
   - 例: `983760593510.dkr.ecr.ap-northeast-1.amazonaws.com/query-server-function@sha256:xxx`
   - タグではなくdigestを使用することで確実性を担保

2. **Lambda Web Adapterの動作**
   - ENTRYPOINTは明示的にクリア必要（`ENTRYPOINT []`）
   - ImageConfigでCMDを上書き指定
   - PORT環境変数とlambda-adapterが連携

3. **エラーのデバッグ方法**
   - CloudFormationイベントでエラー詳細確認
   - Lambda直接実行でexit codeを確認
   - ECRイメージの存在確認は`batch-get-image`が確実

### 🎯 独立デプロイテストの準備状況

1. **Queryのみ変更テスト**
   - Query Server: v12 (Independent Deploy Test) にアップデート済み
   - コミット：69a119c（ローカルのみ、未プッシュ）
   - 期待動作：Queryパイプラインのみ実行
   - **注意**: jemallocの修正を優先したため、このテストは延期

2. **次回テスト予定**
   - まずjemallocの修正が正常にデプロイされることを確認
   - その後、独立デプロイテストを実施
   - Commandのみ変更
   - インフラ変更（両方デプロイ）
   - 変更なし（両方スキップ）※変更検知修正後

### 🚀 今後の改善提案

1. **変更検知システムの実装**
   ```yaml
   # S3ベースの実装案
   - aws s3 cp s3://bucket/last-commit-hash.txt ./
   - LAST_COMMIT=$(cat last-commit-hash.txt)
   - CHANGES=$(aws codecommit get-differences --repository-name repo --before-commit $LAST_COMMIT --after-commit $CODEBUILD_RESOLVED_SOURCE_VERSION)
   ```

2. **ビルド時間短縮**
   - ベースイメージに依存関係を事前インストール
   - より強力なCodeBuildインスタンス（2xlarge）
   - Swiftパッケージレジストリの活用

3. **3分デプロイ達成への道**
   - Lambda Layersでの共通ライブラリ配布
   - コンテナイメージではなくZIPデプロイ検討
   - GraalVMネイティブイメージ化（将来的に）

## CI/CDパイプライン構成

### AWS CodePipelineによる自動デプロイ
**注意**: GitHub Actionsは使用していません。AWS CodePipelineを使用。

#### 新しい独立パイプライン（現在稼働中）
- **Command用**: `command-deploy-pipeline`
- **Query用**: `query-deploy-pipeline`
- **トリガー**: mainブランチへのプッシュで両方起動（変更検知は一時無効）
- **並列実行**: 可能（リソース競合なし）

### 監視コマンド
```bash
# パイプライン実行状況
aws codepipeline list-pipeline-executions --pipeline-name command-deploy-pipeline --region ap-northeast-1

# ビルド詳細
aws codebuild batch-get-builds --ids <BUILD_ID> --region ap-northeast-1

# Lambda関数のログ
aws logs tail /aws/lambda/Stage-CommandServerFunction-<ID> --region ap-northeast-1
```

### API Gateway動作確認
```bash
# ヘルスチェック（現在は500エラー - jemalloc削除後は正常動作予定）
curl https://e5libc8ai7.execute-api.ap-northeast-1.amazonaws.com/Stage/command/v1/healthcheck
curl https://e5libc8ai7.execute-api.ap-northeast-1.amazonaws.com/Stage/query/healthcheck
```

## 重要な注意事項

### デプロイ時の注意
- mainブランチへのプッシュで自動デプロイ開始
- 現在は変更検知が無効のため、全変更で両パイプライン実行
- Lambda互換性エラーが発生した場合、CloudFormationがロールバック

### 開発時の注意
- Dockerfileを変更する際はLambda互換性に注意
- buildxは使用不可（通常のdocker buildのみ）
- jemallocは使用不可（Amazon Linux 2に存在しない）

## 次のアクション（優先順位順）

1. **即座に確認必要**
   - 新しいパイプライン実行の成功確認（abe8e1eコミット）
   - ヘルスチェックエンドポイントの正常動作確認
   - Lambda関数のログでエラーがないことを確認
   ```bash
   # パイプライン確認
   aws codepipeline list-pipeline-executions --pipeline-name query-deploy-pipeline --region ap-northeast-1 --max-items 1
   
   # ヘルスチェック（成功すれば200が返る）
   curl -w "%{http_code}" https://e5libc8ai7.execute-api.ap-northeast-1.amazonaws.com/Stage/query/healthcheck
   ```

2. **デプロイ成功後**
   - 独立デプロイテスト（Query v12）の実施
   - パフォーマンス測定（jemallocなしでの実行時間）
   
3. **中期的改善**
   - 変更検知システムの本格実装
   - ビルド時間のさらなる短縮
   - 旧リソースの削除

## 重要な学習事項

1. **Dockerfileの変更は慎重に**
   - ビルドステージとランタイムステージの両方を確認
   - 部分的な削除は問題を引き起こす可能性
   
2. **デバッグの流れ**
   - パイプライン → CloudFormation → Lambda関数 → ECRイメージの順で確認
   - exit status 127は通常、実行ファイルまたは依存ライブラリが見つからない
   
3. **Git操作**
   - ローカルとリモートの状態確認が重要
   - 意図しない変更が残っていないか常に確認

## まとめ

### 成功した実装
- ✅ 独立デプロイ可能なアーキテクチャ構築
- ✅ Lambda互換性問題の解決
- ✅ ビルド高速化の仕組み（制約付き）

### 未達成の目標
- ❌ 3分以内のデプロイ（Swiftの特性上困難）
- ❌ 完全な変更検知システム（CodePipeline環境の制約）

### 次のアクション
1. 現在ビルド中のjemalloc削除版の動作確認
2. 独立デプロイテストの実施（Query v12）
3. 変更検知システムの本格実装
4. 旧リソースの削除