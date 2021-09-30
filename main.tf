# 定数定義
variable "aws_access_key" {}
variable "aws_secret_key" {}
variable "aws_region" {}
variable "host_bucket_name" {}
variable "notification_mailaddress" {}

# ローカル定数
locals {
  origin_id = "webOrigin"
}

# Cacheポリシー
data "aws_cloudfront_cache_policy" "CachingOptimized" {
  name = "Managed-CachingOptimized"
}
data "aws_cloudfront_cache_policy" "CachingDisabled" {
  name = "Managed-CachingDisabled"
}

# provider設定
provider "aws" {
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key
  region     = var.aws_region
}

provider "aws" {
  alias      = "global"
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key
  region     = "us-east-1"
}

# s3アクセスログ用bucket
resource "aws_s3_bucket" "s3LogBucket" {
  bucket = "${var.host_bucket_name}-s3-accesslog"
  acl    = "log-delivery-write"

}

# cfアクセスログ用bucket
resource "aws_s3_bucket" "cfLogBucket" {
  bucket = "${var.host_bucket_name}-cf-accesslog"
  acl    = "private"

}

# コンテンツbucket
resource "aws_s3_bucket" "webBucket" {
  bucket = var.host_bucket_name
  acl    = "public-read-write"
  logging {
    target_bucket = aws_s3_bucket.s3LogBucket.id
    target_prefix = "s3log/"
  }
  website {
    index_document = "index.html"
  }

}
resource "aws_s3_bucket_policy" "webBucketPolicy" {
  bucket = aws_s3_bucket.webBucket.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowGetPolicy"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.webBucket.arn}/*"
      }
    ]
  })
}



# CFディストリビューション
resource "aws_cloudfront_distribution" "distribution" {
  # Origin設定
  origin {
    domain_name = aws_s3_bucket.webBucket.website_endpoint
    origin_id   = local.origin_id
    custom_origin_config {
      http_port                = 80
      https_port               = 443
      origin_keepalive_timeout = 5
      origin_protocol_policy   = "http-only"
      origin_read_timeout      = 30
      origin_ssl_protocols = [
        "TLSv1",
        "TLSv1.1",
        "TLSv1.2",
      ]
    }
  }
  enabled = true
  logging_config {
    include_cookies = false
    bucket          = aws_s3_bucket.cfLogBucket.bucket_domain_name
    prefix          = "cfprefix"

  }

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = local.origin_id

    cache_policy_id = data.aws_cloudfront_cache_policy.CachingDisabled.id

    viewer_protocol_policy = "allow-all"
  }
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

# 監視設定
# 通知先の作成
# SNS Topic
resource "aws_sns_topic" "tfNotificationGlobalTopic" {
  provider   = aws.global
  fifo_topic = false
  name       = "tfNotificationGlobalTopic"
}

# サブスクリプション登録
resource "aws_sns_topic_subscription" "subscription1" {
  provider  = aws.global
  topic_arn = aws_sns_topic.tfNotificationGlobalTopic.arn
  protocol  = "email"
  endpoint  = var.notification_mailaddress
}

# 確認メールが飛んでくるのでclickする必要あり。

# 監視設定
resource "aws_cloudwatch_metric_alarm" "tfWatchAlarm" {
  provider            = aws.global
  namespace           = "AWS/CloudFront"
  alarm_name          = "tfWatchAlarm"
  metric_name         = "5xxErrorRate"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "1"
  period              = "300"
  statistic           = "Average"
  threshold           = "30"
  dimensions = {
    DistributionId = aws_cloudfront_distribution.distribution.id
    Region         = "Global"
  }

  actions_enabled = true
  alarm_actions   = [aws_sns_topic.tfNotificationGlobalTopic.arn]

}


# cloudfrontのドメインを出力
output "cloudfront_domain" {
  value = aws_cloudfront_distribution.distribution.domain_name
}
