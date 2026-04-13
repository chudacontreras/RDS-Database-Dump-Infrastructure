#!/bin/bash
###############################################################################
# dump_oracle_yearly.sh - Dump anual de Oracle RDS → bucket long-term (8 años)
#
# Crontab: 0 2 10 1 * /opt/scripts/yearly/dump_oracle_yearly.sh
#
# Uso manual:
#   ./dump_oracle_yearly.sh
#
# Configurar variables en la seccion CONFIGURACION antes de usar.
###############################################################################
set -euo pipefail

# ======================== CONFIGURACION ========================
DB_HOST="CHANGE_ME.rds.amazonaws.com"
DB_PORT="1521"
DB_USER="admin"
DB_PASS="CHANGE_ME"
DB_SERVICE="ORCL"
SCHEMAS=""  # Dejar vacio para FULL, o "SCHEMA1,SCHEMA2"
S3_BUCKET="CHANGE_ME-dumps-long-term"
# ===============================================================

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/backups/oracle/yearly"
LOG_FILE="/backups/oracle/logs/dump_oracle_yearly_${TIMESTAMP}.log"
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
DUMP_FILE_RAW="${BACKUP_DIR}/${DB_IDENTIFIER}_yearly_${TIMESTAMP}.dmp"
DUMP_FILE="${DUMP_FILE_RAW}.gz"
S3_KEY="oracle/${DB_IDENTIFIER}/yearly/${DB_IDENTIFIER}_yearly_${TIMESTAMP}.dmp.gz"
CONNECTION_STRING="${DB_USER}/${DB_PASS}@(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=${DB_HOST})(PORT=${DB_PORT}))(CONNECT_DATA=(SERVICE_NAME=${DB_SERVICE})))"

log "=========================================="
log "Dump ANUAL Oracle RDS → bucket long-term (8 años)"
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
    LOG="${BACKUP_DIR}/${DB_IDENTIFIER}_yearly_${TIMESTAMP}_exp.log" 2>&1 | tee -a "${LOG_FILE}" || {
    log "ERROR: Fallo el export"; exit 1
  }
else
  exp "${CONNECTION_STRING}" FILE="${DUMP_FILE_RAW}" FULL=Y \
    COMPRESS=Y CONSISTENT=Y STATISTICS=NONE \
    LOG="${BACKUP_DIR}/${DB_IDENTIFIER}_yearly_${TIMESTAMP}_exp.log" 2>&1 | tee -a "${LOG_FILE}" || {
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
log "Dump anual Oracle completado: s3://${S3_BUCKET}/${S3_KEY}"
