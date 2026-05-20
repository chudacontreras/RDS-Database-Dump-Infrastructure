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
│   ├── setup_oracle_s3_integration.sh  # Setup integración S3 ↔ Oracle RDS
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
| `SSL_MODE` | Modo SSL para la conexión (ver sección [Configuración SSL/TLS](#configuración-ssltls-para-conexiones-a-rds)) | PostgreSQL: `require` <br>MySQL: `REQUIRED` <br>Oracle: `disable` o `require` |

> **⚠️ IMPORTANTE — Secrets gestionados por AWS RDS:**
>
> Los secrets que AWS RDS crea automáticamente (los que aparecen como `rds!db-XXXX` o cuando habilitas "Manage credentials in AWS Secrets Manager" al crear la RDS) **NO incluyen el campo `dbname`**. Solo contienen: `username`, `password`, `host`, `port`, `engine`, `dbInstanceIdentifier`.
>
> Si tu secret no tiene `dbname`, tienes 3 opciones:
>
> **a) Pasar el nombre como variable de entorno (más rápido):**
> ```bash
> # PostgreSQL / MySQL
> DB_NAME=mydb /opt/scripts/monthly/dump_postgresql_monthly.sh
>
> # Oracle (usa DB_SERVICE)
> DB_SERVICE=ORCL /opt/scripts/monthly/dump_oracle_monthly.sh
>
> # MySQL — todas las bases
> DB_NAME=ALL /opt/scripts/monthly/dump_mysql_monthly.sh
> ```
>
> **b) Editar el secret y agregar `dbname` al JSON:**
> ```json
> {
>   "username": "admin",
>   "password": "...",
>   "host": "...",
>   "port": 5432,
>   "dbname": "mydb"
> }
> ```
>
> **c) En el crontab, exportar la variable antes del script:**
> ```cron
> 0 2 5 * * root DB_NAME=mydb /opt/scripts/monthly/dump_postgresql_monthly.sh >> /backups/postgresql/logs/cron_monthly.log 2>&1
> ```

**Variables a modificar (OPCION 2 — Credenciales hardcodeadas):**

Comentar el bloque OPCION 1 y descomentar OPCION 2, luego editar:

| Variable | Descripción | Ejemplo |
|----------|-------------|---------|
| `DB_HOST` | Endpoint RDS | `mydb.cluster-xxx.us-east-1.rds.amazonaws.com` |
| `DB_PORT` | Puerto | `5432` |
| `DB_USER` | Usuario | `admin` |
| `DB_PASS` | Password (usar comillas simples si tiene caracteres especiales) | `'mi-password-seguro'` |
| `DB_NAME` (PostgreSQL/MySQL) <br> `DB_SERVICE` (Oracle) | Base de datos / Service Name | `mydb` / `ORCL` |
| `S3_BUCKET` | Bucket S3 destino | `mi-proyecto-dumps-short-term-123456789012` |
| `SSL_MODE` | Modo SSL (ver sección SSL más abajo) | `require` / `REQUIRED` / `disable` |

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

---

## Prerequisito: Integración S3 para Oracle RDS (Data Pump)

Los scripts de dump de Oracle (`dump_oracle_monthly.sh`, `dump_oracle_yearly.sh`) usan **DBMS_DATAPUMP** para generar el export directamente en la instancia RDS y luego transferirlo a S3 usando `rdsadmin.rdsadmin_s3_tasks.upload_to_s3`. Esto requiere configurar la integración S3 en la instancia RDS Oracle.

> **Esta configuración NO requiere reinicio de la instancia RDS.** La opción `S3_INTEGRATION` es non-persistent y se aplica en caliente.

### Configuración automática

```bash
# Editar las variables al inicio del script
vi scripts/setup_oracle_s3_integration.sh

# Ejecutar
export AWS_ACCOUNT_ID="000999883737"
export AWS_REGION="us-east-1"
export RDS_INSTANCE_ID="mi-instancia-oracle"
export OPTION_GROUP_NAME="mi-option-group-custom"
export S3_BUCKET_SHORT_TERM="mi-proyecto-dumps-short-term-000999883737"
export S3_BUCKET_LONG_TERM="mi-proyecto-dumps-long-term-000999883737"

chmod +x scripts/setup_oracle_s3_integration.sh
./scripts/setup_oracle_s3_integration.sh
```

### Configuración manual (paso a paso)

#### 1. Crear política IAM con acceso a los buckets S3

```bash
aws iam create-policy \
  --policy-name rds-oracle-s3-integration-policy \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": [
          "s3:GetObject",
          "s3:ListBucket",
          "s3:PutObject",
          "s3:DeleteObject"
        ],
        "Resource": [
          "arn:aws:s3:::mi-bucket-dumps-short-term",
          "arn:aws:s3:::mi-bucket-dumps-short-term/*",
          "arn:aws:s3:::mi-bucket-dumps-long-term",
          "arn:aws:s3:::mi-bucket-dumps-long-term/*"
        ]
      }
    ]
  }'
```

#### 2. Crear IAM Role con trust policy para RDS

```bash
aws iam create-role \
  --role-name rds-oracle-s3-integration-role \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": {
          "Service": "rds.amazonaws.com"
        },
        "Action": "sts:AssumeRole",
        "Condition": {
          "StringEquals": {
            "aws:SourceAccount": "000999883737"
          }
        }
      }
    ]
  }'
```

#### 3. Asociar la política al role

```bash
aws iam attach-role-policy \
  --role-name rds-oracle-s3-integration-role \
  --policy-arn arn:aws:iam::000999883737:policy/rds-oracle-s3-integration-policy
```

#### 4. Agregar S3_INTEGRATION al Option Group

```bash
aws rds add-option-to-option-group \
  --option-group-name MI-OPTION-GROUP-CUSTOM \
  --options OptionName=S3_INTEGRATION,OptionVersion=1.0
```

#### 5. Asociar el role a la instancia RDS

```bash
aws rds add-role-to-db-instance \
  --db-instance-identifier mi-instancia-oracle \
  --feature-name S3_INTEGRATION \
  --role-arn arn:aws:iam::000999883737:role/rds-oracle-s3-integration-role
```

#### 6. Verificar que el role está activo

```bash
aws rds describe-db-instances \
  --db-instance-identifier mi-instancia-oracle \
  --query 'DBInstances[0].AssociatedRoles'
```

Resultado esperado:
```json
[
  {
    "RoleArn": "arn:aws:iam::000999883737:role/rds-oracle-s3-integration-role",
    "FeatureName": "S3_INTEGRATION",
    "Status": "ACTIVE"
  }
]
```

#### 7. Verificar desde SQL*Plus

```sql
-- Listar archivos en DATA_PUMP_DIR
SELECT * FROM TABLE(rdsadmin.rds_file_util.listdir('DATA_PUMP_DIR'));

-- Test de upload a S3 (sube todos los archivos del directorio)
SELECT rdsadmin.rdsadmin_s3_tasks.upload_to_s3(
  p_bucket_name    => 'mi-bucket-dumps-short-term',
  p_prefix         => 'test/',
  p_directory_name => 'DATA_PUMP_DIR'
) AS task_id FROM DUAL;

-- Verificar el estado del task
SELECT text FROM TABLE(rdsadmin.rds_file_util.read_text_file('BDUMP', 'dbtask-<task_id>.log'));
```

### Referencia

- [Documentación oficial: Amazon S3 integration for Oracle RDS](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/oracle-s3-integration.html)
- [Troubleshooting S3 integration](https://repost.aws/knowledge-center/rds-oracle-s3-integration)

---

---

## Backup completo de TODAS las bases de la instancia RDS

Para garantizar que se respaldan **todas las bases de datos** de una instancia RDS (no solo una), use el modo `ALL` que está disponible en los 3 motores. Esto es especialmente útil cuando los secrets de AWS RDS no incluyen el campo `dbname`, o cuando la instancia tiene múltiples bases.

### Comportamiento por motor

| Motor | Variable | Modo `ALL` | Resultado |
|-------|----------|-----------|-----------|
| **PostgreSQL** | `DB_NAME=ALL` | Descubre todas las bases con `pg_database` y dumpea cada una con `pg_dump` | Un archivo `.sql.gz` **por cada base** en `s3://bucket/postgresql/<dbname>/...` |
| **MySQL** | `DB_NAME=ALL` | Usa `mysqldump --all-databases` (nativo) | **Un solo archivo** `.sql.gz` con todas las bases en `s3://bucket/mysql/ALL/...` |
| **Oracle** | `SCHEMAS=ALL` | Descubre todos los schemas no-system con `dba_users` y los exporta con Data Pump | Un archivo `.dmp` con todos los schemas en `s3://bucket/oracle/<service>/...` |

### Bases/schemas excluidos automáticamente

| Motor | Excluidos |
|-------|-----------|
| PostgreSQL | `template0`, `template1`, `rdsadmin`, plantillas (`datistemplate=true`), bases sin conexión (`datallowconn=false`) |
| MySQL | El backup nativo `--all-databases` ya excluye `information_schema`, `performance_schema`, `mysql.sys` cuando se restaura |
| Oracle | Schemas Oracle-maintained (`SYS`, `SYSTEM`, `RDSADMIN`, `OUTLN`, `DBSNMP`, etc.) — usa `oracle_maintained='N'` en `dba_users` |

### Privilegios necesarios para modo ALL

| Motor | Privilegios mínimos |
|-------|---------------------|
| PostgreSQL | `CONNECT` en cada base + permisos para `SELECT` en `pg_database` (admin/master user lo tiene por default) |
| MySQL | `SELECT, LOCK TABLES, SHOW VIEW, EVENT, TRIGGER` sobre `*.*` (admin/master user lo tiene) |
| Oracle | `SELECT_CATALOG_ROLE` (para `dba_users`) + `EXP_FULL_DATABASE` o `DATAPUMP_EXP_FULL_DATABASE` |

Si el usuario admin no tiene `SELECT_CATALOG_ROLE`, ejecutar como SYS:

```sql
GRANT SELECT_CATALOG_ROLE TO admin;
```

### Ejemplos de uso

```bash
# Respaldar TODAS las bases - PostgreSQL
DB_NAME=ALL ./dump_postgresql_monthly.sh

# Respaldar TODAS las bases - MySQL
DB_NAME=ALL ./dump_mysql_monthly.sh

# Respaldar TODOS los schemas - Oracle
SCHEMAS=ALL ./dump_oracle_monthly.sh
```

En el crontab, exportar antes del comando:

```cron
0 2 5 * * root DB_NAME=ALL /opt/scripts/monthly/dump_postgresql_monthly.sh >> /backups/postgresql/logs/cron_monthly.log 2>&1
30 2 5 * * root DB_NAME=ALL /opt/scripts/monthly/dump_mysql_monthly.sh >> /backups/mysql/logs/cron_monthly.log 2>&1
0 3 5 * * root SCHEMAS=ALL /opt/scripts/monthly/dump_oracle_monthly.sh >> /backups/oracle/logs/cron_monthly.log 2>&1
```

### Validación post-backup

Después de ejecutar el dump en modo ALL, los scripts de PostgreSQL imprimen un resumen al final del log:

```
==========================================
RESUMEN
  Total bases procesadas: 5
  Exitosas: 5
  Fallidas: 0
==========================================
```

Si alguna base falló, el script termina con código de salida `1` y lista las bases problemáticas.

Para verificar manualmente desde S3:

```bash
# PostgreSQL: cada base tiene su propio prefix
aws s3 ls s3://mi-bucket-dumps-short-term/postgresql/ --recursive | grep "$(date +%Y%m%d)"

# MySQL: archivo único con todas las bases
aws s3 ls s3://mi-bucket-dumps-short-term/mysql/ALL/

# Oracle: archivo único con todos los schemas
aws s3 ls s3://mi-bucket-dumps-short-term/oracle/
```

### Comparación con bases individuales

| Aspecto | `DB_NAME=ALL` | `DB_NAME=mydb` |
|---------|--------------|----------------|
| Archivos S3 (PostgreSQL) | Uno por base | Solo uno |
| Archivos S3 (MySQL) | Un solo archivo con todo | Un archivo con esa base |
| Archivos S3 (Oracle) | Un dump con todos los schemas | Un dump con los schemas indicados |
| Tiempo de ejecución | Mayor (proporcional al # de bases) | Menor |
| Garantía de cobertura | ✅ Total | ⚠️ Solo lo configurado |
| Recomendado para | Producción / compliance | Bases específicas críticas |

---

## Configuración SSL/TLS para conexiones a RDS

Todos los scripts de dump soportan conexiones con y sin SSL. La variable `SSL_MODE` controla el comportamiento.

### Cómo saber si tu RDS requiere SSL

| Motor | Cómo verificarlo |
|-------|------------------|
| PostgreSQL | Console RDS → Parameter Group → buscar `rds.force_ssl`. Si está en `1`, SSL es **obligatorio**. <br>O ejecutar: `SHOW rds.force_ssl;` |
| MySQL | Console RDS → Parameter Group → buscar `require_secure_transport`. Si está en `1`, SSL es **obligatorio**. <br>O ejecutar: `SHOW VARIABLES LIKE 'require_secure_transport';` |
| Oracle | Console RDS → Configuration → Option Group. Si tiene la opción `SSL` agregada, SSL está habilitado. |

### Modos SSL disponibles por motor

#### PostgreSQL (`SSL_MODE`)

| Modo | Descripción | Cuándo usar |
|------|-------------|-------------|
| `disable` | Sin SSL | Solo si la RDS NO tiene `rds.force_ssl=1` |
| `require` | SSL obligatorio sin validar certificado | **Default**, recomendado para la mayoría de casos |
| `verify-ca` | SSL + valida que el CA sea válido | Más seguro, requiere CA bundle |
| `verify-full` | SSL + valida CA + valida hostname | Máxima seguridad, recomendado para **producción** |

#### MySQL (`SSL_MODE`)

| Modo | Descripción | Cuándo usar |
|------|-------------|-------------|
| `DISABLED` | Sin SSL | Solo si la RDS no requiere SSL |
| `PREFERRED` | Usa SSL si está disponible | Default de MySQL 8 |
| `REQUIRED` | SSL obligatorio sin validar certificado | **Default**, recomendado para la mayoría |
| `VERIFY_CA` | SSL + valida CA | Más seguro |
| `VERIFY_IDENTITY` | SSL + valida CA + valida hostname | Máxima seguridad, recomendado para **producción** |

#### Oracle (`SSL_MODE`)

| Modo | Protocolo TNS | Cuándo usar |
|------|---------------|-------------|
| `disable` | `TCP` | Default. Si tu RDS Oracle NO tiene Option Group con SSL |
| `require` | `TCPS` | Si tu RDS Oracle tiene Option Group con SSL agregado |

### Ejemplos de uso

#### Caso 1: RDS sin SSL (entornos de desarrollo)

Editar el script y cambiar:

```bash
# PostgreSQL
SSL_MODE="${SSL_MODE:-disable}"

# MySQL
SSL_MODE="${SSL_MODE:-DISABLED}"

# Oracle
SSL_MODE="${SSL_MODE:-disable}"
```

#### Caso 2: RDS con SSL forzado (la mayoría de casos)

No cambiar nada. Los defaults ya son los correctos:

```bash
# PostgreSQL → require
# MySQL      → REQUIRED
# Oracle     → disable (cambiar a "require" si tu Oracle tiene SSL en Option Group)
```

#### Caso 3: Producción con validación estricta de certificado

Editar el script:

```bash
# PostgreSQL
SSL_MODE="verify-full"

# MySQL
SSL_MODE="VERIFY_IDENTITY"

# Oracle
SSL_MODE="require"   # Oracle solo soporta require/disable en estos scripts
```

Cuando uses `verify-ca`/`verify-full` (PostgreSQL) o `VERIFY_CA`/`VERIFY_IDENTITY` (MySQL), el script descargará automáticamente el bundle de certificados oficial de AWS desde:

```
https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
```

y lo guardará en `/etc/ssl/certs/rds-global-bundle.pem`. Esto requiere que el bastion tenga `sudo` y acceso a internet.

#### Caso 4: Override por variable de entorno (sin editar el script)

```bash
# Probar conexión sin SSL temporalmente
SSL_MODE=disable ./dump_postgresql_monthly.sh

# Forzar verificación estricta
SSL_MODE=verify-full ./dump_postgresql_monthly.sh
```

### Verificación rápida de SSL

#### PostgreSQL
```bash
PGPASSWORD='tu-pass' psql \
  "host=tu-rds.amazonaws.com port=5432 dbname=mydb user=admin sslmode=require" \
  -c "SELECT ssl_is_used();"
# Retorna 't' si está usando SSL
```

#### MySQL
```bash
mysql -h tu-rds.amazonaws.com -u admin -p \
  --ssl-mode=REQUIRED \
  -e "SHOW STATUS LIKE 'Ssl_cipher';"
# Si devuelve un cipher, está usando SSL
```

#### Oracle
```bash
sqlplus admin/'pass'@"(DESCRIPTION=(ADDRESS=(PROTOCOL=TCPS)(HOST=tu-rds.amazonaws.com)(PORT=2484))(CONNECT_DATA=(SERVICE_NAME=ORCL)))"
# Si conecta con TCPS, está usando SSL
```

### Troubleshooting SSL

| Error | Causa probable | Solución |
|-------|----------------|----------|
| `SSL connection is required` (PostgreSQL) | RDS tiene `rds.force_ssl=1` y SSL_MODE=disable | Cambiar SSL_MODE a `require` |
| `Connections using insecure transport are prohibited` (MySQL) | RDS tiene `require_secure_transport=1` y SSL_MODE=DISABLED | Cambiar SSL_MODE a `REQUIRED` |
| `ORA-12660: Encryption or crypto-checksumming required` | Oracle requiere SSL (TCPS) | Cambiar SSL_MODE a `require` |
| `server certificate for "X" does not match host name "Y"` | Hostname del certificado no coincide | Usar `verify-ca` en vez de `verify-full`, o usar el endpoint exacto del cluster |
| `SSL error: certificate verify failed` | El CA bundle local está desactualizado | Borrar `/etc/ssl/certs/rds-global-bundle.pem` y re-ejecutar el script |
