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

# ================================
# Stage Deploy Pipeline
# ================================
# resource "aws_codepipeline" "stage_deploy_pipeline" {
#   name = "stage_deploy_pipeline"
#   role_arn = aws_iam_role.pipeline_role.arn
#   artifact_store {
#     location = "codepipeline-ap-northeast-1-3f6dca6611cc-4e8c-8447-61f82737e9bf"
#     type = "S3"
#   }
#   stages {
#     name = "Source"
#     action = [
#       {
#         name = "Source"
#         category = "Source"
#         owner = "AWS"
#         configuration {
#       BranchName = "main"
#       ConnectionArn = "arn:aws:codeconnections:ap-northeast-1:833542146484:connection/f3219a70-5634-4694-8e07-29412416bfb6"
#       DetectChanges = "false"
#       FullRepositoryId = "lemo-nade-room/cqrs-es-example-swift"
#       OutputArtifactFormat = "CODE_ZIP"
#       }
#         provider = "CodeStarSourceConnection"
#         version = "1"
#         output_artifacts = [
#           "SourceArtifact"
#         ]
#         run_order = 1
#       }
#     ]
#   }
#   stages {
#     name = "Build"
#     action = [
#       {
#         name = "Build"
#         category = "Build"
#         owner = "AWS"
#         configuration {
#       ProjectName = "cqrs-es-example-swift-stg-sam"
#       }
#         input_artifacts = [
#           "SourceArtifact"
#         ]
#         provider = "CodeBuild"
#         version = "1"
#         output_artifacts = [
#           "BuildArtifact"
#         ]
#         run_order = 1
#       }
#     ]
#   }
# }

# resource "aws_iam_role" "pipeline_role" {
#   name = "pipeline_role"
#   assume_role_policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [
#       {
#         Action = "sts:AssumeRole"
#         Effect = "Allow"
#         Principal = {
#           Service = "codepipeline.amazonaws.com"
#         }
#       }
#     ]
#   })
# }
#
# resource "aws_iam_role" "build_role" {
#   name = "build_role"
#   assume_role_policy = jsonencode({
#     Version = "2012-10-17"
#     Statement = [
#       {
#         Action = "sts:AssumeRole"
#         Effect = "Allow"
#         Principal = {
#           Service = "codebuild.amazonaws.com"
#         }
#       }
#     ]
#   })
# }
