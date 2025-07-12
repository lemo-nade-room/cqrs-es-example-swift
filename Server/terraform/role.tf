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
