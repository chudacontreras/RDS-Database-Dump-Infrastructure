terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

# ==============================================================
# S3 Buckets (idénticos a la solución EC2)
# ==============================================================
resource "aws_s3_bucket" "long_term" {
  bucket = "${var.project_name}-dumps-long-term-${data.aws_caller_identity.current.account_id}"
  tags   = { Name = "${var.project_name}-dumps-long-term", Retention = "8-years" }
}

resource "aws_s3_bucket_versioning" "long_term" {
  bucket = aws_s3_bucket.long_term.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "long_term" {
  bucket = aws_s3_bucket.long_term.id
  rule { apply_server_side_encryption_by_default { sse_algorithm = "AES256" } }
}

resource "aws_s3_bucket_public_access_block" "long_term" {
  bucket                  = aws_s3_bucket.long_term.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "long_term" {
  bucket = aws_s3_bucket.long_term.id
  rule {
    id     = "TransitionToGlacierAndExpire8Years"
    status = "Enabled"
    transition { days = 30; storage_class = "GLACIER" }
    expiration { days = 2920 }
  }
}

resource "aws_s3_bucket" "short_term" {
  bucket = "${var.project_name}-dumps-short-term-${data.aws_caller_identity.current.account_id}"
  tags   = { Name = "${var.project_name}-dumps-short-term", Retention = "1-year" }
}

resource "aws_s3_bucket_versioning" "short_term" {
  bucket = aws_s3_bucket.short_term.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "short_term" {
  bucket = aws_s3_bucket.short_term.id
  rule { apply_server_side_encryption_by_default { sse_algorithm = "AES256" } }
}

resource "aws_s3_bucket_public_access_block" "short_term" {
  bucket                  = aws_s3_bucket.short_term.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "short_term" {
  bucket = aws_s3_bucket.short_term.id
  rule {
    id     = "TransitionToGlacierAndExpire1Year"
    status = "Enabled"
    transition { days = 30; storage_class = "GLACIER" }
    expiration { days = 365 }
  }
}

# ==============================================================
# Security Group para Lambdas en VPC
# ==============================================================
resource "aws_security_group" "lambda" {
  name_prefix = "${var.project_name}-lambda-"
  description = "Security group para Lambda functions de dumps"
  vpc_id      = var.vpc_id

  egress {
    description = "HTTPS para AWS APIs"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Oracle RDS"
    from_port   = 1521
    to_port     = 1521
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "PostgreSQL RDS"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "MySQL RDS"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-lambda-sg" }
}

# ==============================================================
# IAM Role para Lambda
# ==============================================================
resource "aws_iam_role" "lambda" {
  name = "${var.project_name}-lambda-dump-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "s3_upload" {
  name = "S3DumpUploadPolicy"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowPutObject"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:PutObjectTagging"]
        Resource = ["${aws_s3_bucket.long_term.arn}/*", "${aws_s3_bucket.short_term.arn}/*"]
      },
      {
        Sid      = "AllowListBuckets"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = [aws_s3_bucket.long_term.arn, aws_s3_bucket.short_term.arn]
      }
    ]
  })
}

resource "aws_iam_role_policy" "secrets_read" {
  name = "SecretsManagerReadPolicy"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "AllowReadSecrets"
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = ["arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:*"]
    }]
  })
}

# ==============================================================
# Lambda - PostgreSQL
# ==============================================================
data "archive_file" "pg_lambda" {
  count       = var.pg_enabled ? 1 : 0
  type        = "zip"
  source_dir  = "${path.module}/../lambda/postgresql"
  output_path = "${path.module}/.build/postgresql.zip"
}

resource "aws_lambda_function" "postgresql" {
  count         = var.pg_enabled ? 1 : 0
  function_name = "${var.project_name}-dump-postgresql"
  role          = aws_iam_role.lambda.arn
  handler       = "handler.handler"
  runtime       = "python3.12"
  timeout       = 900
  memory_size   = 1024

  filename         = data.archive_file.pg_lambda[0].output_path
  source_code_hash = data.archive_file.pg_lambda[0].output_base64sha256

  ephemeral_storage { size = 10240 }

  vpc_config {
    security_group_ids = [aws_security_group.lambda.id]
    subnet_ids         = var.subnet_ids
  }

  environment {
    variables = {
      DB_HOST              = var.pg_db_host
      DB_PORT              = var.pg_db_port
      DB_USER              = var.pg_db_user
      DB_NAME              = var.pg_db_name
      DB_SECRET_ARN        = var.pg_secret_arn
      SCHEMAS              = var.pg_schemas
      S3_BUCKET_SHORT_TERM = aws_s3_bucket.short_term.id
      S3_BUCKET_LONG_TERM  = aws_s3_bucket.long_term.id
    }
  }

  # layers = [aws_lambda_layer_version.postgresql[0].arn]

  tags = { Name = "${var.project_name}-dump-postgresql" }
}

# ==============================================================
# Lambda - MySQL
# ==============================================================
data "archive_file" "my_lambda" {
  count       = var.my_enabled ? 1 : 0
  type        = "zip"
  source_dir  = "${path.module}/../lambda/mysql"
  output_path = "${path.module}/.build/mysql.zip"
}

resource "aws_lambda_function" "mysql" {
  count         = var.my_enabled ? 1 : 0
  function_name = "${var.project_name}-dump-mysql"
  role          = aws_iam_role.lambda.arn
  handler       = "handler.handler"
  runtime       = "python3.12"
  timeout       = 900
  memory_size   = 1024

  filename         = data.archive_file.my_lambda[0].output_path
  source_code_hash = data.archive_file.my_lambda[0].output_base64sha256

  ephemeral_storage { size = 10240 }

  vpc_config {
    security_group_ids = [aws_security_group.lambda.id]
    subnet_ids         = var.subnet_ids
  }

  environment {
    variables = {
      DB_HOST              = var.my_db_host
      DB_PORT              = var.my_db_port
      DB_USER              = var.my_db_user
      DB_NAME              = var.my_db_name
      DB_SECRET_ARN        = var.my_secret_arn
      S3_BUCKET_SHORT_TERM = aws_s3_bucket.short_term.id
      S3_BUCKET_LONG_TERM  = aws_s3_bucket.long_term.id
    }
  }

  # layers = [aws_lambda_layer_version.mysql[0].arn]

  tags = { Name = "${var.project_name}-dump-mysql" }
}

# ==============================================================
# Lambda - Oracle (Container Image)
# ==============================================================
resource "aws_lambda_function" "oracle" {
  count         = var.ora_enabled ? 1 : 0
  function_name = "${var.project_name}-dump-oracle"
  role          = aws_iam_role.lambda.arn
  package_type  = "Image"
  image_uri     = var.ora_image_uri
  timeout       = 900
  memory_size   = 2048

  ephemeral_storage { size = 10240 }

  vpc_config {
    security_group_ids = [aws_security_group.lambda.id]
    subnet_ids         = var.subnet_ids
  }

  environment {
    variables = {
      DB_HOST              = var.ora_db_host
      DB_PORT              = var.ora_db_port
      DB_USER              = var.ora_db_user
      DB_SERVICE           = var.ora_db_service
      DB_SECRET_ARN        = var.ora_secret_arn
      SCHEMAS              = var.ora_schemas
      S3_BUCKET_SHORT_TERM = aws_s3_bucket.short_term.id
      S3_BUCKET_LONG_TERM  = aws_s3_bucket.long_term.id
    }
  }

  tags = { Name = "${var.project_name}-dump-oracle" }
}
