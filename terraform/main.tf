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

data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# ==============================================================
# S3 Buckets
# ==============================================================
resource "aws_s3_bucket" "long_term" {
  bucket = "${var.project_name}-dumps-long-term-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name        = "${var.project_name}-dumps-long-term"
    Retention   = "8-years"
  }
}

resource "aws_s3_bucket_versioning" "long_term" {
  bucket = aws_s3_bucket.long_term.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "long_term" {
  bucket = aws_s3_bucket.long_term.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
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

    transition {
      days          = 30
      storage_class = "GLACIER"
    }

    expiration {
      days = 2920
    }
  }
}

resource "aws_s3_bucket" "short_term" {
  bucket = "${var.project_name}-dumps-short-term-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name      = "${var.project_name}-dumps-short-term"
    Retention = "1-year"
  }
}

resource "aws_s3_bucket_versioning" "short_term" {
  bucket = aws_s3_bucket.short_term.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "short_term" {
  bucket = aws_s3_bucket.short_term.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
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

    transition {
      days          = 30
      storage_class = "GLACIER"
    }

    expiration {
      days = 365
    }
  }
}

# ==============================================================
# EFS
# ==============================================================
resource "aws_efs_file_system" "dumps" {
  encrypted        = true
  performance_mode = "generalPurpose"
  throughput_mode  = "bursting"

  tags = {
    Name = "${var.project_name}-dumps-efs"
  }
}

resource "aws_efs_mount_target" "dumps" {
  file_system_id  = aws_efs_file_system.dumps.id
  subnet_id       = var.subnet_id
  security_groups = [aws_security_group.efs.id]
}

# ==============================================================
# Security Groups
# ==============================================================
resource "aws_security_group" "bastion" {
  name_prefix = "${var.project_name}-bastion-"
  description = "Security group para instancia bastion de dumps"
  vpc_id      = var.vpc_id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  egress {
    description = "HTTPS para AWS APIs y repos"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "HTTP para repos de paquetes"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "NFS para EFS"
    from_port   = 2049
    to_port     = 2049
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

  tags = {
    Name = "${var.project_name}-bastion-sg"
  }
}

resource "aws_security_group" "efs" {
  name_prefix = "${var.project_name}-efs-"
  description = "Security group para EFS mount targets"
  vpc_id      = var.vpc_id

  ingress {
    description     = "NFS desde bastion"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  tags = {
    Name = "${var.project_name}-efs-sg"
  }
}

# ==============================================================
# IAM Role - Minimo Privilegio
# ==============================================================
resource "aws_iam_role" "bastion" {
  name = "${var.project_name}-bastion-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-bastion-role"
  }
}

resource "aws_iam_role_policy" "s3_upload" {
  name = "S3DumpUploadPolicy"
  role = aws_iam_role.bastion.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowPutObjectToDumpBuckets"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:PutObjectTagging"
        ]
        Resource = [
          "${aws_s3_bucket.long_term.arn}/*",
          "${aws_s3_bucket.short_term.arn}/*"
        ]
      },
      {
        Sid    = "AllowListDumpBuckets"
        Effect = "Allow"
        Action = ["s3:ListBucket"]
        Resource = [
          aws_s3_bucket.long_term.arn,
          aws_s3_bucket.short_term.arn
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_managed" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "cloudwatch_logs" {
  name = "CloudWatchLogsPolicy"
  role = aws_iam_role.bastion.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/dumps/*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "secrets_manager" {
  name = "SecretsManagerReadPolicy"
  role = aws_iam_role.bastion.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowReadSecrets"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = [
          "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:*"
        ]
        Condition = {
          StringEquals = {
            "secretsmanager:VersionStage" = "AWSCURRENT"
          }
        }
      }
    ]
  })
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${var.project_name}-bastion-profile"
  role = aws_iam_role.bastion.name
}

# ==============================================================
# EC2 Bastion Instance
# ==============================================================
resource "aws_instance" "bastion" {
  ami                    = data.aws_ssm_parameter.al2023_ami.value
  instance_type          = var.instance_type
  key_name               = var.key_pair_name
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.bastion.id]
  iam_instance_profile   = aws_iam_instance_profile.bastion.name

  root_block_device {
    volume_size = 50
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = templatefile("${path.module}/user_data.sh.tpl", {
    efs_id     = aws_efs_file_system.dumps.id
    aws_region = var.aws_region
  })

  depends_on = [aws_efs_mount_target.dumps]

  tags = {
    Name = "${var.project_name}-bastion-dumps"
  }
}
