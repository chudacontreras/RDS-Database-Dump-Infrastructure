#!/bin/bash
set -euo pipefail
exec > >(tee /var/log/user-data.log) 2>&1

echo "=== Actualizando sistema operativo ==="
dnf update -y

echo "=== Instalando herramientas base ==="
dnf install -y \
  amazon-efs-utils \
  nfs-utils \
  aws-cli \
  gzip \
  tar \
  jq \
  unzip \
  cronie

echo "=== Instalando cliente PostgreSQL ==="
dnf install -y postgresql15

echo "=== Instalando cliente MySQL ==="
dnf install -y mariadb105

echo "=== Instalando Oracle Instant Client ==="
dnf install -y libaio
ORACLE_VERSION="21.15.0.0.0-1"
ORACLE_BASE_URL="https://yum.oracle.com/repo/OracleLinux/OL9/oracle/instantclient/x86_64/getPackage"
rpm -ivh $${ORACLE_BASE_URL}/oracle-instantclient-basic-$${ORACLE_VERSION}.el9.x86_64.rpm || true
rpm -ivh $${ORACLE_BASE_URL}/oracle-instantclient-sqlplus-$${ORACLE_VERSION}.el9.x86_64.rpm || true
rpm -ivh $${ORACLE_BASE_URL}/oracle-instantclient-tools-$${ORACLE_VERSION}.el9.x86_64.rpm || true

echo 'export LD_LIBRARY_PATH=/usr/lib/oracle/21/client64/lib:$LD_LIBRARY_PATH' >> /etc/profile.d/oracle.sh
echo 'export PATH=/usr/lib/oracle/21/client64/bin:$PATH' >> /etc/profile.d/oracle.sh
source /etc/profile.d/oracle.sh

echo "=== Instalando y habilitando SSM Agent ==="
dnf install -y amazon-ssm-agent
systemctl enable amazon-ssm-agent
systemctl start amazon-ssm-agent

echo "=== Montando EFS en /backups ==="
mkdir -p /backups
echo "${efs_id}.efs.${aws_region}.amazonaws.com:/ /backups efs _netdev,tls 0 0" >> /etc/fstab
mount -a || mount -t efs -o tls ${efs_id}:/ /backups

echo "=== Creando directorios de trabajo ==="
mkdir -p /backups/oracle/monthly /backups/oracle/yearly /backups/oracle/logs
mkdir -p /backups/postgresql/monthly /backups/postgresql/yearly /backups/postgresql/logs
mkdir -p /backups/mysql/monthly /backups/mysql/yearly /backups/mysql/logs
mkdir -p /opt/scripts/monthly /opt/scripts/yearly

echo "=== Habilitando servicio cron ==="
systemctl enable crond
systemctl start crond

echo "=== Configurando crontabs ==="
cat > /etc/cron.d/dump-monthly <<'CRON'
# Dump mensual - dia 5 de cada mes a las 02:00 → bucket short-term (1 año)
0 2 5 * * root /opt/scripts/monthly/dump_oracle_monthly.sh >> /backups/oracle/logs/cron_monthly.log 2>&1
30 2 5 * * root /opt/scripts/monthly/dump_postgresql_monthly.sh >> /backups/postgresql/logs/cron_monthly.log 2>&1
0 3 5 * * root /opt/scripts/monthly/dump_mysql_monthly.sh >> /backups/mysql/logs/cron_monthly.log 2>&1
CRON

cat > /etc/cron.d/dump-yearly <<'CRON'
# Dump anual - dia 10 de enero a las 02:00 → bucket long-term (8 años)
0 2 10 1 * root /opt/scripts/yearly/dump_oracle_yearly.sh >> /backups/oracle/logs/cron_yearly.log 2>&1
30 2 10 1 * root /opt/scripts/yearly/dump_postgresql_yearly.sh >> /backups/postgresql/logs/cron_yearly.log 2>&1
0 3 10 1 * root /opt/scripts/yearly/dump_mysql_yearly.sh >> /backups/mysql/logs/cron_yearly.log 2>&1
CRON

chmod 644 /etc/cron.d/dump-monthly /etc/cron.d/dump-yearly

echo "=== Configuracion completada ==="
