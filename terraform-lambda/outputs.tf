output "s3_bucket_long_term" {
  description = "Nombre del bucket S3 de retención 8 años"
  value       = aws_s3_bucket.long_term.id
}

output "s3_bucket_short_term" {
  description = "Nombre del bucket S3 de retención 1 año"
  value       = aws_s3_bucket.short_term.id
}

output "lambda_security_group_id" {
  description = "ID del security group de las Lambdas"
  value       = aws_security_group.lambda.id
}

output "postgresql_function_arn" {
  description = "ARN de la Lambda PostgreSQL"
  value       = var.pg_enabled ? aws_lambda_function.postgresql[0].arn : null
}

output "mysql_function_arn" {
  description = "ARN de la Lambda MySQL"
  value       = var.my_enabled ? aws_lambda_function.mysql[0].arn : null
}

output "oracle_function_arn" {
  description = "ARN de la Lambda Oracle"
  value       = var.ora_enabled ? aws_lambda_function.oracle[0].arn : null
}
