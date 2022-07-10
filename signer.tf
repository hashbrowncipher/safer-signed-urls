data "archive_file" "signer" {
  type        = "zip"
  output_path = "${path.module}/signer.zip"

  source {
    filename = "lambda_function.py"
    content  = file("${path.module}/signer.py")
  }

  source {
    filename = "config.ini"
    content  = <<-EOT
[default]
s3_bucket_region = ${var.region}
s3_bucket = ${aws_s3_bucket.private.bucket}
s3_object = ${aws_s3_object.test.key}
cf_domain = ${var.domain_name}
pepper = ${random_password.pepper.result}
EOT
  }
}

resource "aws_lambda_function" "signer" {
  provider = aws.acm

  filename         = data.archive_file.signer.output_path
  function_name    = "signer"
  handler          = "lambda_function.lambda_handler"
  publish          = true
  role             = aws_iam_role.reader.arn
  runtime          = "python3.9"
  source_code_hash = data.archive_file.signer.output_base64sha256
}
