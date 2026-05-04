#!/bin/bash
###############################################################################
# dump_mysql_monthly.sh - Dump mensual de MySQL RDS → bucket short-term (1 año)
#
# Crontab: 0 2 5 * * /opt/scripts/monthly/dump_mysql_monthly.sh
#
# Uso manual:
#   ./dump_mysql_monthly.sh
#
# Configurar variables en la seccion CONFIGURACION antes de usar.
###############################################################################
set -euo pipefail

# ======================== CONFIGURACION ========================
S3_BUCKET="${S3_BUCKET:-CHANGE_ME-dumps-short-term}"
AWS_REGION="${AWS_REGION:-us-east-1}"
# ===============================================================

# ---------- OPCION 1: Secrets Manager (por defecto) ------------
# El secret debe contener un JSON con: host, port, username, password, dbname
SECRET_NAME="${SECRET_NAME:-mysql/rds/credentials}"

get_secret() {
  local secret_json
  secret_json=$(aws secretsmanager get-secret-value \
    --secret-id "${SECRET_NAME}" \
    --region "${AWS_REGION}" \
    --query 'SecretString' \
    --output text 2>/dev/null) || {
    echo "ERROR: No se pudo obtener el secret '${SECRET_NAME}' de Secrets Manager" >&2
    exit 1
  }
  echo "${secret_json}"
}

SECRET_JSON=$(get_secret)
DB_HOST=$(echo "${SECRET_JSON}" | jq -r '.host')
DB_PORT=$(echo "${SECRET_JSON}" | jq -r '.port // "3306"')
DB_USER=$(echo "${SECRET_JSON}" | jq -r '.username')
DB_PASS=$(echo "${SECRET_JSON}" | jq -r '.password')
DB_NAME=$(echo "${SECRET_JSON}" | jq -r '.dbname // "ALL"')
# ---------------------------------------------------------------

# ---------- OPCION 2: Credenciales hardcodeadas ----------------
# Descomentar este bloque y comentar la OPCION 1 para usar
# credenciales directas sin Secrets Manager.
#
# DB_HOST="CHANGE_ME.rds.amazonaws.com"
# DB_PORT="3306"
# DB_USER="admin"
# DB_PASS="CHANGE_ME"
# DB_NAME="mydb"  # Usar "ALL" para todas las bases
# ---------------------------------------------------------------

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/backups/mysql/monthly"
LOG_FILE="/backups/mysql/logs/dump_mysql_monthly_${TIMESTAMP}.log"

mkdir -p "${BACKUP_DIR}" "/backups/mysql/logs"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOG_FILE}"
}

cleanup() {
  log "Limpiando archivos temporales..."
  if [[ -n "${DUMP_FILE:-}" && -f "${DUMP_FILE}" ]]; then
    rm -f "${DUMP_FILE}"
    log "Archivo temporal ${DUMP_FILE} eliminado"
  fi
}
trap cleanup EXIT

DUMP_FILE="${BACKUP_DIR}/${DB_NAME}_monthly_${TIMESTAMP}.sql.gz"
S3_KEY="mysql/${DB_NAME}/monthly/${DB_NAME}_monthly_${TIMESTAMP}.sql.gz"

log "=========================================="
log "Dump MENSUAL MySQL RDS → bucket short-term"
log "Host: ${DB_HOST}:${DB_PORT} | Database: ${DB_NAME}"
log "=========================================="

log "Verificando conectividad..."
mysql -h "${DB_HOST}" -P "${DB_PORT}" -u "${DB_USER}" -p"${DB_PASS}" \
  -e "SELECT 1;" > /dev/null 2>&1 || {
  log "ERROR: No se pudo conectar a MySQL RDS"; exit 1
}

log "Ejecutando mysqldump..."
if [[ "${DB_NAME}" == "ALL" ]]; then
  mysqldump -h "${DB_HOST}" -P "${DB_PORT}" -u "${DB_USER}" -p"${DB_PASS}" \
    --all-databases --single-transaction --routines --triggers --events \
    --set-gtid-purged=OFF --column-statistics=0 --no-tablespaces \
    2>>"${LOG_FILE}" | gzip -9 > "${DUMP_FILE}" || {
    log "ERROR: Fallo el mysqldump"; exit 1
  }
else
  mysqldump -h "${DB_HOST}" -P "${DB_PORT}" -u "${DB_USER}" -p"${DB_PASS}" \
    --databases "${DB_NAME}" --single-transaction --routines --triggers --events \
    --set-gtid-purged=OFF --column-statistics=0 --no-tablespaces \
    2>>"${LOG_FILE}" | gzip -9 > "${DUMP_FILE}" || {
    log "ERROR: Fallo el mysqldump"; exit 1
  }
fi

DUMP_SIZE=$(du -sh "${DUMP_FILE}" | cut -f1)
log "Dump generado: ${DUMP_FILE} (${DUMP_SIZE})"

log "Subiendo a s3://${S3_BUCKET}/${S3_KEY}..."
aws s3 cp "${DUMP_FILE}" "s3://${S3_BUCKET}/${S3_KEY}" --storage-class STANDARD --only-show-errors || {
  log "ERROR: Fallo la subida a S3"; exit 1
}

S3_SIZE=$(aws s3 ls "s3://${S3_BUCKET}/${S3_KEY}" | awk '{print $3}')
log "Subido exitosamente (${S3_SIZE} bytes)"
log "Dump mensual MySQL completado: s3://${S3_BUCKET}/${S3_KEY}"
