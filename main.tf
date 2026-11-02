# Stockage chiffré des documents clients (production)
# Durci : chiffrement KMS, versioning, accès public bloqué, logs d'accès,
# réplication inter-région, cycle de vie, notifications d'événements.

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "eu-west-3"
}

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------- KMS
resource "aws_kms_key" "docs" {
  description             = "Chiffrement des documents clients"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "RootAccount"
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
      Action    = "kms:*"
      Resource  = "*"
    }]
  })
}

# ---------------------------------------------------------------- Bucket
resource "aws_s3_bucket" "docs" {
  bucket = "acme-prod-customer-docs"
}

resource "aws_s3_bucket_public_access_block" "docs" {
  bucket                  = aws_s3_bucket.docs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "docs" {
  bucket = aws_s3_bucket.docs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "docs" {
  bucket = aws_s3_bucket.docs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.docs.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_logging" "docs" {
  bucket        = aws_s3_bucket.docs.id
  target_bucket = "acme-prod-access-logs"
  target_prefix = "customer-docs/"
}

resource "aws_s3_bucket_lifecycle_configuration" "docs" {
  bucket = aws_s3_bucket.docs.id
  rule {
    id     = "archive"
    status = "Enabled"
    filter {}
    transition {
      days          = 90
      storage_class = "GLACIER"
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_notification" "docs" {
  bucket      = aws_s3_bucket.docs.id
  eventbridge = true
}

resource "aws_s3_bucket_replication_configuration" "docs" {
  depends_on = [aws_s3_bucket_versioning.docs]
  bucket     = aws_s3_bucket.docs.id
  role       = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/s3-replication"

  rule {
    id     = "dr-copy"
    status = "Enabled"
    destination {
      bucket        = "arn:aws:s3:::acme-dr-customer-docs"
      storage_class = "STANDARD_IA"
    }
  }
}

# dev2 : acc�s SSH au bastion pour le debug
resource "aws_security_group" "bastion" {
  name        = "bastion-sg"
  description = "Bastion SSH access"

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
