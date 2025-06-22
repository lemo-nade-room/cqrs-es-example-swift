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

output "application_signals_enabled" {
  value       = awscc_applicationsignals_discovery.this.id
  description = "Application Signals Discovery resource ID"
}

output "xray_logs_policy_name" {
  description = "Name of the CloudWatch Logs resource policy for X-Ray"
  value       = aws_cloudwatch_log_resource_policy.xray_logs_access.id
}