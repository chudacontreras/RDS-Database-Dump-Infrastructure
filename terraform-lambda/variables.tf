variable "aws_region" {
  description = "Región de AWS"
  type        = string
  default     = "us-east-1"
}

variable "vpc_id" {
  description = "ID de la VPC"
  type        = string
}

variable "subnet_ids" {
  description = "IDs de subnets privadas para Lambda VPC (mínimo 2)"
  type        = list(string)
}

variable "project_name" {
  description = "Nombre del proyecto para tagging"
  type        = string
  default     = "rds-dumps"
}

# ======================== PostgreSQL ========================
variable "pg_enabled" {
  description = "Habilitar dump de PostgreSQL"
  type        = bool
  default     = false
}

variable "pg_db_host" {
  description = "Endpoint de PostgreSQL RDS"
  type        = string
  default     = ""
}

variable "pg_db_port" {
  type    = string
  default = "5432"
}

variable "pg_db_user" {
  type    = string
  default = "admin"
}

variable "pg_db_name" {
  type    = string
  default = "mydb"
}

variable "pg_secret_arn" {
  description = "ARN del secreto en Secrets Manager con la password de PostgreSQL"
  type        = string
  default     = ""
}

variable "pg_schemas" {
  description = "Schemas a exportar (vacío = full dump)"
  type        = string
  default     = ""
}

# ======================== MySQL ========================
variable "my_enabled" {
  description = "Habilitar dump de MySQL"
  type        = bool
  default     = false
}

variable "my_db_host" {
  type    = string
  default = ""
}

variable "my_db_port" {
  type    = string
  default = "3306"
}

variable "my_db_user" {
  type    = string
  default = "admin"
}

variable "my_db_name" {
  type    = string
  default = "mydb"
}

variable "my_secret_arn" {
  type    = string
  default = ""
}

# ======================== Oracle ========================
variable "ora_enabled" {
  description = "Habilitar dump de Oracle"
  type        = bool
  default     = false
}

variable "ora_db_host" {
  type    = string
  default = ""
}

variable "ora_db_port" {
  type    = string
  default = "1521"
}

variable "ora_db_user" {
  type    = string
  default = "admin"
}

variable "ora_db_service" {
  type    = string
  default = "ORCL"
}

variable "ora_secret_arn" {
  type    = string
  default = ""
}

variable "ora_schemas" {
  type    = string
  default = ""
}

variable "ora_image_uri" {
  description = "URI de la imagen ECR para Lambda Oracle (account.dkr.ecr.region.amazonaws.com/repo:tag)"
  type        = string
  default     = ""
}
