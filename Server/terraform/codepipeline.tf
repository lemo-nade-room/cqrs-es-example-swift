# GitHub App接続用のCodeStar Connection
# 既に手動で作成済みの接続を参照
data "aws_codestarconnections_connection" "github" {
  name = var.github_connection_name
}

resource "aws_codepipeline" "main" {
  name     = "${var.project_name}-${var.environment}-pipeline"
  role_arn = aws_iam_role.super_role.arn # 一時的にsuper_roleを使用

  artifact_store {
    location = aws_s3_bucket.codepipeline_artifacts.bucket
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        ConnectionArn    = data.aws_codestarconnections_connection.github.arn
        FullRepositoryId = var.github_repository_id
        BranchName       = var.base_branch_name
      }
    }
  }

  stage {
    name = "SwiftBuild"

    action {
      name             = "SwiftBuild"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      input_artifacts  = ["source_output"]
      output_artifacts = ["swift_build_output"]
      version          = "1"

      configuration = {
        ProjectName = aws_codebuild_project.swift_build.name
      }
    }
  }

  stage {
    name = "DockerBuild"

    action {
      name             = "DockerBuild"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      input_artifacts  = ["source_output", "swift_build_output"]
      output_artifacts = ["docker_build_output"]
      version          = "1"

      configuration = {
        ProjectName   = aws_codebuild_project.docker_build.name
        PrimarySource = "source_output"
      }
    }
  }

  tags = {
    Name        = "${var.project_name}-${var.environment}-pipeline"
    Environment = var.environment
    Purpose     = "CI/CD Pipeline"
  }
}