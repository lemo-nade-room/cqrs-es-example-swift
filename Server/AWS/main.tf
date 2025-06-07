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
resource "aws_codepipeline" "stage_deploy" {
  name     = "stage-deploy-pipeline"
  role_arn = aws_iam_role.codepipeline.arn

  artifact_store {
    location = aws_s3_bucket.stage_deploy_codepipeline_bucket.bucket
    type     = "S3"
  }
  pipeline_type = "V2"

  stage {
    name = "Source"

    action {
      name     = "Source"
      category = "Source"
      owner    = "AWS"
      provider = "CodeStarSourceConnection"
      version  = "1"
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
      name      = "CommandBuild"
      category  = "Build"
      owner     = "AWS"
      provider  = "CodeBuild"
      input_artifacts = ["SourceArtifact"]
      output_artifacts = ["CommandBuildArtifact"]
      version   = "1"
      region    = var.region
      run_order = 1

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
      name      = "QueryBuild"
      category  = "Build"
      owner     = "AWS"
      provider  = "CodeBuild"
      input_artifacts = ["SourceArtifact"]
      output_artifacts = ["QueryBuildArtifact"]
      version   = "1"
      region    = var.region
      run_order = 1

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
      name      = "SAMPackage"
      category  = "Build"
      owner     = "AWS"
      provider  = "CodeBuild"
      input_artifacts = ["SourceArtifact"]
      output_artifacts = ["SAMPackageArtifact"]
      version   = "1"
      region    = var.region
      run_order = 2

      configuration = {
        ProjectName = aws_codebuild_project.sam_package.name
      }
    }
  }

  stage {
    name = "Deploy"

    action {
      name      = "Deploy"
      category  = "Deploy"
      owner     = "AWS"
      provider  = "CloudFormation"
      version   = "1"
      region    = var.region
      role_arn  = aws_iam_role.cloudformation_deploy.arn
      input_artifacts = ["SAMPackageArtifact"]
      run_order = 1

      configuration = {
        ActionMode   = "CREATE_UPDATE"
        StackName    = "Stage"
        Capabilities = "CAPABILITY_IAM,CAPABILITY_AUTO_EXPAND"
        RoleArn      = aws_iam_role.cloudformation_deploy.arn
        TemplatePath = "SAMPackageArtifact::packaged.yaml"
        ParameterOverrides = jsonencode({
          CommandServerFunctionImageUri = aws_ecr_repository.command_server_function_repository.repository_url
          QueryServerFunctionImageUri   = aws_ecr_repository.query_server_function_repository.repository_url
        })
      }
    }
  }
}
resource "aws_iam_role" "cloudformation_deploy" {
  name = "cloudformation_deploy_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.codepipeline.arn
        }
        Action = "sts:AssumeRole"
      },
      {
        Effect = "Allow"
        Principal = {
          Service = "cloudformation.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      },
    ]
  })
}
resource "aws_iam_role_policy" "cloudformation_deploy_policy" {
  name = "cloudformation_deploy_policy"
  role = aws_iam_role.cloudformation_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "cloudformation:CreateStack",
          "cloudformation:UpdateStack",
          "cloudformation:DeleteStack",
          "cloudformation:CreateChangeSet",
          "cloudformation:DeleteChangeSet",
          "cloudformation:DescribeChangeSet",
          "cloudformation:ExecuteChangeSet",
          "cloudformation:DescribeStacks",
          "cloudformation:DescribeStackEvents",
          "cloudformation:GetTemplate",
          "cloudformation:ValidateTemplate"
        ],
        Resource = "*"
      },
    ]
  })
}
resource "aws_iam_role_policy" "cloudformation_deploy_s3" {
  name = "cloudformation-deploy-s3"
  role = aws_iam_role.cloudformation_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion"
        ]
        Resource = "${aws_s3_bucket.stage_deploy_codepipeline_bucket.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketVersioning"
        ]
        Resource = aws_s3_bucket.stage_deploy_codepipeline_bucket.arn
      }
    ]
  })
}

resource "aws_s3_bucket" "stage_deploy_codepipeline_bucket" {
  bucket = "stage-deploy-codepipeline-bucket"
}

resource "aws_iam_role" "codepipeline" {
  name               = "codepipeline_role"
  assume_role_policy = data.aws_iam_policy_document.codepipeline_trust.json
}
data "aws_iam_policy_document" "codepipeline_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type = "Service"
      identifiers = ["codepipeline.amazonaws.com"]
    }
  }
}
resource "aws_iam_role_policy" "codepipeline_use_connection" {
  name = "codepipeline-use-connection"
  role = aws_iam_role.codepipeline.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "codestar-connections:UseConnection"
        Resource = data.aws_codestarconnections_connection.github_connection.arn
      }
    ]
  })
}
resource "aws_iam_role_policy" "codepipeline_artifacts_s3" {
  name = "codepipeline-artifacts-s3"
  role = aws_iam_role.codepipeline.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:GetObjectVersion"
        ]
        Resource = "${aws_s3_bucket.stage_deploy_codepipeline_bucket.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketVersioning"
        ]
        Resource = aws_s3_bucket.stage_deploy_codepipeline_bucket.arn
      }
    ]
  })
}
resource "aws_iam_role_policy" "codepipeline_start_build" {
  name = "codepipeline-start-build"
  role = aws_iam_role.codepipeline.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "codebuild:StartBuild",
          "codebuild:BatchGetBuilds"
        ]
        Resource = [
          aws_codebuild_project.docker_build_and_push.arn,
          aws_codebuild_project.sam_package.arn
        ]
      }
    ]
  })
}

resource "aws_codebuild_project" "sam_package" {
  name          = "sam_package"
  description   = "sam packageを行い、packaged.yamlを作成します"
  build_timeout = 5
  service_role  = aws_iam_role.sam_package_codebuild.arn

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
resource "aws_iam_role" "sam_package_codebuild" {
  name = "sam_package_codebuild_role"
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
resource "aws_iam_role_policy" "sam_package_role_artifacts_s3" {
  name = "sam_package_artifacts_s3"
  role = aws_iam_role.sam_package_codebuild.id

  policy = aws_iam_role_policy.docker_build_role_artifacts_s3.policy
}
resource "aws_iam_role_policy" "sam_package_role_logs" {
  name   = "sam_package_logs"
  role   = aws_iam_role.sam_package_codebuild.id
  policy = aws_iam_role_policy.docker_build_role_logs.policy
}

resource "aws_codebuild_project" "docker_build_and_push" {
  name          = "docker_build_and_push"
  description   = "Docker ImageをBuildし、ECRへプッシュするCodeBuildプロジェクトです。使用時にはREPOSITORY_URL, DOCKERFILE_PATH, TAGの環境変数のOverrideが必要です"
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
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer"
        ]
        Resource = [
          aws_ecr_repository.command_server_function_repository.arn,
          aws_ecr_repository.query_server_function_repository.arn
        ]
      }
    ]
  })
}
resource "aws_iam_role_policy" "docker_build_ecr_auth" {
  name = "docker_build_ecr_auth"
  role = aws_iam_role.docker_build_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      }
    ]
  })
}
resource "aws_iam_role_policy" "docker_build_role_logs" {
  name = "docker_build_logs"
  role = aws_iam_role.docker_build_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      }
    ]
  })
}
resource "aws_iam_role_policy" "docker_build_role_artifacts_s3" {
  name = "docker_build_artifacts_s3"
  role = aws_iam_role.docker_build_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject"
        ]
        Resource = "${aws_s3_bucket.stage_deploy_codepipeline_bucket.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketVersioning"
        ]
        Resource = aws_s3_bucket.stage_deploy_codepipeline_bucket.arn
      }
    ]
  })
}