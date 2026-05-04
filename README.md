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

Una vez desplegada la infraestructura, conectarse a la instancia via SSM o SSH y ejecutar los siguientes pasos:

#### Paso 1: Crear directorio y montar EFS en /backups

```bash
# Crear punto de montaje
sudo mkdir -p /backups

# Agregar entrada en fstab (reemplazar EFS_ID y REGION con valores reales del output del stack)
sudo bash -c 'echo "fs-XXXXXXXX.efs.us-east-1.amazonaws.com:/ /backups efs _netdev,tls 0 0" >> /etc/fstab'

# Montar
sudo mount -a

# Si mount -a falla, intentar montaje directo:
sudo mount -t efs -o tls fs-XXXXXXXX:/ /backups

# Verificar que esta montado
df -h /backups
```

#### Paso 2: Crear directorios de trabajo

```bash
# Directorios para backups en EFS
sudo mkdir -p /backups/oracle/monthly /backups/oracle/yearly /backups/oracle/logs
sudo mkdir -p /backups/postgresql/monthly /backups/postgresql/yearly /backups/postgresql/logs
sudo mkdir -p /backups/mysql/monthly /backups/mysql/yearly /backups/mysql/logs

# Directorios para los scripts
sudo mkdir -p /opt/scripts/monthly /opt/scripts/yearly
```

#### Paso 3: Copiar scripts a la instancia

```bash
# Opcion A: Desde tu maquina local via SCP
scp scripts/monthly/*.sh ec2-user@<IP>:/tmp/
scp scripts/yearly/*.sh ec2-user@<IP>:/tmp/
# Luego en la EC2:
sudo mv /tmp/dump_*_monthly.sh /opt/scripts/monthly/
sudo mv /tmp/dump_*_yearly.sh /opt/scripts/yearly/

# Opcion B: Desde la EC2 via git clone o S3
# aws s3 cp s3://mi-bucket/scripts/ /opt/scripts/ --recursive

# Dar permisos de ejecucion
sudo chmod +x /opt/scripts/monthly/*.sh
sudo chmod +x /opt/scripts/yearly/*.sh
```

#### Paso 4: Editar la política de Secrets Manager del IAM Role

La política desplegada por defecto permite acceso a **todos** los secrets de la cuenta (`secret:*`).
Se debe restringir al ARN específico del secret que usa cada cuenta/ambiente.

**ARN genérico de un secret:**
```
arn:aws:secretsmanager:<REGION>:<ACCOUNT_ID>:secret:<NOMBRE>/<AMBIENTE>/<SECRETO>-<SUFIJO_6_CHARS>
```

**Ejemplo real:**
```
arn:aws:secretsmanager:us-east-1:123456789012:secret:postgresAurora/qa/rds-credentials-oVWs0C
```

> **Nota:** Secrets Manager agrega un sufijo aleatorio de 6 caracteres al ARN del secret. Puedes obtener el ARN completo con:
> ```bash
> aws secretsmanager describe-secret --secret-id nombre/ambiente/secreto --query 'ARN' --output text
> ```

**Editar la política del role:**

```bash
aws iam put-role-policy \
  --role-name <NOMBRE_DEL_ROLE> \
  --policy-name SecretsManagerReadPolicy \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Sid": "AllowReadSecrets",
        "Effect": "Allow",
        "Action": [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ],
        "Resource": [
          "arn:aws:secretsmanager:us-east-1:<ACCOUNT_ID>:secret:nombre/ambiente/secreto-XXXXXX"
        ]
      }
    ]
  }'
```

Reemplazar:
- `<NOMBRE_DEL_ROLE>` — nombre del IAM Role del bastion (ej: `bbpa-rds-backups-bastion-role`)
- `<ACCOUNT_ID>` — ID de la cuenta AWS (ej: `123456789012`)
- `nombre/ambiente/secreto-XXXXXX` — ARN completo del secret incluyendo el sufijo

Si se necesitan múltiples secrets (Oracle, PostgreSQL, MySQL), agregar cada ARN al array de `Resource`:
```json
"Resource": [
  "arn:aws:secretsmanager:us-east-1:123456789012:secret:postgresAurora/prod/rds-creds-AbCdEf",
  "arn:aws:secretsmanager:us-east-1:123456789012:secret:oracle/prod/rds-creds-GhIjKl",
  "arn:aws:secretsmanager:us-east-1:123456789012:secret:mysql/prod/rds-creds-MnOpQr"
]
```

#### Paso 5: Editar los scripts de backup

Cada script tiene una sección de configuración al inicio. Editar los siguientes valores:

```bash
sudo vi /opt/scripts/monthly/dump_postgresql_monthly.sh
```

**Variables a modificar (OPCION 1 — Secrets Manager):**

| Variable | Descripción | Ejemplo |
|----------|-------------|---------|
| `SECRET_NAME` | Nombre del secret en Secrets Manager | `postgresAurora/qa/rds-credentials` |
| `AWS_REGION` | Región donde está el secret | `us-east-1` |
| `S3_BUCKET` | Nombre del bucket S3 destino | `mi-proyecto-dumps-short-term-123456789012` |
| `SCHEMAS` | Schemas a exportar (vacío = todos) | `public,app` |

**Variables a modificar (OPCION 2 — Credenciales hardcodeadas):**

Comentar el bloque OPCION 1 y descomentar OPCION 2, luego editar:

| Variable | Descripción | Ejemplo |
|----------|-------------|---------|
| `DB_HOST` | Endpoint RDS | `mydb.cluster-xxx.us-east-1.rds.amazonaws.com` |
| `DB_PORT` | Puerto | `5432` |
| `DB_USER` | Usuario | `admin` |
| `DB_PASS` | Password | `mi-password-seguro` |
| `DB_NAME` | Base de datos | `mydb` |
| `S3_BUCKET` | Bucket S3 destino | `mi-proyecto-dumps-short-term-123456789012` |

Repetir para cada script que se vaya a usar (monthly y yearly).

#### Paso 6: Habilitar servicio cron

```bash
sudo systemctl enable crond
sudo systemctl start crond
sudo systemctl status crond
```

#### Paso 7: Configurar crontabs

```bash
# Crontab mensual - dia 5 de cada mes a las 02:00
sudo tee /etc/cron.d/dump-monthly > /dev/null <<'CRON'
# Dump mensual - dia 5 de cada mes a las 02:00 -> bucket short-term (1 anio)
0 2 5 * * root /opt/scripts/monthly/dump_oracle_monthly.sh >> /backups/oracle/logs/cron_monthly.log 2>&1
30 2 5 * * root /opt/scripts/monthly/dump_postgresql_monthly.sh >> /backups/postgresql/logs/cron_monthly.log 2>&1
0 3 5 * * root /opt/scripts/monthly/dump_mysql_monthly.sh >> /backups/mysql/logs/cron_monthly.log 2>&1
CRON

# Crontab anual - dia 10 de enero a las 02:00
sudo tee /etc/cron.d/dump-yearly > /dev/null <<'CRON'
# Dump anual - dia 10 de enero a las 02:00 -> bucket long-term (8 anios)
0 2 10 1 * root /opt/scripts/yearly/dump_oracle_yearly.sh >> /backups/oracle/logs/cron_yearly.log 2>&1
30 2 10 1 * root /opt/scripts/yearly/dump_postgresql_yearly.sh >> /backups/postgresql/logs/cron_yearly.log 2>&1
0 3 10 1 * root /opt/scripts/yearly/dump_mysql_yearly.sh >> /backups/mysql/logs/cron_yearly.log 2>&1
CRON

# Permisos correctos (cron requiere 644 y owner root)
sudo chmod 644 /etc/cron.d/dump-monthly /etc/cron.d/dump-yearly
sudo chown root:root /etc/cron.d/dump-monthly /etc/cron.d/dump-yearly

# Reiniciar crond
sudo systemctl restart crond
```

> **Nota:** Comentar con `#` las líneas de los motores que no se usen en esa cuenta.

#### Paso 8: Test del cron

Para verificar que el cron ejecuta correctamente sin esperar al día programado:

```bash
# Crear un cron de prueba que ejecute cada minuto
sudo tee /etc/cron.d/dump-test > /dev/null <<'CRON'
* * * * * root /opt/scripts/monthly/dump_postgresql_monthly.sh >> /backups/postgresql/logs/cron_test.log 2>&1
CRON
sudo chmod 644 /etc/cron.d/dump-test
sudo chown root:root /etc/cron.d/dump-test

# Esperar 2 minutos y verificar que se ejecuto
sleep 120
cat /backups/postgresql/logs/cron_test.log

# Verificar en los logs del sistema
sudo grep -i cron /var/log/messages | tail -10

# IMPORTANTE: Eliminar el cron de prueba cuando termine el test
sudo rm -f /etc/cron.d/dump-test
```

Si el test falla, verificar:
```bash
# Crond esta corriendo?
sudo systemctl status crond

# Permisos del archivo cron?
ls -la /etc/cron.d/dump-test

# El script tiene permisos de ejecucion?
ls -la /opt/scripts/monthly/dump_postgresql_monthly.sh

# Ver errores en logs del sistema
sudo journalctl -u crond --since "5 minutes ago"
```

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
