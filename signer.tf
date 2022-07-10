resource "random_string" "private-bucket" {
  length  = 16
  special = false
  upper   = false
}

resource "aws_s3_bucket" "private" {
  bucket = random_string.private-bucket.result
}

resource "aws_s3_bucket_public_access_block" "private" {
  bucket = aws_s3_bucket.private.bucket

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "private" {
  bucket = aws_s3_bucket.private.bucket

  policy = jsonencode({
    Version : "2012-10-17",
    Statement : [
      {
        "Effect" : "Allow",
        "Principal" : "*",
        "Action" : "*",
        "Resource" : [
          "${aws_s3_bucket.private.arn}",
          "${aws_s3_bucket.private.arn}/*",
        ],
        "Condition" : {
          "StringEquals" : {
            "s3:signatureversion" : "AWS4-HMAC-SHA256"
          }
        }
      }
    ]
  })
}

resource "aws_s3_bucket_server_side_encryption_configuration" "private" {
  bucket = aws_s3_bucket.private.bucket

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_object" "test" {
  bucket                 = aws_s3_bucket.private.bucket
  key                    = "test"
  content_base64         = "WDVPIVAlQEFQWzRcUFpYNTQoUF4pN0NDKTd9JEVJQ0FSLVNUQU5EQVJELUFOVElWSVJVUy1URVNULUZJTEUhJEgrSCoK"
  content_type           = "text/plain"
  server_side_encryption = "AES256"
}

resource "aws_cloudfront_distribution" "assets" {
  aliases         = [var.domain_name]
  comment         = "Authentication for s3://${aws_s3_bucket.private.bucket}"
  enabled         = true
  is_ipv6_enabled = true
  price_class     = "PriceClass_100"

  origin {
    domain_name = aws_s3_bucket.private.bucket_regional_domain_name
    origin_id   = "private"
  }

  origin {
    domain_name = aws_s3_bucket.public.bucket_regional_domain_name
    origin_id   = "public"

    s3_origin_config {
      origin_access_identity = "origin-access-identity/cloudfront/${aws_cloudfront_origin_access_identity.public.id}"
    }
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "private"
    viewer_protocol_policy = "https-only"

    default_ttl = 0
    min_ttl     = 0
    max_ttl     = 0

    forwarded_values {
      query_string = true

      headers = ["cf-auth"]
      cookies {
        forward = "none"
      }
    }

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.hmac.arn

    }
  }

  ordered_cache_behavior {
    path_pattern = "/"

    allowed_methods = ["GET", "HEAD", "OPTIONS"]
    cached_methods  = ["GET", "HEAD", "OPTIONS"]

    target_origin_id       = "public"
    viewer_protocol_policy = "https-only"

    default_ttl = 0
    min_ttl     = 0
    max_ttl     = 0

    lambda_function_association {
      event_type   = "viewer-request"
      lambda_arn   = aws_lambda_function.signer.qualified_arn
      include_body = false
    }

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }
  }

  ordered_cache_behavior {
    allowed_methods = ["GET", "HEAD", "OPTIONS"]
    cached_methods  = ["GET", "HEAD", "OPTIONS"]

    target_origin_id       = "public"
    viewer_protocol_policy = "https-only"
    path_pattern           = "/_errors/*"


    default_ttl = 300
    min_ttl     = 300
    max_ttl     = 300

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    minimum_protocol_version = "TLSv1.2_2021"
    acm_certificate_arn      = aws_acm_certificate.assets.arn
    ssl_support_method       = "sni-only"
  }

  custom_error_response {
    error_caching_min_ttl = 300
    error_code            = 403
    response_code         = 403
    response_page_path    = "/_errors/403"
  }
}

resource "aws_cloudfront_function" "hmac" {
  name    = "hmac"
  runtime = "cloudfront-js-1.0"
  publish = true
  code    = file("${path.module}/hmac.js")
}


resource "aws_iam_role" "reader" {
  name = "s3-reader"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = [
            "lambda.amazonaws.com",
            "edgelambda.amazonaws.com",
          ]
        }
      },
    ]
  })

  inline_policy {
    name = "policy"
    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Action   = "s3:GetObject"
          Effect   = "Allow"
          Resource = "${aws_s3_bucket.private.arn}/*"
        },
      ]
    })
  }
}

resource "aws_acm_certificate" "assets" {
  provider          = aws.acm
  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}


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
