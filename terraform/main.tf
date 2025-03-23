###############################################################################
# Provider の設定（AWSの認証情報やRegion設定など。既に記載済みの場合は省略可。）
###############################################################################
terraform {
  required_version = ">= 1.3.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 4.0"
    }
  }
}
data "aws_caller_identity" "current" {}

variable "aws_region" {
  default = "us-east-1"
}

provider "aws" {
  region = var.aws_region
}

###############################################################################
# ECR リポジトリ
###############################################################################
resource "aws_ecr_repository" "cqrs_swift" {
  name = "cqrs-es-example-swift"

  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

###############################################################################
# CodeBuild 用 IAM ロール
###############################################################################
data "aws_iam_policy_document" "codebuild_assume_role" {
  statement {
    effect = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codebuild_role" {
  name               = "codebuild-cqrs-swift-role"
  assume_role_policy = data.aws_iam_policy_document.codebuild_assume_role.json
}

data "aws_secretsmanager_secret" "github-repository-secret" {
  name = "lemo-nade-room-cqrs-es-example-swift"
}

# CodeBuildがECRへpushする際に必要なポリシーを付与
data "aws_iam_policy_document" "codebuild_inline" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["*"]
  }

  # ビルド時のDocker Pull/PushでECR操作
  statement {
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
    ]
    resources = ["*"]
  }

  # Secrets Managerのシークレットを取得するための権限を追加
  statement {
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue"
    ]
    resources = [
      data.aws_secretsmanager_secret.github-repository-secret.arn
    ]
  }
}

resource "aws_iam_role_policy" "codebuild_inline" {
  name   = "codebuild-cqrs-swift-policy"
  role   = aws_iam_role.codebuild_role.id
  policy = data.aws_iam_policy_document.codebuild_inline.json
}

###############################################################################
# CodeBuild プロジェクト
###############################################################################
resource "aws_codebuild_project" "cqrs_swift" {
  name         = "cqrs-es-example-swift"
  description  = "Build Docker image (ARM) and push to ECR"
  service_role = aws_iam_role.codebuild_role.arn

  # タイムアウトやキューイングの上限は環境に合わせて調整
  build_timeout  = 30
  queued_timeout = 30

  # ビルド環境設定
  environment {
    # ARMコンテナを指定
    type         = "ARM_CONTAINER"
    compute_type = "BUILD_GENERAL1_MEDIUM"
    image        = "aws/codebuild/amazonlinux2-aarch64-standard:2.0"

    # Dockerイメージをbuild/pushするのでprivileged_modeをtrueにすることが多いです
    privileged_mode = true

    # 環境変数（AWS_ACCOUNT_IDなどを注入しておくと便利）
    environment_variable {
      name  = "IMAGE_REPO_NAME"
      value = aws_ecr_repository.cqrs_swift.name
    }

    # AWS_DEFAULT_REGION を環境変数として注入
    environment_variable {
      name  = "AWS_DEFAULT_REGION"
      value = var.aws_region
    }

    # AWS_ACCOUNT_ID を注入する例
    # 自アカウントIDを自動取得したい場合
    environment_variable {
      name  = "AWS_ACCOUNT_ID"
      value = data.aws_caller_identity.current.account_id
    }
  }

  # GitHubソース（CodeStar Connections）
  source {
    type      = "GITHUB"
    location  = "https://github.com/lemo-nade-room/cqrs-es-example-swift.git"

    # buildspec を inline ではなく CodeBuildプロジェクトで定義
    buildspec = file("${path.module}/buildspec.yml")
  }

  # アーティファクトはS3アップロード不要であれば NO_ARTIFACTS
  artifacts {
    type = "NO_ARTIFACTS"
  }

  # お好みでログ設定
  logs_config {
    cloudwatch_logs {
      status     = "ENABLED"
      group_name = "/aws/codebuild/cqrs-swift"
    }
  }
}

###############################################################################
# GitHub OIDC 用のリソース
###############################################################################
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  # GitHub公式ドキュメントで示されているThumbprint
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  # GitHub ActionsからのAssumeRoleではクレーム内 "aud" = sts.amazonaws.com となる
  client_id_list = ["sts.amazonaws.com"]
}
data "aws_iam_policy_document" "github_actions_assume_role" {
  statement {
    effect = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    # OpenID Connect Provider (Federated) からのAssumeを許可
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    # GitHubリポジトリ・ブランチなどを制限 (condition) で指定
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [
        "repo:lemo-nade-room/cqrs-es-example-swift:ref:refs/heads/main"
      ]
    }
  }
}
resource "aws_iam_role" "github_actions_role" {
  name               = "github-actions-oidc-role"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume_role.json
}
data "aws_iam_policy_document" "github_actions_codebuild" {
  statement {
    effect    = "Allow"
    actions   = [
      "codebuild:StartBuild",
      "codebuild:BatchGetBuilds",
      # 他にも必要に応じて追加
    ]
    resources = ["*"]  # 必要に応じて特定の CodeBuild プロジェクトARNに絞ることを推奨
  }
}

resource "aws_iam_role_policy" "github_actions_codebuild" {
  name   = "github-actions-codebuild"
  role   = aws_iam_role.github_actions_role.id
  policy = data.aws_iam_policy_document.github_actions_codebuild.json
}

###############################################################################
# Lambda実行用のIAMロール
###############################################################################
data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_execution_role" {
  name               = "lambda-cqrs-swift-arm-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

# CloudWatch Logs などへの書き込みを許可するためのポリシーをアタッチ
data "aws_iam_policy_document" "lambda_inline" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "lambda_inline" {
  name   = "lambda-cqrs-swift-arm-policy"
  role   = aws_iam_role.lambda_execution_role.id
  policy = data.aws_iam_policy_document.lambda_inline.json
}

###############################################################################
# Lambda 関数 (ECR イメージを使用し、ARM64 で実行)
###############################################################################
resource "aws_lambda_function" "swift_lambda" {
  function_name = "cqrs-es-example-swift-ARM"
  role          = aws_iam_role.lambda_execution_role.arn

  # コンテナイメージデプロイ
  package_type = "Image"

  # ECRリポジトリ「cqrs-es-example-swift」の :latest を参照
  image_uri = "${aws_ecr_repository.cqrs_swift.repository_url}:latest"

  # ARM64 で実行 (x86_64 の場合は省略可)
  architectures = ["arm64"]

  # タイムアウト、メモリなど必要に応じて
  timeout     = 15
  memory_size = 512

  # Lambda Web Adapter でHTTPを扱う場合、handlerやruntimeの設定は不要ですが、
  # Image内でポートをLISTENしておく必要があります。(Dockerfile や Lambda Web Adapterの設定次第)
}

###############################################################################
# API Gateway (HTTP API)
###############################################################################
resource "aws_apigatewayv2_api" "swift_api" {
  name          = "swift-api"
  protocol_type = "HTTP"
}

# Lambda 連携 (AWS_PROXY)
resource "aws_apigatewayv2_integration" "swift_integration" {
  api_id                 = aws_apigatewayv2_api.swift_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.swift_lambda.arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

# デフォルトルート (全てのリクエストを Lambda にルーティング)
resource "aws_apigatewayv2_route" "swift_route" {
  api_id    = aws_apigatewayv2_api.swift_api.id
  route_key = "$default"  # どんなパス/メソッドでも受け取る
  target    = "integrations/${aws_apigatewayv2_integration.swift_integration.id}"
}

# デフォルトステージ (自動デプロイ)
resource "aws_apigatewayv2_stage" "swift_stage" {
  api_id      = aws_apigatewayv2_api.swift_api.id
  name        = "$default"
  auto_deploy = true
}

# API Gateway から Lambda を呼び出す権限
resource "aws_lambda_permission" "apigw_permission" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.swift_lambda.arn
  principal     = "apigateway.amazonaws.com"

  # このAPIの全ステージからの呼び出しを許可
  source_arn = "${aws_apigatewayv2_api.swift_api.execution_arn}/*"
}
