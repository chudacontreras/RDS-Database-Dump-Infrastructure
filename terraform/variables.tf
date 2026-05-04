variable "aws_region" {
  description = "Region de AWS"
  type        = string
  default     = "us-east-1"
}

variable "vpc_id" {
  description = "ID de la VPC"
  type        = string
}

variable "subnet_id" {
  description = "ID de la subnet para EC2 y EFS"
  type        = string
}

variable "key_pair_name" {
  description = "Nombre del key pair para SSH"
  type        = string
}

variable "allowed_ssh_cidr" {
  description = "CIDR permitido para SSH"
  type        = string
  default     = "0.0.0.0/0"
}

variable "instance_type" {
  description = "Tipo de instancia EC2"
  type        = string
  default     = "t3.medium"
}

variable "project_name" {
  description = "Nombre del proyecto para tagging"
  type        = string
  default     = "rds-dumps"
}

variable "oracle_secret_name" {
  description = "Nombre del secret en Secrets Manager para credenciales Oracle"
  type        = string
  default     = ""
}

variable "postgresql_secret_name" {
  description = "Nombre del secret en Secrets Manager para credenciales PostgreSQL"
  type        = string
  default     = ""
}

variable "mysql_secret_name" {
  description = "Nombre del secret en Secrets Manager para credenciales MySQL"
  type        = string
  default     = ""
}

variable "s3_bucket_short_term" {
  description = "Nombre del bucket S3 short-term (override automatico)"
  type        = string
  default     = ""
}

variable "s3_bucket_long_term" {
  description = "Nombre del bucket S3 long-term (override automatico)"
  type        = string
  default     = ""
}
