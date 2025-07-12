resource "aws_codebuild_project" "main" {
  name         = "${var.project_name}-${var.environment}-build"
  description  = "Build project for ${var.project_name}"
  service_role = aws_iam_role.super_role.arn # 一時的にsuper_roleを使用

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_LARGE"
    image                       = "aws/codebuild/amazonlinux-aarch64-standard:3.0"
    type                        = "ARM_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = true # Dockerビルドのために必要

    environment_variable {
      name  = "PROJECT_NAME"
      value = var.project_name
    }

    environment_variable {
      name  = "ENVIRONMENT"
      value = var.environment
    }
  }

  source {
    type = "CODEPIPELINE"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/${var.project_name}-${var.environment}"
      stream_name = "build-log"
    }
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-build"
    Environment = var.environment
    Purpose     = "Build project"
  }
}