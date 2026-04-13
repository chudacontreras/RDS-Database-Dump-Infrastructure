# RDS Database Dump Infrastructure

Infraestructura para realizar dumps de bases de datos RDS (Oracle, PostgreSQL, MySQL) con almacenamiento en S3 y transición a Glacier.

## Estructura

```
├── cloudformation/
│   └── template.yaml
├── terraform/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── user_data.sh.tpl
│   └── terraform.tfvars.example
├── scripts/
│   ├── monthly/                          # → bucket short-term (1 año)
│   │   ├── dump_oracle_monthly.sh
│   │   ├── dump_postgresql_monthly.sh
│   │   └── dump_mysql_monthly.sh
│   └── yearly/                           # → bucket long-term (8 años)
│       ├── dump_oracle_yearly.sh
│       ├── dump_postgresql_yearly.sh
│       └── dump_mysql_yearly.sh
└── README.md
```

## Componentes

| Recurso | Descripción |
|---------|-------------|
| S3 Long-Term | Transición a Glacier a 30 días, expiración a 8 años |
| S3 Short-Term | Transición a Glacier a 30 días, expiración a 1 año |
| EC2 Bastion | Amazon Linux 2023 con clientes Oracle, PostgreSQL, MySQL y SSM Agent |
| EFS | Montado en `/backups` para almacenamiento temporal de dumps |
| IAM Role | Mínimo privilegio: PutObject a S3 + AmazonSSMManagedInstanceCore |

## Crontabs

| Frecuencia | Día | Hora | Bucket destino |
|------------|-----|------|----------------|
| Mensual | 5 de cada mes | 02:00-03:00 | short-term (1 año) |
| Anual | 10 de enero | 02:00-03:00 | long-term (8 años) |

## Despliegue

### CloudFormation
```bash
aws cloudformation deploy \
  --template-file cloudformation/template.yaml \
  --stack-name rds-dumps \
  --parameter-overrides VpcId=vpc-xxx SubnetId=subnet-xxx KeyPairName=my-key AllowedSshCidr=10.0.0.0/8 \
  --capabilities CAPABILITY_NAMED_IAM
```

### Terraform
```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Editar terraform.tfvars con valores reales
terraform init && terraform plan && terraform apply
```

## Post-despliegue

1. Copiar los scripts a la instancia EC2 en `/opt/scripts/monthly/` y `/opt/scripts/yearly/`
2. Editar la sección `CONFIGURACION` de cada script con los datos de conexión reales
3. Dar permisos de ejecución: `chmod +x /opt/scripts/{monthly,yearly}/*.sh`
4. Los crontabs ya están configurados por el user data
