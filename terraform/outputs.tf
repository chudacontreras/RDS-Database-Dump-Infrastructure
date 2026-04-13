output "bastion_instance_id" {
  description = "ID de la instancia bastion"
  value       = aws_instance.bastion.id
}

output "bastion_private_ip" {
  description = "IP privada de la instancia bastion"
  value       = aws_instance.bastion.private_ip
}

output "s3_bucket_long_term" {
  description = "Nombre del bucket S3 de retencion 8 anios"
  value       = aws_s3_bucket.long_term.id
}

output "s3_bucket_short_term" {
  description = "Nombre del bucket S3 de retencion 1 anio"
  value       = aws_s3_bucket.short_term.id
}

output "efs_file_system_id" {
  description = "ID del sistema de archivos EFS"
  value       = aws_efs_file_system.dumps.id
}

output "bastion_security_group_id" {
  description = "ID del security group del bastion"
  value       = aws_security_group.bastion.id
}
