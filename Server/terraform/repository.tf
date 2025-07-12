# ECR Repository for Lambda container images
resource "aws_ecr_repository" "lambda_command" {
  name                 = "${var.project_name}-lambda-command"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Name        = "${var.project_name}-lambda-command"
    Environment = var.environment
    Purpose     = "Lambda Command Server Container Images"
  }
}

# Lifecycle policy document
data "aws_ecr_lifecycle_policy_document" "lambda_command" {
  rule {
    priority    = 1
    description = "Keep cache-buildkit images"

    selection {
      tag_status       = "tagged"
      tag_pattern_list = ["cache-buildkit"]
      count_type       = "imageCountMoreThan"
      count_number     = 1
    }

    action {
      type = "expire"
    }
  }

  rule {
    priority    = 2
    description = "Keep last 5 tagged images (excluding cache)"

    selection {
      tag_status       = "tagged"
      tag_pattern_list = ["*"]
      count_type       = "imageCountMoreThan"
      count_number     = 5
    }

    action {
      type = "expire"
    }
  }

  rule {
    priority    = 3
    description = "Expire untagged images after 1 day"

    selection {
      tag_status   = "untagged"
      count_type   = "sinceImagePushed"
      count_unit   = "days"
      count_number = 1
    }

    action {
      type = "expire"
    }
  }
}

# Lifecycle policy for Command repository
resource "aws_ecr_lifecycle_policy" "lambda_command_policy" {
  repository = aws_ecr_repository.lambda_command.name
  policy     = data.aws_ecr_lifecycle_policy_document.lambda_command.json
}

