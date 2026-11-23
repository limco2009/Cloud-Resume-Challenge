terraform {
  required_version = ">= 1.10"

  backend "s3" {
    bucket       = "my-terraform-state-bucket-limco"
    key          = "static-website/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
}

provider "aws" {
  region = "us-east-1" # Required for CloudFront ACM certificates
}

variable "domain_name" {
  description = "Custom subdomain managed in GoDaddy"
  type        = string
  default     = "www.mylimco.com"
}

resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "random_password" "origin_verify_secret" {
  length  = 32
  special = false
}

locals {
  mime_types = {
    ".html" = "text/html"
    ".css"  = "text/css"
    ".js"   = "application/javascript"
    ".json" = "application/json"
    ".png"  = "image/png"
    ".jpg"  = "image/jpeg"
    ".svg"  = "image/svg+xml"
    ".ico"  = "image/x-icon"
  }
}

# ==============================================================================
# 1. SSL CERTIFICATE: AWS CERTIFICATE MANAGER (FOR GODADDY DNS VALIDATION)
# ==============================================================================
resource "aws_acm_certificate" "site_cert" {
  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate_validation" "site_cert_validation" {
  certificate_arn = aws_acm_certificate.site_cert.arn
}

# ==============================================================================
# 2. BACKEND: DYNAMODB & PROTECTED PYTHON LAMBDA
# ==============================================================================
resource "aws_dynamodb_table" "page_views" {
  name         = "PageViews"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "page_id"

  attribute {
    name = "page_id"
    type = "S"
  }
}

resource "aws_iam_role" "lambda_role" {
  name = "page_views_lambda_role_${random_id.bucket_suffix.hex}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "dynamodb_access" {
  name = "dynamodb_page_views_policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["dynamodb:UpdateItem", "dynamodb:GetItem"]
      Resource = aws_dynamodb_table.page_views.arn
    }]
  })
}

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/counter.py"
  output_path = "${path.module}/counter.zip"
}

resource "aws_lambda_function" "view_counter" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "IncrementPageViews-${random_id.bucket_suffix.hex}"
  role             = aws_iam_role.lambda_role.arn
  handler          = "counter.lambda_handler"
  runtime          = "python3.12"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  environment {
    variables = {
      TABLE_NAME    = aws_dynamodb_table.page_views.name
      ORIGIN_SECRET = random_password.origin_verify_secret.result
    }
  }
}

resource "aws_lambda_function_url" "counter_url" {
  function_name      = aws_lambda_function.view_counter.function_name
  authorization_type = "NONE"
}

# ==============================================================================
# 3. FRONTEND: PRIVATE S3 BUCKET & AUTOMATED FILE UPLOADS
# ==============================================================================
resource "aws_s3_bucket" "website_bucket" {
  bucket        = "my-static-site-${random_id.bucket_suffix.hex}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "website_pab" {
  bucket = aws_s3_bucket.website_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "index_html" {
  bucket       = aws_s3_bucket.website_bucket.id
  key          = "index.html"
  content_type = "text/html"
  source       = "${path.module}/website/index.html"
  etag         = filemd5("${path.module}/website/index.html")
}

resource "aws_s3_object" "static_assets" {
  for_each = setsubtract(fileset("${path.module}/website", "**/*"), ["index.html"])

  bucket = aws_s3_bucket.website_bucket.id
  key    = each.value
  source = "${path.module}/website/${each.value}"

  content_type = lookup(
    local.mime_types,
    regex("\\.[^.]+$", each.value),
    "application/octet-stream"
  )

  etag = filemd5("${path.module}/website/${each.value}")
}

# ==============================================================================
# 4. CDN: CLOUDFRONT DISTRIBUTION (COMPATIBLE WITH $0/MO FLAT-RATE FREE PLAN)
# ==============================================================================
resource "aws_cloudfront_origin_access_control" "s3_oac" {
  name                              = "s3-oac-${random_id.bucket_suffix.hex}"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "cdn" {
  enabled             = true
  default_root_object = "index.html"
  aliases             = [var.domain_name]

  # Prevents Terraform from removing the bundled WAF managed by the $0 Free Plan
  lifecycle {
    ignore_changes = [web_acl_id]
  }

  origin {
    domain_name              = aws_s3_bucket.website_bucket.bucket_regional_domain_name
    origin_id                = "S3-Origin"
    origin_access_control_id = aws_cloudfront_origin_access_control.s3_oac.id
  }

  origin {
    domain_name = trimsuffix(trimprefix(aws_lambda_function_url.counter_url.function_url, "https://"), "/")
    origin_id   = "Lambda-API-Origin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    custom_header {
      name  = "X-Origin-Verify"
      value = random_password.origin_verify_secret.result
    }
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "S3-Origin"
    viewer_protocol_policy = "redirect-to-https"
    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  ordered_cache_behavior {
    path_pattern             = "/api/*"
    allowed_methods          = ["GET", "HEAD", "OPTIONS"]
    cached_methods           = ["GET", "HEAD"]
    target_origin_id         = "Lambda-API-Origin"
    viewer_protocol_policy   = "redirect-to-https"
    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
    origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.site_cert_validation.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

resource "aws_s3_bucket_policy" "allow_cloudfront" {
  bucket = aws_s3_bucket.website_bucket.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontServicePrincipalReadOnly"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.website_bucket.arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.cdn.arn
        }
      }
    }]
  })
}

resource "terraform_data" "invalidate_cache" {
  triggers_replace = [
    aws_s3_object.index_html.etag,
    jsonencode({ for k, v in aws_s3_object.static_assets : k => v.etag })
  ]

  provisioner "local-exec" {
    command = "aws cloudfront create-invalidation --distribution-id ${aws_cloudfront_distribution.cdn.id} --paths '/*'"
  }
}

# ==============================================================================
# 5. OUTPUTS
# ==============================================================================
output "godaddy_step1_acm_validation_records" {
  description = "Add this CNAME record in GoDaddy to validate your SSL certificate"
  value = [
    for dvo in aws_acm_certificate.site_cert.domain_validation_options : {
      type  = dvo.resource_record_type
      name  = dvo.resource_record_name
      value = dvo.resource_record_value
    }
  ]
}

output "godaddy_step2_cloudfront_cname" {
  description = "Add this CNAME record in GoDaddy to point your domain to CloudFront"
  value = {
    type  = "CNAME"
    name  = "www"
    value = aws_cloudfront_distribution.cdn.domain_name
  }
}

output "live_website_url" {
  description = "Your live custom domain URL"
  value       = "https://${var.domain_name}"
}
