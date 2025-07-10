provider "aws" {
  region = var.region
}

# ================================
# Application Signals
# ================================
# AWS CC プロバイダーを使用してApplication Signalsを有効化
# これにより自動的にAWSServiceRoleForCloudWatchApplicationSignalsサービスリンクロールが作成されます
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    awscc = {
      source  = "hashicorp/awscc"
      version = "~> 1.0"
    }
  }
}

provider "awscc" {
  region = var.region
}

# Application Signals Discovery - アカウントでApplication Signalsを有効化
resource "awscc_applicationsignals_discovery" "this" {}

# ================================
# X-Ray CloudWatch Logs Permission
# ================================
# X-RayがCloudWatch Logsに書き込むためのリソースポリシー
# OTLP APIを使用するために必要
data "aws_iam_policy_document" "xray_logs_access" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["xray.amazonaws.com"]
    }

    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]

    resources = ["*"]
  }
}

resource "aws_cloudwatch_log_resource_policy" "xray_logs_access" {
  policy_name     = "AWSXRayLogsAccess"
  policy_document = data.aws_iam_policy_document.xray_logs_access.json
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
data "aws_iam_policy_document" "lambda_pull" {
  statement {
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = [
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability",
    ]
  }
}
resource "aws_ecr_repository_policy" "command_server_function" {
  repository = aws_ecr_repository.command_server_function_repository.name
  policy     = data.aws_iam_policy_document.lambda_pull.json
}
resource "aws_ecr_repository_policy" "query_server_function" {
  repository = aws_ecr_repository.query_server_function_repository.name
  policy     = data.aws_iam_policy_document.lambda_pull.json
}

data "aws_ecr_lifecycle_policy_document" "cleanup_untagged" {
  rule {
    priority    = 1
    description = "1日経過後のタグなしイメージは自動削除される"
    selection {
      tag_status   = "untagged"
      count_type   = "sinceImagePushed"
      count_unit   = "days"
      count_number = 1
    }
  }
}
resource "aws_ecr_lifecycle_policy" "command_server_function" {
  repository = aws_ecr_repository.command_server_function_repository.name
  policy     = data.aws_ecr_lifecycle_policy_document.cleanup_untagged.json
}
resource "aws_ecr_lifecycle_policy" "query_server_function" {
  repository = aws_ecr_repository.query_server_function_repository.name
  policy     = data.aws_ecr_lifecycle_policy_document.cleanup_untagged.json
}

# ================================
# Deploy Pipeline
# ================================
# 旧パイプライン（削除予定）
resource "aws_codepipeline" "stage_deploy" {
  name     = "stage-deploy-pipeline"
  role_arn = aws_iam_role.super_role.arn

  artifact_store {
    location = aws_s3_bucket.stage_deploy_codepipeline_bucket.bucket
    type     = "S3"
  }
  pipeline_type = "V2"

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["SourceArtifact"]

      configuration = {
        BranchName       = var.base_branch_name
        ConnectionArn    = data.aws_codestarconnections_connection.github_connection.arn
        FullRepositoryId = var.github_repository_id
        DetectChanges    = true
      }
    }
  }

  stage {
    name = "Build"

    action {
      name             = "CommandBuild"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      input_artifacts  = ["SourceArtifact"]
      output_artifacts = ["CommandBuildArtifact"]
      version          = "1"
      region           = var.region
      run_order        = 1
      namespace        = "CommandBuild"

      configuration = {
        ProjectName = aws_codebuild_project.docker_build_and_push.name
        EnvironmentVariables = jsonencode([
          {
            name  = "DOCKERFILE_PATH"
            value = "Server/Sources/Command/Dockerfile"
          },
          {
            name  = "REPOSITORY_URL"
            value = aws_ecr_repository.command_server_function_repository.repository_url, type = "PLAINTEXT"
          },
          {
            name  = "TAG"
            value = "latest"
          },
        ])
      }
    }

    action {
      name             = "QueryBuild"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      input_artifacts  = ["SourceArtifact"]
      output_artifacts = ["QueryBuildArtifact"]
      version          = "1"
      region           = var.region
      run_order        = 1
      namespace        = "QueryBuild"

      configuration = {
        ProjectName = aws_codebuild_project.docker_build_and_push.name
        EnvironmentVariables = jsonencode([
          {
            name  = "DOCKERFILE_PATH"
            value = "Server/Sources/Query/Dockerfile"
          },
          {
            name  = "REPOSITORY_URL"
            value = aws_ecr_repository.query_server_function_repository.repository_url, type = "PLAINTEXT"
          },
          {
            name  = "TAG"
            value = "latest"
          },
        ])
      }
    }

    action {
      name             = "SAMPackage"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      input_artifacts  = ["SourceArtifact"]
      output_artifacts = ["SAMPackageArtifact"]
      version          = "1"
      region           = var.region
      run_order        = 1

      configuration = {
        ProjectName = aws_codebuild_project.sam_package.name
      }
    }
  }

  stage {
    name = "Deploy"

    action {
      name            = "Deploy"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "CloudFormation"
      version         = "1"
      region          = var.region
      role_arn        = aws_iam_role.super_role.arn
      input_artifacts = ["SAMPackageArtifact"]
      run_order       = 1

      configuration = {
        ActionMode   = "REPLACE_ON_FAILURE"
        StackName    = "Stage"
        Capabilities = "CAPABILITY_IAM,CAPABILITY_AUTO_EXPAND"
        RoleArn      = aws_iam_role.super_role.arn
        TemplatePath = "SAMPackageArtifact::packaged.yaml"
        ParameterOverrides = jsonencode({
          CommandServerFunctionImageUri = "#{CommandBuild.IMAGE_URI}"
          QueryServerFunctionImageUri   = "#{QueryBuild.IMAGE_URI}"
          ServerEnvironment             = "Staging"
        })
      }
    }
  }
}

resource "aws_s3_bucket" "stage_deploy_codepipeline_bucket" {
  bucket = "stage-deploy-codepipeline-bucket-983760593510"
}

# 条件付きSAMパッケージプロジェクト（Command用）
resource "aws_codebuild_project" "sam_package_command" {
  name          = "sam_package_command"
  description   = "Commandサーバー用のSAM packageを行い、packaged.yamlを作成します"
  build_timeout = 5
  service_role  = aws_iam_role.super_role.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/amazonlinux-aarch64-standard:3.0-25.03.03"
    type         = "ARM_CONTAINER"

    environment_variable {
      name  = "COMMAND_SERVER_FUNCTION_IMAGE_URI"
      value = aws_ecr_repository.command_server_function_repository.repository_url
    }

    environment_variable {
      name  = "QUERY_SERVER_FUNCTION_IMAGE_URI"
      value = aws_ecr_repository.query_server_function_repository.repository_url
    }
  }

  logs_config {
    cloudwatch_logs {
      status = "ENABLED"
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "Server/AWS/sam_package_with_detection.yaml"
  }
}

# 条件付きSAMパッケージプロジェクト（Query用）
resource "aws_codebuild_project" "sam_package_query" {
  name          = "sam_package_query"
  description   = "Queryサーバー用のSAM packageを行い、packaged.yamlを作成します"
  build_timeout = 5
  service_role  = aws_iam_role.super_role.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/amazonlinux-aarch64-standard:3.0-25.03.03"
    type         = "ARM_CONTAINER"

    environment_variable {
      name  = "COMMAND_SERVER_FUNCTION_IMAGE_URI"
      value = aws_ecr_repository.command_server_function_repository.repository_url
    }

    environment_variable {
      name  = "QUERY_SERVER_FUNCTION_IMAGE_URI"
      value = aws_ecr_repository.query_server_function_repository.repository_url
    }
  }

  logs_config {
    cloudwatch_logs {
      status = "ENABLED"
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "Server/AWS/sam_package_with_detection.yaml"
  }
}

# 旧プロジェクト（削除予定）
resource "aws_codebuild_project" "sam_package" {
  name          = "sam_package"
  description   = "sam packageを行い、packaged.yamlを作成します"
  build_timeout = 5
  service_role  = aws_iam_role.super_role.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type = "BUILD_GENERAL1_SMALL"
    image        = "aws/codebuild/amazonlinux-aarch64-standard:3.0-25.03.03"
    type         = "ARM_CONTAINER"

    environment_variable {
      name  = "COMMAND_SERVER_FUNCTION_IMAGE_URI"
      value = aws_ecr_repository.command_server_function_repository.repository_url
    }

    environment_variable {
      name  = "QUERY_SERVER_FUNCTION_IMAGE_URI"
      value = aws_ecr_repository.query_server_function_repository.repository_url
    }
  }

  logs_config {
    cloudwatch_logs {
      status = "ENABLED"
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "Server/AWS/sam_package_buildspec.yaml"
  }
}


# 新しい独立したビルドプロジェクト（Command用）
resource "aws_codebuild_project" "docker_build_command" {
  name          = "docker_build_command"
  description   = "Command ServerのDocker ImageをBuildし、ECRへプッシュするCodeBuildプロジェクト"
  build_timeout = 15
  service_role  = aws_iam_role.super_role.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  cache {
    type  = "LOCAL"
    modes = ["LOCAL_DOCKER_LAYER_CACHE", "LOCAL_SOURCE_CACHE"]
  }

  environment {
    compute_type                = "BUILD_GENERAL1_2XLARGE"
    image                       = "aws/codebuild/amazonlinux-aarch64-standard:3.0-25.03.03"
    type                        = "ARM_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = true

    environment_variable {
      name  = "AWS_REGION"
      value = var.region
    }

    environment_variable {
      name  = "SERVICE_NAME"
      value = "Command"
    }

    environment_variable {
      name  = "DOCKERFILE_PATH"
      value = "Server/Sources/Command/Dockerfile"
    }

    environment_variable {
      name  = "REPOSITORY_URL"
      value = aws_ecr_repository.command_server_function_repository.repository_url
    }

    environment_variable {
      name  = "TAG"
      value = "latest"
    }
  }

  logs_config {
    cloudwatch_logs {
      status = "ENABLED"
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "Server/AWS/docker_build_with_change_detection.yaml"
  }
}

# 新しい独立したビルドプロジェクト（Query用）
resource "aws_codebuild_project" "docker_build_query" {
  name          = "docker_build_query"
  description   = "Query ServerのDocker ImageをBuildし、ECRへプッシュするCodeBuildプロジェクト"
  build_timeout = 15
  service_role  = aws_iam_role.super_role.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  cache {
    type  = "LOCAL"
    modes = ["LOCAL_DOCKER_LAYER_CACHE", "LOCAL_SOURCE_CACHE"]
  }

  environment {
    compute_type                = "BUILD_GENERAL1_2XLARGE"
    image                       = "aws/codebuild/amazonlinux-aarch64-standard:3.0-25.03.03"
    type                        = "ARM_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = true

    environment_variable {
      name  = "AWS_REGION"
      value = var.region
    }

    environment_variable {
      name  = "SERVICE_NAME"
      value = "Query"
    }

    environment_variable {
      name  = "DOCKERFILE_PATH"
      value = "Server/Sources/Query/Dockerfile"
    }

    environment_variable {
      name  = "REPOSITORY_URL"
      value = aws_ecr_repository.query_server_function_repository.repository_url
    }

    environment_variable {
      name  = "TAG"
      value = "latest"
    }
  }

  logs_config {
    cloudwatch_logs {
      status = "ENABLED"
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "Server/AWS/docker_build_with_change_detection.yaml"
  }
}

# 旧プロジェクト（削除予定）
resource "aws_codebuild_project" "docker_build_and_push" {
  name          = "docker_build_and_push"
  description   = "Docker ImageをBuildし、ECRへプッシュするCodeBuildプロジェクトです。使用時にはREPOSITORY_URL, DOCKERFILE_PATH, TAGの環境変数のOverrideが必要です"
  build_timeout = 15
  service_role  = aws_iam_role.super_role.arn

  artifacts {
    type = "CODEPIPELINE"
  }

  cache {
    type  = "LOCAL"
    modes = ["LOCAL_DOCKER_LAYER_CACHE"]
  }

  environment {
    compute_type                = "BUILD_GENERAL1_2XLARGE"
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
    buildspec = "Server/AWS/docker_build_with_change_detection.yaml"
  }
}

# ================================
# Change Detection Infrastructure
# ================================
# S3 bucket for storing last commit hash
resource "aws_s3_bucket" "change_detection" {
  bucket = "change-detection-bucket-983760593510"
}

resource "aws_s3_bucket_versioning" "change_detection" {
  bucket = aws_s3_bucket.change_detection.id
  versioning_configuration {
    status = "Enabled"
  }
}

# DynamoDB table for tracking service changes
resource "aws_dynamodb_table" "service_change_tracking" {
  name         = "service-change-tracking"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "service_name"

  attribute {
    name = "service_name"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = {
    Name = "Service Change Tracking"
  }
}

# ================================
# Super IAM Role
# ================================
resource "aws_iam_role" "super_role" {
  name               = "super_role"
  assume_role_policy = data.aws_iam_policy_document.super_role_trust.json
}
resource "aws_iam_role_policy_attachment" "super_role_power_user" {
  role       = aws_iam_role.super_role.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}
resource "aws_iam_role_policy_attachment" "super_role_iam_full" {
  role       = aws_iam_role.super_role.name
  policy_arn = "arn:aws:iam::aws:policy/IAMFullAccess"
}
data "aws_iam_policy_document" "super_role_trust" {
  statement {
    sid     = "AWSServicePrincipals"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type = "Service"
      identifiers = [
        "codebuild.amazonaws.com",
        "codepipeline.amazonaws.com",
        "cloudformation.amazonaws.com",
        "lambda.amazonaws.com",
      ]
    }
  }
}

# ================================
# Command Pipeline (Independent)
# ================================
resource "aws_codepipeline" "command_deploy" {
  name     = "command-deploy-pipeline"
  role_arn = aws_iam_role.super_role.arn

  artifact_store {
    location = aws_s3_bucket.stage_deploy_codepipeline_bucket.bucket
    type     = "S3"
  }
  pipeline_type = "V2"

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["SourceArtifact"]

      configuration = {
        BranchName       = var.base_branch_name
        ConnectionArn    = data.aws_codestarconnections_connection.github_connection.arn
        FullRepositoryId = var.github_repository_id
        DetectChanges    = true
      }
    }
  }

  stage {
    name = "Build"

    action {
      name             = "CommandBuild"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      input_artifacts  = ["SourceArtifact"]
      output_artifacts = ["CommandBuildArtifact"]
      version          = "1"
      region           = var.region
      run_order        = 1
      namespace        = "CommandBuild"

      configuration = {
        ProjectName = aws_codebuild_project.docker_build_command.name
      }
    }

    action {
      name             = "SAMPackage"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      input_artifacts  = ["SourceArtifact"]
      output_artifacts = ["SAMPackageArtifact"]
      version          = "1"
      region           = var.region
      run_order        = 2

      configuration = {
        ProjectName = aws_codebuild_project.sam_package_command.name
        EnvironmentVariables = jsonencode([
          {
            name  = "COMMAND_BUILD_SKIPPED"
            value = "#{CommandBuild.BUILD_SKIPPED}"
          },
          {
            name  = "QUERY_BUILD_SKIPPED"
            value = "true"
          },
          {
            name  = "COMMAND_SERVER_FUNCTION_IMAGE_URI"
            value = "#{CommandBuild.IMAGE_URI}"
          },
          {
            name  = "QUERY_SERVER_FUNCTION_IMAGE_URI"
            value = aws_ecr_repository.query_server_function_repository.repository_url
          }
        ])
      }
    }
  }

  stage {
    name = "Deploy"

    action {
      name            = "Deploy"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "CloudFormation"
      version         = "1"
      region          = var.region
      role_arn        = aws_iam_role.super_role.arn
      input_artifacts = ["SAMPackageArtifact"]
      run_order       = 1

      configuration = {
        ActionMode   = "REPLACE_ON_FAILURE"
        StackName    = "Stage"
        Capabilities = "CAPABILITY_IAM,CAPABILITY_AUTO_EXPAND"
        RoleArn      = aws_iam_role.super_role.arn
        TemplatePath = "SAMPackageArtifact::packaged.yaml"
        ParameterOverrides = jsonencode({
          CommandServerFunctionImageUri = "#{CommandBuild.IMAGE_URI}"
          QueryServerFunctionImageUri   = "${aws_ecr_repository.query_server_function_repository.repository_url}:latest"
          ServerEnvironment             = "Staging"
        })
      }
    }
  }
}

# ================================
# Query Pipeline (Independent)
# ================================
resource "aws_codepipeline" "query_deploy" {
  name     = "query-deploy-pipeline"
  role_arn = aws_iam_role.super_role.arn

  artifact_store {
    location = aws_s3_bucket.stage_deploy_codepipeline_bucket.bucket
    type     = "S3"
  }
  pipeline_type = "V2"

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["SourceArtifact"]

      configuration = {
        BranchName       = var.base_branch_name
        ConnectionArn    = data.aws_codestarconnections_connection.github_connection.arn
        FullRepositoryId = var.github_repository_id
        DetectChanges    = true
      }
    }
  }

  stage {
    name = "Build"

    action {
      name             = "QueryBuild"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      input_artifacts  = ["SourceArtifact"]
      output_artifacts = ["QueryBuildArtifact"]
      version          = "1"
      region           = var.region
      run_order        = 1
      namespace        = "QueryBuild"

      configuration = {
        ProjectName = aws_codebuild_project.docker_build_query.name
      }
    }

    action {
      name             = "SAMPackage"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      input_artifacts  = ["SourceArtifact"]
      output_artifacts = ["SAMPackageArtifact"]
      version          = "1"
      region           = var.region
      run_order        = 2

      configuration = {
        ProjectName = aws_codebuild_project.sam_package_query.name
        EnvironmentVariables = jsonencode([
          {
            name  = "COMMAND_BUILD_SKIPPED"
            value = "true"
          },
          {
            name  = "QUERY_BUILD_SKIPPED"
            value = "#{QueryBuild.BUILD_SKIPPED}"
          },
          {
            name  = "COMMAND_SERVER_FUNCTION_IMAGE_URI"
            value = aws_ecr_repository.command_server_function_repository.repository_url
          },
          {
            name  = "QUERY_SERVER_FUNCTION_IMAGE_URI"
            value = "#{QueryBuild.IMAGE_URI}"
          }
        ])
      }
    }
  }

  stage {
    name = "Deploy"

    action {
      name            = "Deploy"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "CloudFormation"
      version         = "1"
      region          = var.region
      role_arn        = aws_iam_role.super_role.arn
      input_artifacts = ["SAMPackageArtifact"]
      run_order       = 1

      configuration = {
        ActionMode   = "REPLACE_ON_FAILURE"
        StackName    = "Stage"
        Capabilities = "CAPABILITY_IAM,CAPABILITY_AUTO_EXPAND"
        RoleArn      = aws_iam_role.super_role.arn
        TemplatePath = "SAMPackageArtifact::packaged.yaml"
        ParameterOverrides = jsonencode({
          CommandServerFunctionImageUri = "${aws_ecr_repository.command_server_function_repository.repository_url}:latest"
          QueryServerFunctionImageUri   = "#{QueryBuild.IMAGE_URI}"
          ServerEnvironment             = "Staging"
        })
      }
    }
  }
}