variable "region" {
  default     = "ap-northeast-1"
  description = "AWSのデプロイ先のリージョン"
  type        = string
}

variable "base_branch_name" {
  default     = "main"
  description = "GitHubのベースブランチ名"
  type        = string
}

variable "github_repository_id" {
  default     = "lemo-nade-room/cqrs-es-example-swift"
  description = "GitHubのリポジトリID"
  type        = string
}