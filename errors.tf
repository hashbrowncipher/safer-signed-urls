resource "random_string" "public-bucket" {
  length  = 16
  special = false
  upper   = false
}

resource "aws_s3_bucket" "public" {
  bucket = random_string.public-bucket.result
}

resource "aws_s3_bucket_public_access_block" "public" {
  bucket = aws_s3_bucket.public.bucket

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "public" {
  bucket = aws_s3_bucket.public.bucket

  policy = jsonencode({
    Version : "2012-10-17",
    Statement : [
      {
        "Effect" : "Allow",
        "Principal" : {
          "AWS" : "arn:aws:iam::cloudfront:user/CloudFront Origin Access Identity ${aws_cloudfront_origin_access_identity.public.id}"
        },
        "Action" : "s3:GetObject",
        "Resource" : "${aws_s3_bucket.public.arn}/*"
      }
    ]
  })
}

resource "aws_s3_bucket_server_side_encryption_configuration" "public" {
  bucket = aws_s3_bucket.public.bucket

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_object" "public_403" {
  bucket                 = aws_s3_bucket.public.bucket
  key                    = "_errors/403"
  content                = "403\n"
  content_type           = "text/plain"
  server_side_encryption = "AES256"
}

resource "aws_cloudfront_origin_access_identity" "public" {
  comment = "For fetching public assets (error pages)"
}
