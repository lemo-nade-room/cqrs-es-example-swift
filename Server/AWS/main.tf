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
