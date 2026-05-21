# RDS Database Dump Infrastructure

Infraestructura como código (IaC) para realizar **dumps lógicos automatizados** de bases de datos RDS (Oracle, PostgreSQL, MySQL) con almacenamiento en S3, transición a Glacier, retención configurable y notificaciones SNS.

## Tabla de contenidos

- [Visión general](#visión-general)
- [Estructura del proyecto](#estructura-del-proyecto)
- [Comparativa: EC2 vs Lambda](#comparativa-ec2-vs-lambda)
- [Solución 1: EC2 Bastion](#solución-1-ec2-bastion)
- [Solución 2: Lambda Serverless](#solución-2-lambda-serverless)
- [Scripts de validación y auditoría](#scripts-de-validación-y-auditoría-de-rds)
- [Backup completo de TODAS las bases (modo ALL)](#backup-completo-de-todas-las-bases-de-la-instancia-rds)
- [Configuración SSL/TLS](#configuración-ssltls-para-conexiones-a-rds)
- [Integración S3 para Oracle (Data Pump)](#prerequisito-integración-s3-para-oracle-rds-data-pump)
- [Permisos KMS para Secrets Manager](#permisos-kms-para-secrets-manager)
- [Privilegios Oracle requeridos](#privilegios-oracle-requeridos)
- [Notificaciones SNS](#notificaciones-sns)
- [Troubleshooting](#troubleshooting)

---

## Visión general

Este proyecto provee dos arquitecturas alternativas para automatizar dumps de RDS:

- **EC2 Bastion** — instancia EC2 dedicada con clientes nativos (sqlplus, psql, mysqldump) y crontab. Solución tradicional, simple, sin límites de tiempo.
- **Lambda Serverless** — funciones Lambda con EventBridge. Sin infraestructura que mantener, pago por uso, ideal para dumps de hasta 15 minutos.

Ambas soluciones:
- Generan dumps mensuales (retención corta = 1 año) y anuales (retención larga = 8 años)
- Suben los dumps a S3 con transición a Glacier a los 30 días
- Soportan conexiones con/sin SSL (PostgreSQL, MySQL, Oracle TCPS)
- Soportan respaldar todas las bases/schemas de la instancia (modo `ALL`)
- Notifican vía SNS cuando un dump se sube exitosamente a S3

---

## Estructura del proyecto

```
.
├── cloudformation/
│   ├── template.yaml              # Stack EC2 Bastion + S3 + EFS + SNS
│   └── template-lambda.yaml       # Stack Lambda + EventBridge + S3
│
├── terraform/                     # Solución EC2 (Terraform)
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── user_data.sh.tpl
│   └── terraform.tfvars.example
│
├── terraform-lambda/              # Solución Lambda (Terraform)
│   ├── main.tf
│   ├── eventbridge.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars.example
│
├── lambda/                        # Código de las funciones Lambda
│   ├── postgresql/handler.py      # Lambda PostgreSQL (con pg_dump)
│   ├── mysql/handler.py           # Lambda MySQL (con mysqldump)
│   └── oracle/
│       ├── handler.py             # Lambda Oracle (Data Pump via DBMS_DATAPUMP)
│       └── Dockerfile             # Container image con Oracle Instant Client
│
├── scripts/                       # Scripts bash para la solución EC2
│   ├── monthly/                   # Dumps mensuales (cron día 5)
│   │   ├── dump_oracle_monthly.sh
│   │   ├── dump_postgresql_monthly.sh
│   │   └── dump_mysql_monthly.sh
│   │
│   ├── yearly/                    # Dumps anuales (cron 10 de enero)
│   │   ├── dump_oracle_yearly.sh
│   │   ├── dump_postgresql_yearly.sh
│   │   └── dump_mysql_yearly.sh
│   │
│   └── revision/                  # Utilidades de validación y setup
│       ├── conectar_oracle.sh           # Validar privilegios Oracle
│       ├── conectar_postgresql.sh       # Validar privilegios PostgreSQL
│       ├── conectar_mysql.sh            # Validar privilegios MySQL
│       └── setup_oracle_s3_integration.sh  # Setup integración S3 ↔ Oracle RDS
│
├── docs/
│   └── diagrama-secuencia-ec2.md
│
├── .gitignore
└── README.md
```

---

## Comparativa: EC2 vs Lambda

| Aspecto | EC2 Bastion | Lambda Serverless |
|---------|-------------|-------------------|
| **Costo mensual** | ~$30-60 (t3.medium 24/7) | ~$0.01-0.50 (pago por ejecución) |
| **Timeout** | Sin límite | 15 minutos máximo |
| **Almacenamiento temporal** | 50GB EBS + EFS ilimitado | 10GB `/tmp` efímero |
| **Scheduling** | Crontab | EventBridge (nativo AWS) |
| **Oracle Instant Client** | Instalado vía dnf en la EC2 | Container image (Dockerfile) |
| **PostgreSQL / MySQL** | Clientes nativos (postgresql15, mariadb105) | Lambda Layer con binarios compilados |
| **Mantenimiento** | Parches OS, actualizaciones de cliente | Sin mantenimiento de infra |
| **Networking** | Security Group directo | VPC config + NAT Gateway necesario |
| **Credenciales DB** | Secrets Manager o hardcoded en script | Secrets Manager (integrado) |
| **Observabilidad** | Logs en EFS + CloudWatch | CloudWatch Logs nativo |
| **Acceso interactivo** | ✅ SSH/SSM para debugging | ❌ Solo invocaciones |
| **Complejidad de deploy** | Baja | Media (Layers/Container image) |

### ¿Cuándo elegir cada una?

**Elige EC2 Bastion si:**
- Los dumps son grandes (>10 GB comprimidos) o tardan >15 minutos
- Necesitas acceso interactivo a las bases (troubleshooting, queries ad-hoc)
- Prefieres simplicidad operativa con scripts bash
- El cliente quiere tener una "máquina de mantenimiento" reutilizable

**Elige Lambda Serverless si:**
- Los dumps son moderados (<10 GB) y completan en <15 minutos
- Quieres minimizar costos (la EC2 corre 24/7 pero solo trabaja unas horas al mes)
- Prefieres infraestructura sin mantenimiento de OS
- Tienes restricciones de seguridad que prohíben EC2s permanentes

---

## Solución 1: EC2 Bastion

### Componentes

| Recurso | Descripción |
|---------|-------------|
| S3 Long-Term | Bucket con transición a Glacier a 30 días, expiración a 8 años |
| S3 Short-Term | Bucket con transición a Glacier a 30 días, expiración a 1 año |
| EC2 Bastion | Amazon Linux 2023 con clientes Oracle, PostgreSQL, MySQL y SSM Agent |
| EFS | Montado en `/backups` para almacenamiento temporal de dumps |
| IAM Role | Mínimo privilegio: PutObject a S3 + AmazonSSMManagedInstanceCore + Secrets Manager |
| SNS Topic | Notificaciones cuando un dump se sube exitosamente a S3 |
| S3 Event Notifications | Disparan SNS al subirse archivos `.dmp` o `.gz` |

### Schedules de los dumps

| Frecuencia | Día | Hora | Bucket destino |
|------------|-----|------|----------------|
| Mensual | 5 de cada mes | 02:00-03:00 UTC | short-term (1 año) |
| Anual | 10 de enero | 02:00-03:00 UTC | long-term (8 años) |

### Despliegue EC2

#### Opción A: CloudFormation

```bash
aws cloudformation deploy \
  --template-file cloudformation/template.yaml \
  --stack-name rds-dumps \
  --parameter-overrides \
    VpcId=vpc-xxx \
    SubnetId=subnet-xxx \
    KeyPairName=my-key \
    AllowedSshCidr=10.0.0.0/8 \
    NotificationEmail=ops@empresa.com \
  --capabilities CAPABILITY_NAMED_IAM
```

#### Opción B: Terraform

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Editar terraform.tfvars con valores reales
terraform init
terraform plan
terraform apply
```

### Post-despliegue: configuración de la EC2

Una vez desplegada la infraestructura, conéctate a la instancia vía SSM o SSH y ejecuta los siguientes pasos.

#### Paso 1: Montar EFS en `/backups`

```bash
sudo mkdir -p /backups

# Reemplazar EFS_ID con el output del stack (output: EFSFileSystemId)
sudo bash -c 'echo "fs-XXXXXXXX.efs.us-east-1.amazonaws.com:/ /backups efs _netdev,tls 0 0" >> /etc/fstab'
sudo mount -a

# Si mount -a falla, montaje directo:
sudo mount -t efs -o tls fs-XXXXXXXX:/ /backups

# Verificar
df -h /backups
```

#### Paso 2: Crear directorios de trabajo

```bash
sudo mkdir -p /backups/{oracle,postgresql,mysql}/{monthly,yearly,logs}
sudo mkdir -p /opt/scripts/{monthly,yearly,revision}
```

#### Paso 3: Copiar scripts al bastion

```bash
# Desde tu máquina local
scp scripts/monthly/*.sh ec2-user@<IP>:/tmp/
scp scripts/yearly/*.sh ec2-user@<IP>:/tmp/
scp scripts/revision/*.sh ec2-user@<IP>:/tmp/

# En la EC2
sudo mv /tmp/dump_*_monthly.sh /opt/scripts/monthly/
sudo mv /tmp/dump_*_yearly.sh /opt/scripts/yearly/
sudo mv /tmp/conectar_*.sh /opt/scripts/revision/
sudo mv /tmp/setup_oracle_s3_integration.sh /opt/scripts/revision/

sudo chmod +x /opt/scripts/monthly/*.sh /opt/scripts/yearly/*.sh /opt/scripts/revision/*.sh
```

#### Paso 4: Restringir la política de Secrets Manager

La política desplegada por defecto permite acceso a **todos** los secrets de la cuenta (`secret:*`). Es buena práctica restringirla a los secrets específicos:

```bash
aws iam put-role-policy \
  --role-name <NOMBRE_DEL_ROLE> \
  --policy-name SecretsManagerReadPolicy \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Sid": "AllowReadSecrets",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": [
        "arn:aws:secretsmanager:us-east-1:<ACCOUNT_ID>:secret:postgresql/qa/rds-creds-XXXXXX",
        "arn:aws:secretsmanager:us-east-1:<ACCOUNT_ID>:secret:oracle/qa/rds-creds-XXXXXX",
        "arn:aws:secretsmanager:us-east-1:<ACCOUNT_ID>:secret:mysql/qa/rds-creds-XXXXXX"
      ]
    }]
  }'
```

> **Nota:** Secrets Manager agrega un sufijo aleatorio de 6 caracteres al ARN del secret. Obtén el ARN exacto con:
> ```bash
> aws secretsmanager describe-secret --secret-id nombre/secret --query 'ARN' --output text
> ```

Si el secret está cifrado con una **KMS key custom (CMK)**, también necesitas permisos KMS — ver [Permisos KMS para Secrets Manager](#permisos-kms-para-secrets-manager).

#### Paso 5: Configurar los scripts de backup

Cada script tiene una sección de configuración al inicio. Edita los valores según tu ambiente:

```bash
sudo vi /opt/scripts/monthly/dump_postgresql_monthly.sh
```

**Variables principales (Opción 1 — Secrets Manager):**

| Variable | Descripción | Ejemplo |
|----------|-------------|---------|
| `SECRET_NAME` | Nombre del secret | `postgresql/qa/rds-credentials` |
| `AWS_REGION` | Región AWS | `us-east-1` |
| `S3_BUCKET` | Bucket S3 destino | `rds-dumps-short-term-123456789012` |
| `SCHEMAS` | Schemas a exportar (vacío = todos) | `public,app` o `ALL` |
| `SSL_MODE` | Modo SSL (ver [SSL/TLS](#configuración-ssltls-para-conexiones-a-rds)) | PostgreSQL: `require`<br>MySQL: `REQUIRED`<br>Oracle: `disable` |

> **⚠️ IMPORTANTE — Secrets gestionados por AWS RDS:**
>
> Los secrets que AWS RDS crea automáticamente (formato `rds!db-XXXX`, o cuando habilitas "Manage credentials in AWS Secrets Manager" al crear la RDS) **NO incluyen el campo `dbname`**. Solo contienen: `username`, `password`, `host`, `port`, `engine`, `dbInstanceIdentifier`.
>
> Si tu secret no tiene `dbname`, define el nombre por env var (ver el script de PostgreSQL/MySQL admite `DB_NAME=ALL` para todas las bases):
> ```bash
> DB_NAME=mydb ./dump_postgresql_monthly.sh   # PostgreSQL/MySQL
> DB_SERVICE=ORCL ./dump_oracle_monthly.sh    # Oracle
> ```

**Variables principales (Opción 2 — Credenciales hardcoded):**

Comenta el bloque OPCION 1 y descomenta OPCION 2, luego edita:

| Variable | Descripción | Ejemplo |
|----------|-------------|---------|
| `DB_HOST` | Endpoint RDS | `mydb.cluster-xxx.us-east-1.rds.amazonaws.com` |
| `DB_PORT` | Puerto | `5432` / `3306` / `1521` |
| `DB_USER` | Usuario | `admin` |
| `DB_PASS` | Password (comillas simples si tiene caracteres especiales) | `'P@ss!w0rd'` |
| `DB_NAME` (PG/MySQL)<br>`DB_SERVICE` (Oracle) | Nombre de DB / Service Name | `mydb` / `ORCL` |

#### Paso 6: Habilitar cron

```bash
sudo systemctl enable crond
sudo systemctl start crond
sudo systemctl status crond
```

#### Paso 7: Configurar crontabs

```bash
# Crontab mensual - día 5 de cada mes
sudo tee /etc/cron.d/dump-monthly > /dev/null <<'CRON'
0 2 5 * * root /opt/scripts/monthly/dump_oracle_monthly.sh >> /backups/oracle/logs/cron_monthly.log 2>&1
30 2 5 * * root /opt/scripts/monthly/dump_postgresql_monthly.sh >> /backups/postgresql/logs/cron_monthly.log 2>&1
0 3 5 * * root /opt/scripts/monthly/dump_mysql_monthly.sh >> /backups/mysql/logs/cron_monthly.log 2>&1
CRON

# Crontab anual - 10 de enero
sudo tee /etc/cron.d/dump-yearly > /dev/null <<'CRON'
0 2 10 1 * root /opt/scripts/yearly/dump_oracle_yearly.sh >> /backups/oracle/logs/cron_yearly.log 2>&1
30 2 10 1 * root /opt/scripts/yearly/dump_postgresql_yearly.sh >> /backups/postgresql/logs/cron_yearly.log 2>&1
0 3 10 1 * root /opt/scripts/yearly/dump_mysql_yearly.sh >> /backups/mysql/logs/cron_yearly.log 2>&1
CRON

sudo chmod 644 /etc/cron.d/dump-monthly /etc/cron.d/dump-yearly
sudo chown root:root /etc/cron.d/dump-monthly /etc/cron.d/dump-yearly
sudo systemctl restart crond
```

> **Nota:** Comenta con `#` las líneas de los motores que no se usen en esta cuenta.

#### Paso 8: Test del cron (opcional)

```bash
# Cron de prueba que ejecuta cada minuto
sudo tee /etc/cron.d/dump-test > /dev/null <<'CRON'
* * * * * root /opt/scripts/monthly/dump_postgresql_monthly.sh >> /backups/postgresql/logs/cron_test.log 2>&1
CRON
sudo chmod 644 /etc/cron.d/dump-test

sleep 120
cat /backups/postgresql/logs/cron_test.log

# IMPORTANTE: limpiar el cron de prueba
sudo rm -f /etc/cron.d/dump-test
```

---

## Solución 2: Lambda Serverless

### Componentes

| Recurso | Descripción |
|---------|-------------|
| S3 Long-Term / Short-Term | Mismos buckets que solución EC2 |
| Lambda PostgreSQL | Python 3.12 + Layer con `pg_dump` |
| Lambda MySQL | Python 3.12 + Layer con `mysqldump` |
| Lambda Oracle | Container image con Oracle Instant Client |
| EventBridge Rules | Schedules mensuales y anuales (reemplazan crontab) |
| Secrets Manager | Almacena passwords de las bases de datos |
| IAM Role | Mínimo privilegio: S3 PutObject + Secrets Manager GetSecretValue |
| SNS Topic | Notificaciones cuando un dump se sube exitosamente |

### Schedules EventBridge

| Frecuencia | Motor | Expresión cron | Bucket destino |
|------------|-------|----------------|----------------|
| Mensual | PostgreSQL | `cron(0 2 5 * ? *)` | short-term |
| Mensual | MySQL | `cron(30 2 5 * ? *)` | short-term |
| Mensual | Oracle | `cron(0 3 5 * ? *)` | short-term |
| Anual | PostgreSQL | `cron(0 2 10 1 ? *)` | long-term |
| Anual | MySQL | `cron(30 2 10 1 ? *)` | long-term |
| Anual | Oracle | `cron(0 3 10 1 ? *)` | long-term |

### Pre-requisitos

1. **Secrets Manager** — Crear secretos con las credenciales de cada base de datos
2. **Lambda Layers (PostgreSQL/MySQL)** — Compilar `pg_dump` y `mysqldump` como binarios estáticos para Amazon Linux 2023 y empaquetarlos como Layer
3. **Container Image Oracle** — Construir y subir a ECR la imagen del Dockerfile

#### Construir imagen Oracle para ECR

```bash
# Crear repositorio ECR
aws ecr create-repository --repository-name rds-dumps-oracle

# Login, build y push
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin 123456789012.dkr.ecr.us-east-1.amazonaws.com

cd lambda/oracle
docker build -t rds-dumps-oracle .
docker tag rds-dumps-oracle:latest \
  123456789012.dkr.ecr.us-east-1.amazonaws.com/rds-dumps-oracle:latest
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

### Networking en Lambda

Las Lambdas en VPC necesitan acceso a servicios AWS (S3, Secrets Manager, CloudWatch). Opciones:

- **NAT Gateway** — más simple pero costoso (~$32/mes por NAT)
- **VPC Endpoints** — más económico, recomendado para producción:
  - Gateway Endpoint para S3 (gratis)
  - Interface Endpoints para Secrets Manager, KMS, CloudWatch Logs (~$7/mes cada uno)

---

## Scripts de validación y auditoría de RDS

Los scripts en `scripts/revision/` son **utilidades de validación** que se conectan a la RDS y reportan información completa sobre schemas, usuarios, roles, permisos y configuración SSL. Útiles para:

- **Validar privilegios** del usuario antes de configurar el primer dump
- **Auditar** usuarios y roles existentes
- **Diagnosticar** problemas de permisos antes de ejecutar el dump real
- **Generar evidencia** para compartir con el cliente

### Scripts disponibles

| Script | Motor | Reporta |
|--------|-------|---------|
| `conectar_oracle.sh` | Oracle | Schemas, usuarios, roles, privilegios DATAPUMP, integración S3 |
| `conectar_postgresql.sh` | PostgreSQL | Bases, usuarios, roles, privilegios, SSL, extensiones |
| `conectar_mysql.sh` | MySQL | Bases, usuarios, privilegios, SSL, top tablas |
| `setup_oracle_s3_integration.sh` | Oracle | **Setup automático** de IAM Role + Option Group para integración S3 |

### Información reportada por motor

| Sección | Oracle | PostgreSQL | MySQL |
|---------|--------|------------|-------|
| Info de instancia (versión, host, usuario actual) | ✅ | ✅ | ✅ |
| Resumen de schemas/databases | ✅ | ✅ | ✅ |
| Lista detallada con tamaño | ✅ (top 10 objetos) | ✅ (con `pg_database_size`) | ✅ (top 10 tablas) |
| Usuarios y roles del servidor | ✅ | ✅ | ✅ |
| Privilegios del usuario actual | ✅ | ✅ | ✅ |
| Privilegios para dump | ✅ (DATAPUMP_EXP_FULL_DATABASE, etc.) | ✅ (CONNECT, CREATE) | ✅ (SELECT, LOCK TABLES, etc.) |
| Estado SSL | - | ✅ (`rds.force_ssl`) | ✅ (`require_secure_transport`) |
| Integración S3 | ✅ (verifica `rdsadmin_s3_tasks`) | - | - |
| Extensiones / paquetes | - | ✅ (`pg_extension`) | - |

### Uso

```bash
# Ejecutar con secret default del script
./scripts/revision/conectar_postgresql.sh

# Pasar nombre del secret como argumento
./scripts/revision/conectar_oracle.sh USR_BACKUP_DUMP_secret

# Override por variables de entorno
SECRET_NAME=mi-secret \
AWS_REGION=us-east-1 \
SSL_MODE=verify-full \
DB_NAME=mydb \
./scripts/revision/conectar_postgresql.sh

# Sin Secrets Manager (credenciales directas)
DB_HOST=mydb.amazonaws.com \
DB_USER=admin \
DB_PASS='mipass' \
DB_SERVICE=ORCL \
./scripts/revision/conectar_oracle.sh
```

### Reportes de auditoría

Los 3 scripts **guardan automáticamente toda su salida** en archivos de texto dentro de `./audit-reports/` (relativo al directorio donde se ejecuta el script).

#### Estructura del archivo

```
================================================================
 REPORTE DE AUDITORIA - POSTGRESQL RDS
================================================================
 Fecha:            2026-05-21 15:30:42 UTC
 Ejecutado por:    ec2-user@ip-10-40-222-167
 Caller identity:  arn:aws:sts::000999883737:assumed-role/bastion-role/i-0123abc
 Secret usado:     postgresql/qa/rds-credentials
 Region AWS:       us-east-1
 SSL Mode:         require
 Archivo reporte:  ./audit-reports/audit_postgresql_20260521_153042.txt
================================================================

[contenido de validación...]

================================================================
 Reporte completado: 2026-05-21 15:30:55 UTC
 Estado: EXITOSO
================================================================
```

#### Archivos generados

```
audit-reports/
├── audit_oracle_20260521_153042.txt
├── audit_postgresql_20260521_153115.txt
└── audit_mysql_20260521_153158.txt
```

#### Compartir con el cliente

```bash
# Empaquetar reportes del día
tar -czf reportes_auditoria_$(date +%Y%m%d).tar.gz audit-reports/

# Subir a S3 para evidencia
aws s3 cp reportes_auditoria_$(date +%Y%m%d).tar.gz \
  s3://mi-bucket-auditorias/$(date +%Y/%m)/

# Personalizar directorio de salida
AUDIT_DIR=/var/log/audits ./scripts/revision/conectar_postgresql.sh
```

> **Importante:** los reportes **no contienen passwords** (solo metadatos y resultados de queries). Aún así contienen nombres de schemas, usuarios y configuración interna — trátalos como información sensible. El `.gitignore` ya excluye `audit-reports/` para evitar commits accidentales.

---

## Backup completo de TODAS las bases de la instancia RDS

Para garantizar que se respaldan **todas las bases/schemas** de una instancia RDS (no solo una), usa el modo `ALL`. Es **especialmente útil** cuando el secret no incluye `dbname` o cuando la instancia tiene múltiples bases que no quieres enumerar.

### Comportamiento por motor

| Motor | Variable | Estrategia | Resultado en S3 |
|-------|----------|------------|-----------------|
| **PostgreSQL** | `DB_NAME=ALL` | Lista bases con `pg_database` y dumpea cada una con `pg_dump` | Un `.sql.gz` **por cada base** en `s3://bucket/postgresql/<dbname>/...` |
| **MySQL** | `DB_NAME=ALL` | Usa `mysqldump --all-databases` (nativo) | **Un solo archivo** `.sql.gz` con todas las bases |
| **Oracle** | `SCHEMAS=ALL` | Descubre todos los schemas no-system y los exporta con Data Pump | Un `.dmp` con todos los schemas |

### Bases/schemas excluidos automáticamente

| Motor | Excluidos |
|-------|-----------|
| PostgreSQL | `template0`, `template1`, `rdsadmin`, plantillas (`datistemplate=true`), bases sin conexión (`datallowconn=false`) |
| MySQL | `--all-databases` ya excluye al restaurar `information_schema`, `performance_schema`, `mysql.sys` |
| Oracle | Schemas Oracle-maintained (`SYS`, `SYSTEM`, `RDSADMIN`, `OUTLN`, `DBSNMP`, etc.) — usa `oracle_maintained='N'` |

### Privilegios necesarios

| Motor | Privilegios mínimos |
|-------|---------------------|
| PostgreSQL | `CONNECT` en cada base + `SELECT` en `pg_database` (admin/master user lo tiene) |
| MySQL | `SELECT, LOCK TABLES, SHOW VIEW, EVENT, TRIGGER` sobre `*.*` |
| Oracle | `SELECT_CATALOG_ROLE` + `DATAPUMP_EXP_FULL_DATABASE` |

> **⚠️ Crítico para Oracle:** El modo `SCHEMAS=ALL` requiere `DATAPUMP_EXP_FULL_DATABASE` igual que el modo `FULL`, porque el usuario debe poder leer schemas que no son suyos. Ver [Privilegios Oracle requeridos](#privilegios-oracle-requeridos).

### Ejemplos

```bash
# PostgreSQL - todas las bases
DB_NAME=ALL ./dump_postgresql_monthly.sh

# MySQL - todas las bases
DB_NAME=ALL ./dump_mysql_monthly.sh

# Oracle - todos los schemas de usuario
SCHEMAS=ALL ./dump_oracle_monthly.sh
```

En el crontab:

```cron
0 2 5 * * root DB_NAME=ALL /opt/scripts/monthly/dump_postgresql_monthly.sh >> /backups/postgresql/logs/cron_monthly.log 2>&1
30 2 5 * * root DB_NAME=ALL /opt/scripts/monthly/dump_mysql_monthly.sh >> /backups/mysql/logs/cron_monthly.log 2>&1
0 3 5 * * root SCHEMAS=ALL /opt/scripts/monthly/dump_oracle_monthly.sh >> /backups/oracle/logs/cron_monthly.log 2>&1
```

### Validación post-backup

PostgreSQL imprime un resumen al finalizar:

```
==========================================
RESUMEN
  Total bases procesadas: 5
  Exitosas: 5
  Fallidas: 0
==========================================
```

Si alguna base falla, el script termina con exit code `1` y lista las bases problemáticas. Esto es útil para integrar con monitoreo (CloudWatch alarms o similar).

Verificación manual desde S3:

```bash
# PostgreSQL: una carpeta por base
aws s3 ls s3://mi-bucket-dumps-short-term/postgresql/ --recursive | grep "$(date +%Y%m%d)"

# MySQL: archivo único
aws s3 ls s3://mi-bucket-dumps-short-term/mysql/ALL/

# Oracle: un dump
aws s3 ls s3://mi-bucket-dumps-short-term/oracle/
```

---

## Configuración SSL/TLS para conexiones a RDS

Todos los scripts de dump y validación soportan conexiones con/sin SSL. La variable `SSL_MODE` controla el comportamiento.

### Cómo verificar si tu RDS requiere SSL

| Motor | Comando |
|-------|---------|
| PostgreSQL | Console RDS → Parameter Group → buscar `rds.force_ssl`. <br>O ejecutar: `SHOW rds.force_ssl;` |
| MySQL | Console RDS → Parameter Group → buscar `require_secure_transport`. <br>O ejecutar: `SHOW VARIABLES LIKE 'require_secure_transport';` |
| Oracle | Console RDS → Configuration → Option Group. Si tiene la opción `SSL` agregada, está habilitado. |

### Modos SSL por motor

#### PostgreSQL (`SSL_MODE`)

| Modo | Descripción | Cuándo usar |
|------|-------------|-------------|
| `disable` | Sin SSL | Solo si la RDS NO tiene `rds.force_ssl=1` |
| `require` | SSL sin validar certificado | **Default**, recomendado para casi todos los casos |
| `verify-ca` | SSL + valida CA | Más seguro, requiere CA bundle |
| `verify-full` | SSL + valida CA + valida hostname | Máxima seguridad, **producción** |

#### MySQL (`SSL_MODE`)

| Modo | Descripción | Cuándo usar |
|------|-------------|-------------|
| `DISABLED` | Sin SSL | Solo si la RDS no requiere SSL |
| `PREFERRED` | Usa SSL si está disponible | Default de MySQL 8 |
| `REQUIRED` | SSL sin validar certificado | **Default**, recomendado |
| `VERIFY_CA` | SSL + valida CA | Más seguro |
| `VERIFY_IDENTITY` | SSL + valida CA + valida hostname | Máxima seguridad, **producción** |

#### Oracle (`SSL_MODE`)

| Modo | Protocolo TNS | Cuándo usar |
|------|---------------|-------------|
| `disable` | `TCP` | **Default**. Si la RDS Oracle NO tiene Option Group con SSL |
| `require` | `TCPS` | Si la RDS Oracle tiene Option Group con SSL agregado |

### Ejemplos

```bash
# Sin SSL (dev)
SSL_MODE=disable ./dump_postgresql_monthly.sh        # PostgreSQL
SSL_MODE=DISABLED ./dump_mysql_monthly.sh            # MySQL
SSL_MODE=disable ./dump_oracle_monthly.sh            # Oracle

# Con SSL básico (default - no requiere cambios)
./dump_postgresql_monthly.sh                          # PostgreSQL → require
./dump_mysql_monthly.sh                               # MySQL → REQUIRED

# Producción con validación estricta
SSL_MODE=verify-full ./dump_postgresql_monthly.sh    # PostgreSQL
SSL_MODE=VERIFY_IDENTITY ./dump_mysql_monthly.sh     # MySQL
SSL_MODE=require ./dump_oracle_monthly.sh            # Oracle TCPS
```

Cuando uses `verify-ca`/`verify-full` (PostgreSQL) o `VERIFY_CA`/`VERIFY_IDENTITY` (MySQL), el script descargará automáticamente el CA bundle de AWS desde:

```
https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
```

y lo guardará en `/etc/ssl/certs/rds-global-bundle.pem`. Requiere `sudo` y acceso a internet desde el bastion.

---

## Prerequisito: Integración S3 para Oracle RDS (Data Pump)

Los scripts de dump de Oracle usan **DBMS_DATAPUMP** dentro de la instancia RDS y luego transfieren el `.dmp` a S3 vía `rdsadmin.rdsadmin_s3_tasks.upload_to_s3`. Para que esto funcione, la instancia RDS Oracle necesita:

1. Un Option Group con la opción `S3_INTEGRATION` agregada
2. Un IAM Role asociado a la instancia con permisos de S3

> **Esta configuración NO requiere reinicio de la instancia RDS.** La opción `S3_INTEGRATION` es non-persistent y se aplica en caliente.

### Configuración automática (recomendada)

```bash
# Editar variables al inicio del script
vi scripts/revision/setup_oracle_s3_integration.sh

# Ejecutar con env vars
export AWS_ACCOUNT_ID="000999883737"
export AWS_REGION="us-east-1"
export RDS_INSTANCE_ID="mi-instancia-oracle"
export OPTION_GROUP_NAME="mi-option-group-custom"
export S3_BUCKET_SHORT_TERM="rds-dumps-short-term-000999883737"
export S3_BUCKET_LONG_TERM="rds-dumps-long-term-000999883737"

chmod +x scripts/revision/setup_oracle_s3_integration.sh
./scripts/revision/setup_oracle_s3_integration.sh
```

### Configuración manual

#### 1. Política IAM con acceso a S3

```bash
aws iam create-policy \
  --policy-name rds-oracle-s3-integration-policy \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:ListBucket", "s3:PutObject", "s3:DeleteObject"],
      "Resource": [
        "arn:aws:s3:::mi-bucket-dumps-short-term",
        "arn:aws:s3:::mi-bucket-dumps-short-term/*",
        "arn:aws:s3:::mi-bucket-dumps-long-term",
        "arn:aws:s3:::mi-bucket-dumps-long-term/*"
      ]
    }]
  }'
```

#### 2. IAM Role con trust policy para RDS

```bash
aws iam create-role \
  --role-name rds-oracle-s3-integration-role \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "rds.amazonaws.com"},
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {"aws:SourceAccount": "000999883737"}
      }
    }]
  }'
```

#### 3. Asociar política al role

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

#### 5. Asociar role a la instancia RDS

```bash
aws rds add-role-to-db-instance \
  --db-instance-identifier mi-instancia-oracle \
  --feature-name S3_INTEGRATION \
  --role-arn arn:aws:iam::000999883737:role/rds-oracle-s3-integration-role
```

#### 6. Verificar

```bash
aws rds describe-db-instances \
  --db-instance-identifier mi-instancia-oracle \
  --query 'DBInstances[0].AssociatedRoles'
```

Resultado esperado:
```json
[{
  "RoleArn": "arn:aws:iam::000999883737:role/rds-oracle-s3-integration-role",
  "FeatureName": "S3_INTEGRATION",
  "Status": "ACTIVE"
}]
```

#### 7. Test desde SQL*Plus

```sql
SELECT rdsadmin.rdsadmin_s3_tasks.upload_to_s3(
  p_bucket_name    => 'mi-bucket-dumps-short-term',
  p_prefix         => 'test/',
  p_directory_name => 'DATA_PUMP_DIR'
) AS task_id FROM DUAL;
```

### Referencia

- [Documentación oficial: Amazon S3 integration for Oracle RDS](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/oracle-s3-integration.html)
- [Troubleshooting S3 integration](https://repost.aws/knowledge-center/rds-oracle-s3-integration)

---

## Permisos KMS para Secrets Manager

Si los secrets en Secrets Manager están cifrados con una **KMS key custom (CMK)** (no la `aws/secretsmanager` por defecto), el role que ejecuta los scripts necesita permisos KMS adicionales. Sin esto verás:

```
ERROR: Access to KMS is not allowed when calling the GetSecretValue operation
```

### Identificar la KMS key del secret

```bash
aws secretsmanager describe-secret \
  --secret-id mi-secret \
  --region us-east-1 \
  --query 'KmsKeyId' \
  --output text
```

### Agregar permisos al IAM Role del bastion/Lambda

```bash
aws iam put-role-policy \
  --role-name <NOMBRE_DEL_ROLE> \
  --policy-name KMSDecryptForSecrets \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Sid": "AllowDecryptSecretsKey",
      "Effect": "Allow",
      "Action": ["kms:Decrypt", "kms:DescribeKey", "kms:GenerateDataKey"],
      "Resource": "<KMS_KEY_ARN>",
      "Condition": {
        "StringEquals": {
          "kms:ViaService": "secretsmanager.us-east-1.amazonaws.com"
        }
      }
    }]
  }'
```

### Verificar la KMS Key Policy

A veces además del IAM permission, la KMS key tiene su propia policy que debe permitir al role. Revisa:

```bash
aws kms get-key-policy --key-id <KEY_ARN> --policy-name default
```

Si el role del bastion no aparece en ningún `Statement`, agrega:

```json
{
  "Sid": "AllowBastionRoleToUseKey",
  "Effect": "Allow",
  "Principal": {
    "AWS": "arn:aws:iam::000999883737:role/<NOMBRE_DEL_ROLE>"
  },
  "Action": ["kms:Decrypt", "kms:DescribeKey", "kms:GenerateDataKey"],
  "Resource": "*"
}
```

---

## Privilegios Oracle requeridos

Los dumps de Oracle vía `DBMS_DATAPUMP` requieren privilegios específicos según el modo de export.

### Por modo de export

| Modo | Cómo se invoca | Privilegios requeridos |
|------|----------------|------------------------|
| `FULL` | `./dump_oracle_monthly.sh` (sin variable) | `DATAPUMP_EXP_FULL_DATABASE` |
| `SCHEMAS=ALL` | `SCHEMAS=ALL ./dump_oracle_monthly.sh` | `DATAPUMP_EXP_FULL_DATABASE` + `SELECT_CATALOG_ROLE` |
| `SCHEMAS="X,Y"` | `SCHEMAS="X,Y" ./dump_oracle_monthly.sh` | Solo si X, Y son del usuario actual: nada extra. Si no: `DATAPUMP_EXP_FULL_DATABASE` |

> **⚠️ Restricción de Oracle:** Para exportar schemas que NO son del usuario actual, **se requiere `DATAPUMP_EXP_FULL_DATABASE`** independientemente del modo (FULL o SCHEMA). El modo `SCHEMA` NO evita este requisito si los schemas no son tuyos.

### Otorgar privilegios al usuario de backup

Conéctate como **master user de la RDS** y ejecuta:

```sql
-- Privilegios necesarios para dumps con DATAPUMP
GRANT DATAPUMP_EXP_FULL_DATABASE TO USR_BACKUP_DUMP;
GRANT EXP_FULL_DATABASE TO USR_BACKUP_DUMP;
GRANT SELECT_CATALOG_ROLE TO USR_BACKUP_DUMP;
GRANT SELECT ANY TABLE TO USR_BACKUP_DUMP;
GRANT FLASHBACK ANY TABLE TO USR_BACKUP_DUMP;
```

### Verificar privilegios

Usa el script de validación:

```bash
./scripts/revision/conectar_oracle.sh USR_BACKUP_DUMP_secret
```

En la sección "PRIVILEGIOS RELEVANTES PARA DUMP/EXPORT" verás cuáles están otorgados.

---

## Notificaciones SNS

El stack de CloudFormation crea automáticamente un SNS Topic que recibe notificaciones cuando se sube un dump a S3. Útil para monitoreo y alertas.

### Suscribirse a las notificaciones

#### Por email (al desplegar)

Pasa el parámetro `NotificationEmail` al desplegar:

```bash
aws cloudformation deploy \
  --template-file cloudformation/template.yaml \
  --stack-name rds-dumps \
  --parameter-overrides NotificationEmail=ops@empresa.com ...
```

Recibirás un email de confirmación de SNS — debes aceptarlo.

#### Por email (post-deploy)

```bash
TOPIC_ARN=$(aws cloudformation describe-stacks \
  --stack-name rds-dumps \
  --query 'Stacks[0].Outputs[?OutputKey==`DumpNotificationTopicArn`].OutputValue' \
  --output text)

aws sns subscribe \
  --topic-arn "${TOPIC_ARN}" \
  --protocol email \
  --notification-endpoint ops@empresa.com
```

#### Por Lambda (procesamiento custom)

```bash
aws sns subscribe \
  --topic-arn "${TOPIC_ARN}" \
  --protocol lambda \
  --notification-endpoint arn:aws:lambda:us-east-1:000999883737:function:procesar-dump
```

### Eventos que generan notificaciones

| Evento S3 | Filter |
|-----------|--------|
| `s3:ObjectCreated:*` con prefix `oracle/` y suffix `.dmp` | Dump Oracle subido |
| `s3:ObjectCreated:*` con prefix `postgresql/` y suffix `.gz` | Dump PostgreSQL subido |
| `s3:ObjectCreated:*` con prefix `mysql/` y suffix `.gz` | Dump MySQL subido |

---

## Troubleshooting

### Error: `Database: null` en logs de PostgreSQL/MySQL

**Causa:** El secret no incluye el campo `dbname` (típico de secrets gestionados por AWS RDS).

**Solución:** Pasar `DB_NAME` por env var o usar modo `ALL`:

```bash
DB_NAME=mydb ./dump_postgresql_monthly.sh
DB_NAME=ALL ./dump_postgresql_monthly.sh
```

### Error: `ORA-39002: invalid operation`

**Causa:** El usuario no tiene privilegios suficientes para el modo de export elegido.

**Solución:** Otorgar privilegios (ver [Privilegios Oracle requeridos](#privilegios-oracle-requeridos)) o cambiar a modo SCHEMA si solo necesitas tus propios schemas.

### Error: `Access to KMS is not allowed`

**Causa:** El secret está cifrado con una KMS CMK y el role no tiene `kms:Decrypt`.

**Solución:** Ver [Permisos KMS para Secrets Manager](#permisos-kms-para-secrets-manager).

### Error: `permission denied for large object` en PostgreSQL

**Causa:** PostgreSQL Large Objects (LOBs) tienen permisos por objeto. El master user de RDS no es superuser real y no hereda permisos de LOBs creados por otros usuarios (común en Confluence, JIRA, etc).

**Solución:** Conectarse como el dueño de los LOBs (usuario de la app) y cambiar dueño:

```sql
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT oid FROM pg_largeobject_metadata LOOP
    EXECUTE 'ALTER LARGE OBJECT ' || r.oid || ' OWNER TO admin';
  END LOOP;
END $$;
```

### Error: `SP2-0306: Invalid option` en Oracle

**Causa:** El password tiene caracteres especiales (`@`, `/`, `(`) que rompen el parser de sqlplus.

**Solución:** Los scripts ya manejan esto vía archivo `.sql` temporal con `CONNECT user/"password"@tns`. Si lo ves manualmente, usa comillas dobles alrededor del password.

### El dump reporta éxito pero no aparece en S3

**Causa probable (Oracle):** Falta la integración S3.

**Solución:** Ejecutar `./scripts/revision/setup_oracle_s3_integration.sh` y verificar con:

```bash
./scripts/revision/conectar_oracle.sh
```

En la sección "INTEGRACION S3" debería decir "SI - Integracion S3 habilitada".

### Connection timeout (todos los motores)

**Causa:** Security Group de la RDS no permite tráfico desde el bastion.

**Solución:** Agregar el SG del bastion como source en el SG de la RDS para los puertos 1521 (Oracle), 5432 (PostgreSQL) o 3306 (MySQL).

---

## Notas adicionales

- Los scripts usan `set -euo pipefail` para fallar rápido ante errores
- Todos los archivos temporales con credenciales se crean con `chmod 600` y se eliminan en `trap EXIT`
- Los logs de los dumps quedan en `/backups/<motor>/logs/` para auditoría
- El `.gitignore` excluye `audit-reports/`, `*.tfvars`, `*.tfstate`, `*.log` para evitar commits accidentales de info sensible
