output "github_connection_arn" {
  value       = data.aws_codestarconnections_connection.github_connection.arn
  description = "コンソールから設定済みのGitHubとのCodeConnectionのARN"
}

output "command_server_function_image_uri" {
  value       = aws_ecr_repository.command_server_function_repository.repository_url
  description = "Command ServerのLambda Docker Imageを保管するECRリポジトリのImage URI"
}

output "query_server_function_image_uri" {
  value       = aws_ecr_repository.query_server_function_repository.repository_url
  description = "Query ServerのLambda Docker Imageを保管するECRリポジトリのImage URI"
}