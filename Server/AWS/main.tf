provider "aws" {
  region = var.region
}

# ================================
# Elastic Container Registry
# ================================
resource "aws_ecr_repository" "command_server_function_repository" {
  name                 = "command-server-function"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}
resource "aws_ecr_repository" "query_server_function_repository" {
  name                 = "query-server-function"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

# ================================
# Deploy Pipeline
# ================================
resource "aws_codebuild_project" "docker_build_and_push" {
  name          = "docker_build_and_push"
  description   = "Docker ImageをBuildし、ECRへプッシュするCodeBuildプロジェクトです。使用時にはREPOSITORY_URL, DOCKER_FILE_PATH, TAGの環境変数のOverrideが必要です"
  build_timeout = 15
  service_role  = aws_iam_role.docker_build_role.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_LARGE"
    image                       = "aws/codebuild/amazonlinux-aarch64-standard:3.0-25.03.03"
    type                        = "ARM_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = true

    environment_variable {
      name  = "AWS_REGION"
      value = var.region
    }
  }

  logs_config {
    cloudwatch_logs {
      status = "ENABLED"
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "Server/AWS/docker_build_and_push_buildspec.yaml"
  }
}

resource "aws_iam_role" "docker_build_role" {
  name = "docker_build_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "sts:AssumeRole"
        Principal = {
          Service = "codebuild.amazonaws.com"
        }
      }
    ]
  })
}
resource "aws_iam_role_policy" "docker_build_role_policy" {
  name = "docker_build_ecr"
  role = aws_iam_role.docker_build_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
        ]
        Resource = [
          aws_ecr_repository.command_server_function_repository.arn,
          aws_ecr_repository.query_server_function_repository.arn,
        ]
      }
    ]
  })
}
