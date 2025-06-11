# AGENTS

このドキュメントはコード生成エージェント向けの操作手順をまとめたものです。

## ビルド

```bash
cd Server
swift build
```

## テスト

```bash
cd Server
swift test
```

## フォーマット・Lint

### swift-format (外部ツール)

```bash
swift-format lint -r .
swift-format format -i -r .
```

### swift format (Swift 組み込み)

```bash
swift format -i -r .
```