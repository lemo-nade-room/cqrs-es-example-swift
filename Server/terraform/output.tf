# ECR Repository outputs
output "ecr_repository_command_url" {
  description = "URL of the ECR repository for Lambda Command server"
  value       = aws_ecr_repository.lambda_command.repository_url
}

output "ecr_repository_command_arn" {
  description = "ARN of the ECR repository for Lambda Command server"
  value       = aws_ecr_repository.lambda_command.arn
}