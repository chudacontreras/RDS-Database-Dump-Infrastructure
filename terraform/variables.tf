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
