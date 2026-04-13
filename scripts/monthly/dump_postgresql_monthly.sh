#!/bin/bash
###############################################################################
# dump_postgresql_monthly.sh - Dump mensual de PostgreSQL RDS → bucket short-term (1 año)
#
# Crontab: 0 2 5 * * /opt/scripts/monthly/dump_postgresql_monthly.sh
#
# Uso manual:
#   ./dump_postgresql_monthly.sh
#
# Configurar variables en la seccion CONFIGURACION antes de usar.
###############################################################################
set -euo pipefail

# ======================== CONFIGURACION ========================
DB_HOST="CHANGE_ME.rds.amazonaws.com"
DB_PORT="5432"
DB_USER="admin"
DB_PASS="CHANGE_ME"
DB_NAME="mydb"
SCHEMAS=""  # Dejar vacio para full, o "public,app"
S3_BUCKET="CHANGE_ME-dumps-short-term"
# ===============================================================

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/backups/postgresql/monthly"
LOG_FILE="/backups/postgresql/logs/dump_postgresql_monthly_${TIMESTAMP}.log"

mkdir -p "${BACKUP_DIR}" "/backups/postgresql/logs"

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
S3_KEY="postgresql/${DB_NAME}/monthly/${DB_NAME}_monthly_${TIMESTAMP}.sql.gz"
export PGPASSWORD="${DB_PASS}"

log "=========================================="
log "Dump MENSUAL PostgreSQL RDS → bucket short-term"
log "Host: ${DB_HOST}:${DB_PORT} | Database: ${DB_NAME}"
log "=========================================="

log "Verificando conectividad..."
psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" \
  -c "SELECT 1;" > /dev/null 2>&1 || {
  log "ERROR: No se pudo conectar a PostgreSQL RDS"; exit 1
}

SCHEMA_OPTS=""
if [[ -n "${SCHEMAS}" ]]; then
  IFS=',' read -ra SCHEMA_ARRAY <<< "${SCHEMAS}"
  for schema in "${SCHEMA_ARRAY[@]}"; do
    SCHEMA_OPTS="${SCHEMA_OPTS} -n ${schema}"
  done
  log "Exportando schemas: ${SCHEMAS}"
else
  log "Exportando base de datos completa"
fi

log "Ejecutando pg_dump..."
pg_dump \
  -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" \
  -v --no-owner --no-privileges --format=plain \
  ${SCHEMA_OPTS} \
  2>>"${LOG_FILE}" | gzip -9 > "${DUMP_FILE}" || {
  log "ERROR: Fallo el pg_dump"; exit 1
}

DUMP_SIZE=$(du -sh "${DUMP_FILE}" | cut -f1)
log "Dump generado: ${DUMP_FILE} (${DUMP_SIZE})"

log "Subiendo a s3://${S3_BUCKET}/${S3_KEY}..."
aws s3 cp "${DUMP_FILE}" "s3://${S3_BUCKET}/${S3_KEY}" --storage-class STANDARD --only-show-errors || {
  log "ERROR: Fallo la subida a S3"; exit 1
}

S3_SIZE=$(aws s3 ls "s3://${S3_BUCKET}/${S3_KEY}" | awk '{print $3}')
unset PGPASSWORD
log "Subido exitosamente (${S3_SIZE} bytes)"
log "Dump mensual PostgreSQL completado: s3://${S3_BUCKET}/${S3_KEY}"
