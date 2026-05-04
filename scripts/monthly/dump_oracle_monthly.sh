#!/bin/bash
###############################################################################
# dump_oracle_monthly.sh - Dump mensual de Oracle RDS → bucket short-term (1 año)
#
# Crontab: 0 2 5 * * /opt/scripts/monthly/dump_oracle_monthly.sh
#
# Uso manual:
#   ./dump_oracle_monthly.sh
#
# Configurar variables en la seccion CONFIGURACION antes de usar.
###############################################################################
set -euo pipefail

# ======================== CONFIGURACION ========================
SCHEMAS=""  # Dejar vacio para FULL, o "SCHEMA1,SCHEMA2"
S3_BUCKET="${S3_BUCKET:-CHANGE_ME-dumps-short-term}"
AWS_REGION="${AWS_REGION:-us-east-1}"
# ===============================================================

# ---------- OPCION 1: Secrets Manager (por defecto) ------------
# El secret debe contener un JSON con: host, port, username, password, dbname
SECRET_NAME="${SECRET_NAME:-oracle/rds/credentials}"

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
DB_PORT=$(echo "${SECRET_JSON}" | jq -r '.port // "1521"')
DB_USER=$(echo "${SECRET_JSON}" | jq -r '.username')
DB_PASS=$(echo "${SECRET_JSON}" | jq -r '.password')
DB_SERVICE=$(echo "${SECRET_JSON}" | jq -r '.dbname')
# ---------------------------------------------------------------

# ---------- OPCION 2: Credenciales hardcodeadas ----------------
# Descomentar este bloque y comentar la OPCION 1 para usar
# credenciales directas sin Secrets Manager.
#
# DB_HOST="CHANGE_ME.rds.amazonaws.com"
# DB_PORT="1521"
# DB_USER="admin"
# DB_PASS="CHANGE_ME"
# DB_SERVICE="ORCL"
# ---------------------------------------------------------------

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/backups/oracle/monthly"
LOG_FILE="/backups/oracle/logs/dump_oracle_monthly_${TIMESTAMP}.log"
ORACLE_HOME="/usr/lib/oracle/21/client64"
export LD_LIBRARY_PATH="${ORACLE_HOME}/lib:${LD_LIBRARY_PATH:-}"
export PATH="${ORACLE_HOME}/bin:${PATH}"

mkdir -p "${BACKUP_DIR}" "/backups/oracle/logs"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOG_FILE}"
}

cleanup() {
  log "Limpiando archivos temporales..."
  if [[ -n "${DUMP_FILE:-}" && -f "${DUMP_FILE}" ]]; then
    rm -f "${DUMP_FILE}"
    log "Archivo temporal ${DUMP_FILE} eliminado"
  fi
  if [[ -n "${DUMP_FILE_RAW:-}" && -f "${DUMP_FILE_RAW}" ]]; then
    rm -f "${DUMP_FILE_RAW}"
  fi
}
trap cleanup EXIT

DB_IDENTIFIER="${DB_SERVICE}"
DUMP_FILE_RAW="${BACKUP_DIR}/${DB_IDENTIFIER}_monthly_${TIMESTAMP}.dmp"
DUMP_FILE="${DUMP_FILE_RAW}.gz"
S3_KEY="oracle/${DB_IDENTIFIER}/monthly/${DB_IDENTIFIER}_monthly_${TIMESTAMP}.dmp.gz"
CONNECTION_STRING="${DB_USER}/${DB_PASS}@(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=${DB_HOST})(PORT=${DB_PORT}))(CONNECT_DATA=(SERVICE_NAME=${DB_SERVICE})))"

log "=========================================="
log "Dump MENSUAL Oracle RDS → bucket short-term"
log "Host: ${DB_HOST}:${DB_PORT} | Service: ${DB_SERVICE}"
log "=========================================="

log "Verificando conectividad..."
echo "SELECT 'OK' FROM DUAL;" | sqlplus -S "${CONNECTION_STRING}" > /dev/null 2>&1 || {
  log "ERROR: No se pudo conectar a Oracle RDS"; exit 1
}

log "Ejecutando export..."
if [[ -n "${SCHEMAS}" ]]; then
  exp "${CONNECTION_STRING}" FILE="${DUMP_FILE_RAW}" OWNER="${SCHEMAS}" \
    COMPRESS=Y CONSISTENT=Y STATISTICS=NONE \
    LOG="${BACKUP_DIR}/${DB_IDENTIFIER}_monthly_${TIMESTAMP}_exp.log" 2>&1 | tee -a "${LOG_FILE}" || {
    log "ERROR: Fallo el export"; exit 1
  }
else
  exp "${CONNECTION_STRING}" FILE="${DUMP_FILE_RAW}" FULL=Y \
    COMPRESS=Y CONSISTENT=Y STATISTICS=NONE \
    LOG="${BACKUP_DIR}/${DB_IDENTIFIER}_monthly_${TIMESTAMP}_exp.log" 2>&1 | tee -a "${LOG_FILE}" || {
    log "ERROR: Fallo el export"; exit 1
  }
fi

log "Comprimiendo dump..."
gzip -9 "${DUMP_FILE_RAW}"
DUMP_SIZE=$(du -sh "${DUMP_FILE}" | cut -f1)
log "Dump comprimido: ${DUMP_FILE} (${DUMP_SIZE})"

log "Subiendo a s3://${S3_BUCKET}/${S3_KEY}..."
aws s3 cp "${DUMP_FILE}" "s3://${S3_BUCKET}/${S3_KEY}" --storage-class STANDARD --only-show-errors || {
  log "ERROR: Fallo la subida a S3"; exit 1
}

S3_SIZE=$(aws s3 ls "s3://${S3_BUCKET}/${S3_KEY}" | awk '{print $3}')
log "Subido exitosamente (${S3_SIZE} bytes)"
log "Dump mensual Oracle completado: s3://${S3_BUCKET}/${S3_KEY}"
