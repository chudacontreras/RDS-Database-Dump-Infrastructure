#!/bin/bash
###############################################################################
# restore_mysql.sh - Restaurar dump de MySQL desde S3 a una RDS de prueba
#
# Uso manual:
#   ./restore_mysql.sh
#   ./restore_mysql.sh s3://bucket/mysql/ALL/monthly/ALL_monthly_20260527.sql.gz
#
# ==============================================================================
# PROPOSITO
# ==============================================================================
# Validar integridad de dumps MySQL almacenados en S3.
# Descarga, restaura en RDS de prueba y ejecuta validaciones.
#
# IMPORTANTE:
#   - La RDS de prueba debe existir previamente
#   - La RDS de prueba se SOBREESCRIBE con cada restore
#   - El dump se elimina del bastion despues de restaurar
#
# ==============================================================================
# CONFIGURACION SSL
# ==============================================================================
# Variable SSL_MODE: DISABLED | PREFERRED | REQUIRED | VERIFY_CA | VERIFY_IDENTITY
# Default: REQUIRED
###############################################################################
set -euo pipefail

# ======================== CONFIGURACION ========================
# RDS de PRUEBA donde se restaura (NO la de produccion)
RESTORE_HOST="${RESTORE_HOST:-CHANGE_ME-restore.rds.amazonaws.com}"
RESTORE_PORT="${RESTORE_PORT:-3306}"
RESTORE_USER="${RESTORE_USER:-admin}"
RESTORE_PASS="${RESTORE_PASS:-CHANGE_ME}"

# S3 - se puede pasar como argumento o definir aqui
S3_DUMP_PATH="${1:-${S3_DUMP_PATH:-}}"

# SSL
SSL_MODE="${SSL_MODE:-REQUIRED}"
SSL_CA_CERT="${SSL_CA_CERT:-/etc/ssl/certs/rds-global-bundle.pem}"

# Directorio temporal
WORK_DIR="${WORK_DIR:-/backups/mysql/restore}"

AWS_REGION="${AWS_REGION:-us-east-1}"
# ===============================================================

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${WORK_DIR}/restore_mysql_${TIMESTAMP}.log"
REPORT_FILE="${WORK_DIR}/integrity_report_mysql_${TIMESTAMP}.txt"

mkdir -p "${WORK_DIR}"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOG_FILE}"
}

cleanup() {
  log "Limpiando archivos temporales..."
  [[ -n "${DUMP_FILE_LOCAL:-}" && -f "${DUMP_FILE_LOCAL}" ]] && rm -f "${DUMP_FILE_LOCAL}"
  [[ -n "${DUMP_FILE_SQL:-}" && -f "${DUMP_FILE_SQL}" ]] && rm -f "${DUMP_FILE_SQL}"
  rm -f "${MYSQL_CNF:-/dev/null}" 2>/dev/null
}
trap cleanup EXIT

# ============================================================
# Validaciones
# ============================================================
if [[ -z "${S3_DUMP_PATH}" ]]; then
  echo "ERROR: Debe especificar la ruta S3 del dump a restaurar." >&2
  echo "" >&2
  echo "Uso:" >&2
  echo "  ./restore_mysql.sh s3://bucket/mysql/ALL/monthly/ALL_monthly_20260527.sql.gz" >&2
  echo "" >&2
  echo "Para listar dumps disponibles:" >&2
  echo "  aws s3 ls s3://rds-backup-ics-dumps-short-term-464326976274/mysql/ --recursive" >&2
  exit 1
fi

if [[ "${RESTORE_HOST}" == "CHANGE_ME-restore.rds.amazonaws.com" ]]; then
  echo "ERROR: Configure RESTORE_HOST con el endpoint de la RDS de prueba." >&2
  exit 1
fi

for tool in aws mysql gzip; do
  command -v "${tool}" >/dev/null 2>&1 || {
    echo "ERROR: '${tool}' no esta instalado" >&2
    exit 1
  }
done

# ============================================================
# Configuracion SSL
# ============================================================
case "${SSL_MODE}" in
  DISABLED|PREFERRED|REQUIRED|VERIFY_CA|VERIFY_IDENTITY) ;;
  *)
    echo "ERROR: SSL_MODE invalido: ${SSL_MODE}" >&2
    exit 1
    ;;
esac

if [[ "${SSL_MODE}" == "VERIFY_CA" || "${SSL_MODE}" == "VERIFY_IDENTITY" ]]; then
  if [[ ! -f "${SSL_CA_CERT}" ]]; then
    sudo mkdir -p "$(dirname "${SSL_CA_CERT}")"
    sudo curl -fsSL -o "${SSL_CA_CERT}" \
      https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
    sudo chmod 644 "${SSL_CA_CERT}"
  fi
fi

# Crear archivo .my.cnf temporal
MYSQL_CNF=$(mktemp /tmp/mysql_restore_XXXXXX.cnf)
chmod 600 "${MYSQL_CNF}"
{
  echo "[client]"
  echo "host=${RESTORE_HOST}"
  echo "port=${RESTORE_PORT}"
  echo "user=${RESTORE_USER}"
  echo "password=${RESTORE_PASS}"
  echo "ssl-mode=${SSL_MODE}"
  if [[ "${SSL_MODE}" == "VERIFY_CA" || "${SSL_MODE}" == "VERIFY_IDENTITY" ]]; then
    echo "ssl-ca=${SSL_CA_CERT}"
  fi
} > "${MYSQL_CNF}"

# ============================================================
# INICIO
# ============================================================
DUMP_FILENAME=$(basename "${S3_DUMP_PATH}")
DUMP_FILE_LOCAL="${WORK_DIR}/${DUMP_FILENAME}"
DUMP_FILE_SQL="${DUMP_FILE_LOCAL%.gz}"

{
  echo "================================================================"
  echo " REPORTE DE INTEGRIDAD - MYSQL"
  echo "================================================================"
  echo " Fecha:          $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo " Ejecutado por:  $(whoami)@$(hostname)"
  echo " Dump S3:        ${S3_DUMP_PATH}"
  echo " RDS destino:    ${RESTORE_HOST}:${RESTORE_PORT}"
  echo " SSL Mode:       ${SSL_MODE}"
  echo "================================================================"
  echo ""
} | tee "${REPORT_FILE}"

log "=========================================="
log "Restore MySQL - Validacion de integridad"
log "Dump: ${S3_DUMP_PATH}"
log "Destino: ${RESTORE_HOST}:${RESTORE_PORT}"
log "=========================================="

# ---------- Paso 1: Descargar dump desde S3 ----------
log "Paso 1: Descargando dump desde S3..."
aws s3 cp "${S3_DUMP_PATH}" "${DUMP_FILE_LOCAL}" --only-show-errors || {
  log "ERROR: No se pudo descargar el dump desde S3"
  exit 1
}
DUMP_SIZE=$(du -sh "${DUMP_FILE_LOCAL}" | cut -f1)
log "  Descargado: ${DUMP_FILENAME} (${DUMP_SIZE})"

# ---------- Paso 2: Descomprimir ----------
log "Paso 2: Descomprimiendo..."
if [[ "${DUMP_FILE_LOCAL}" == *.gz ]]; then
  gzip -df "${DUMP_FILE_LOCAL}"
  SQL_SIZE=$(du -sh "${DUMP_FILE_SQL}" | cut -f1)
  log "  Descomprimido: ${SQL_SIZE}"
else
  DUMP_FILE_SQL="${DUMP_FILE_LOCAL}"
fi

# ---------- Paso 3: Verificar conectividad ----------
log "Paso 3: Verificando conectividad a RDS de prueba..."
mysql --defaults-extra-file="${MYSQL_CNF}" -e "SELECT 1;" > /dev/null 2>&1 || {
  log "ERROR: No se pudo conectar a la RDS de prueba"
  exit 1
}
log "  Conectividad OK"

# ---------- Paso 4: Restaurar dump ----------
log "Paso 4: Restaurando dump (esto puede tardar varios minutos)..."
RESTORE_START=$(date +%s)

mysql --defaults-extra-file="${MYSQL_CNF}" \
  --force \
  < "${DUMP_FILE_SQL}" \
  > "${WORK_DIR}/restore_output_${TIMESTAMP}.log" 2>&1

RESTORE_RC=$?
RESTORE_END=$(date +%s)
RESTORE_DURATION=$(( RESTORE_END - RESTORE_START ))

if [[ ${RESTORE_RC} -ne 0 ]]; then
  log "  WARN: mysql termino con codigo ${RESTORE_RC} (algunos errores son normales)"
fi
log "  Restore completado en ${RESTORE_DURATION} segundos"

# ---------- Paso 5: Validaciones de integridad ----------
log "Paso 5: Ejecutando validaciones de integridad..."

run_sql() {
  local title="$1"
  local sql="$2"
  {
    echo ""
    echo "--- ${title} ---"
  } | tee -a "${REPORT_FILE}"
  mysql --defaults-extra-file="${MYSQL_CNF}" --table -e "${sql}" 2>&1 | tee -a "${REPORT_FILE}"
}

run_sql "Bases de datos restauradas" "
SELECT schema_name AS database_name,
       default_character_set_name AS charset
FROM information_schema.schemata
WHERE schema_name NOT IN ('mysql','information_schema','performance_schema','sys','tmp')
ORDER BY schema_name;
"

run_sql "Conteo de tablas por base" "
SELECT table_schema AS db, COUNT(*) AS tablas
FROM information_schema.tables
WHERE table_schema NOT IN ('mysql','information_schema','performance_schema','sys','tmp')
GROUP BY table_schema
ORDER BY tablas DESC;
"

run_sql "Top 10 tablas mas grandes" "
SELECT table_schema AS db,
       table_name AS tabla,
       table_rows AS filas,
       ROUND(data_length / 1024 / 1024, 2) AS data_mb,
       ROUND(index_length / 1024 / 1024, 2) AS index_mb
FROM information_schema.tables
WHERE table_schema NOT IN ('mysql','information_schema','performance_schema','sys','tmp')
ORDER BY (data_length + index_length) DESC
LIMIT 10;
"

run_sql "Resumen general" "
SELECT
  (SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','information_schema','performance_schema','sys','tmp')) AS bases,
  (SELECT COUNT(*) FROM information_schema.tables WHERE table_schema NOT IN ('mysql','information_schema','performance_schema','sys','tmp')) AS tablas,
  (SELECT COUNT(*) FROM information_schema.views WHERE table_schema NOT IN ('mysql','information_schema','performance_schema','sys','tmp')) AS vistas,
  (SELECT COUNT(*) FROM information_schema.routines WHERE routine_schema NOT IN ('mysql','information_schema','performance_schema','sys','tmp')) AS procedures;
"

# ---------- Resumen final ----------
{
  echo ""
  echo "================================================================"
  echo " RESULTADO"
  echo "================================================================"
  echo " Dump restaurado:    ${S3_DUMP_PATH}"
  echo " Tiempo de restore:  ${RESTORE_DURATION} segundos"
  echo " Estado:             COMPLETADO"
  echo " Reporte:            ${REPORT_FILE}"
  echo " Log detallado:      ${LOG_FILE}"
  echo "================================================================"
} | tee -a "${REPORT_FILE}"

log "=========================================="
log "Validacion de integridad completada"
log "Reporte: ${REPORT_FILE}"
log "=========================================="
