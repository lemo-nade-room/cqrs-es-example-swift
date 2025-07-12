# ECR Repository outputs
output "ecr_repository_command_url" {
  description = "URL of the ECR repository for Lambda Command server"
  value       = aws_ecr_repository.lambda_command.repository_url
}

output "ecr_repository_command_arn" {
  description = "ARN of the ECR repository for Lambda Command server"
  value       = aws_ecr_repository.lambda_command.arn
}

# S3 Bucket outputs
output "s3_bucket_artifacts_name" {
  description = "Name of the S3 bucket for CodePipeline artifacts"
  value       = aws_s3_bucket.codepipeline_artifacts.id
}

output "s3_bucket_artifacts_arn" {
  description = "ARN of the S3 bucket for CodePipeline artifacts"
  value       = aws_s3_bucket.codepipeline_artifacts.arn
}

# CodeBuild outputs
output "codebuild_project_name" {
  description = "Name of the CodeBuild project"
  value       = aws_codebuild_project.main.name
}

output "codebuild_project_arn" {
  description = "ARN of the CodeBuild project"
  value       = aws_codebuild_project.main.arn
}

# CodePipeline outputs
output "codepipeline_name" {
  description = "Name of the CodePipeline"
  value       = aws_codepipeline.main.name
}

output "codepipeline_arn" {
  description = "ARN of the CodePipeline"
  value       = aws_codepipeline.main.arn
}