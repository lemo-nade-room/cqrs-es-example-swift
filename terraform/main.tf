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
    #
    # 例: "repo:YOUR_ORG/YOUR_REPO:ref:refs/heads/main" のみ許可
    #     YOUR_ORG, YOUR_REPO を置き換えてください。
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
