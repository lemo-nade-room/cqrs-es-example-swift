# CQRS ES Example Swift

event-store-adapter-swiftを使用した、SwiftによるCQRS・ESのサンプルサーバー

## はじめ方

### 事前準備

以下の環境を事前に整えてください。

- Dockerインストール済み
- AWS SAM CLIのインストール済み
- AWSアカウントの認証情報を環境変数に登録済み

### ビルド

DockerでLambda関数用のDocker Imageをbuildします。

```shell
sam build
```

# デプロイ

アプリケーションをAWS上にデプロイします。

`sam build`が完了していることが前提です。

```shell
sam deploy
```

# 削除

デプロイしたアプリケーションを削除します。

`sam deploy`が完了していることが前提です。

```shell
sam delete --stack-name cqrs-es-example-swift-dev
```