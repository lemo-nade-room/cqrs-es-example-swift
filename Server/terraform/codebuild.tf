# Swift Build Project
resource "aws_codebuild_project" "swift_build" {
  name         = "${var.project_name}-${var.environment}-swift-build"
  description  = "Swift build project for ${var.project_name}"
  service_role = aws_iam_role.super_role.arn # 一時的にsuper_roleを使用

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_LARGE"
    image                       = "public.ecr.aws/docker/library/swift:6.1-noble"
    type                        = "ARM_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = false # Swiftビルドには不要

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
    type      = "CODEPIPELINE"
    buildspec = "Server/terraform/buildspec-swift.yml"
  }

  cache {
    type     = "S3"
    location = "${aws_s3_bucket.codepipeline_artifacts.id}/codebuild-cache-swift"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/${var.project_name}-${var.environment}"
      stream_name = "swift-build-log"
    }
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-swift-build"
    Environment = var.environment
    Purpose     = "Swift build project"
  }
}

# Docker Build Project
resource "aws_codebuild_project" "docker_build" {
  name         = "${var.project_name}-${var.environment}-docker-build"
  description  = "Docker build project for ${var.project_name}"
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

    environment_variable {
      name  = "ECR_REPOSITORY_NAME"
      value = aws_ecr_repository.lambda_command.name
    }

    environment_variable {
      name  = "AWS_ACCOUNT_ID"
      value = data.aws_caller_identity.current.account_id
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "Server/terraform/buildspec-docker.yml"
  }

  cache {
    type     = "S3"
    location = "${aws_s3_bucket.codepipeline_artifacts.id}/codebuild-cache-docker"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/${var.project_name}-${var.environment}"
      stream_name = "docker-build-log"
    }
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-docker-build"
    Environment = var.environment
    Purpose     = "Docker build project"
  }
}
