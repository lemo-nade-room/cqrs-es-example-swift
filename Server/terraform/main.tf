provider "aws" {
  region = var.region
}

# 現在のAWSアカウント情報を取得
data "aws_caller_identity" "current" {}
