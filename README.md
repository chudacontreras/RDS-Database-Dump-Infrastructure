# RDS Database Dump Infrastructure

Infraestructura para realizar dumps de bases de datos RDS (Oracle, PostgreSQL, MySQL) con almacenamiento en S3 y transición a Glacier.

Dos soluciones disponibles:
- **EC2 Bastion** — instancia dedicada con crontab (solución original)
- **Lambda Serverless** — funciones Lambda con EventBridge (sin servidores)

## Estructura

```
├── cloudformation/
│   ├── template.yaml              # Solución EC2
│   └── template-lambda.yaml       # Solución Lambda
├── terraform/                     # Solución EC2 (Terraform)
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── user_data.sh.tpl
│   └── terraform.tfvars.example
├── terraform-lambda/              # Solución Lambda (Terraform)
│   ├── main.tf
│   ├── eventbridge.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars.example
├── lambda/                        # Código de las funciones Lambda
│   ├── postgresql/handler.py
│   ├── mysql/handler.py
│   └── oracle/
│       ├── handler.py
│       └── Dockerfile             # Container image (Oracle Instant Client)
├── scripts/                       # Scripts bash para la solución EC2
│   ├── monthly/
│   │   ├── dump_oracle_monthly.sh
│   │   ├── dump_postgresql_monthly.sh
│   │   └── dump_mysql_monthly.sh
│   └── yearly/
│       ├── dump_oracle_yearly.sh
│       ├── dump_postgresql_yearly.sh
│       └── dump_mysql_yearly.sh
└── README.md
```

---

## Comparativa: EC2 vs Lambda

| Aspecto | EC2 Bastion | Lambda Serverless |
|---------|-------------|-------------------|
| Costo mensual | ~$30-60 (t3.medium 24/7) | ~$0.01-0.50 (pago por ejecución) |
| Timeout | Sin límite | 15 minutos máximo |
| Almacenamiento temporal | 50GB EBS + EFS ilimitado | 10GB `/tmp` efímero |
| Scheduling | Crontab | EventBridge (nativo) |
| Oracle Instant Client | Instalado vía dnf | Container image Lambda (Dockerfile) |
| PostgreSQL / MySQL | Clientes nativos | Lambda Layer con binarios compilados |
| Mantenimiento | Parches OS, actualizaciones | Sin mantenimiento de infra |
| Networking | Security Group directo | VPC config + NAT Gateway necesario |
| Credenciales DB | En scripts (o SSM Parameter) | Secrets Manager (integrado) |
| Observabilidad | Logs en EFS + CloudWatch | CloudWatch Logs nativo |
| Complejidad de deploy | Baja | Media (Layers/Container image) |

### ¿Cuándo elegir cada una?

**EC2 Bastion** si:
- Los dumps son grandes (>10GB comprimidos) o tardan >15 minutos
- Necesitas acceso interactivo a las bases (troubleshooting, queries ad-hoc)
- Prefieres simplicidad operativa con scripts bash

**Lambda Serverless** si:
- Los dumps son moderados (<10GB) y completan en <15 minutos
- Quieres minimizar costos (la EC2 corre 24/7 pero solo trabaja unas horas al mes)
- Prefieres infraestructura sin mantenimiento de OS

---

## Solución 1: EC2 Bastion

### Componentes

| Recurso | Descripción |
|---------|-------------|
| S3 Long-Term | Transición a Glacier a 30 días, expiración a 8 años |
| S3 Short-Term | Transición a Glacier a 30 días, expiración a 1 año |
| EC2 Bastion | Amazon Linux 2023 con clientes Oracle, PostgreSQL, MySQL y SSM Agent |
| EFS | Montado en `/backups` para almacenamiento temporal de dumps |
| IAM Role | Mínimo privilegio: PutObject a S3 + AmazonSSMManagedInstanceCore |

### Crontabs

| Frecuencia | Día | Hora | Bucket destino |
|------------|-----|------|----------------|
| Mensual | 5 de cada mes | 02:00-03:00 | short-term (1 año) |
| Anual | 10 de enero | 02:00-03:00 | long-term (8 años) |

### Despliegue EC2

#### CloudFormation
```bash
aws cloudformation deploy \
  --template-file cloudformation/template.yaml \
  --stack-name rds-dumps \
  --parameter-overrides VpcId=vpc-xxx SubnetId=subnet-xxx KeyPairName=my-key AllowedSshCidr=10.0.0.0/8 \
  --capabilities CAPABILITY_NAMED_IAM
```

#### Terraform
```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Editar terraform.tfvars con valores reales
terraform init && terraform plan && terraform apply
```

### Post-despliegue EC2

1. Copiar los scripts a la instancia EC2 en `/opt/scripts/monthly/` y `/opt/scripts/yearly/`
2. Editar la sección `CONFIGURACION` de cada script con los datos de conexión reales
3. Dar permisos de ejecución: `chmod +x /opt/scripts/{monthly,yearly}/*.sh`
4. Los crontabs ya están configurados por el user data

---

## Solución 2: Lambda Serverless

### Componentes

| Recurso | Descripción |
|---------|-------------|
| S3 Long-Term | Transición a Glacier a 30 días, expiración a 8 años |
| S3 Short-Term | Transición a Glacier a 30 días, expiración a 1 año |
| Lambda PostgreSQL | Python 3.12 + Layer con pg_dump |
| Lambda MySQL | Python 3.12 + Layer con mysqldump |
| Lambda Oracle | Container image con Oracle Instant Client |
| EventBridge Rules | Schedules mensuales y anuales (reemplazan crontab) |
| Secrets Manager | Almacena passwords de las bases de datos |
| IAM Role | Mínimo privilegio: S3 PutObject + Secrets Manager GetSecretValue |

### Schedules EventBridge

| Frecuencia | Motor | Expresión cron | Bucket destino |
|------------|-------|----------------|----------------|
| Mensual | PostgreSQL | `cron(0 2 5 * ? *)` | short-term |
| Mensual | MySQL | `cron(30 2 5 * ? *)` | short-term |
| Mensual | Oracle | `cron(0 3 5 * ? *)` | short-term |
| Anual | PostgreSQL | `cron(0 2 10 1 ? *)` | long-term |
| Anual | MySQL | `cron(30 2 10 1 ? *)` | long-term |
| Anual | Oracle | `cron(0 3 10 1 ? *)` | long-term |

### Pre-requisitos Lambda

1. **Secrets Manager**: Crear secretos con las passwords de cada base de datos
2. **Lambda Layers** (PostgreSQL/MySQL): Compilar `pg_dump` y `mysqldump` como binarios estáticos para Amazon Linux 2023 y empaquetarlos como Layer
3. **Container Image Oracle**: Construir y subir a ECR la imagen del Dockerfile

#### Construir imagen Oracle para ECR
```bash
# Crear repositorio ECR
aws ecr create-repository --repository-name rds-dumps-oracle

# Login, build y push
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 123456789012.dkr.ecr.us-east-1.amazonaws.com
cd lambda/oracle
docker build -t rds-dumps-oracle .
docker tag rds-dumps-oracle:latest 123456789012.dkr.ecr.us-east-1.amazonaws.com/rds-dumps-oracle:latest
docker push 123456789012.dkr.ecr.us-east-1.amazonaws.com/rds-dumps-oracle:latest
```

### Despliegue Lambda

#### CloudFormation
```bash
aws cloudformation deploy \
  --template-file cloudformation/template-lambda.yaml \
  --stack-name rds-dumps-lambda \
  --parameter-overrides \
    VpcId=vpc-xxx \
    SubnetIds=subnet-aaa,subnet-bbb \
    RdsSecurityGroupId=sg-xxx \
    PgDbHost=mydb.xxx.rds.amazonaws.com \
    PgSecretArn=arn:aws:secretsmanager:... \
    OracleImageUri=123456789012.dkr.ecr.us-east-1.amazonaws.com/rds-dumps-oracle:latest \
  --capabilities CAPABILITY_NAMED_IAM
```

#### Terraform
```bash
cd terraform-lambda
cp terraform.tfvars.example terraform.tfvars
# Editar terraform.tfvars con valores reales
terraform init && terraform plan && terraform apply
```

### Nota sobre NAT Gateway

Las Lambdas en VPC necesitan un NAT Gateway para acceder a servicios AWS (S3, Secrets Manager, CloudWatch). Si tu VPC ya tiene NAT Gateway configurado, no necesitas cambios adicionales. Si no, considera usar VPC Endpoints para S3 y Secrets Manager como alternativa más económica.
