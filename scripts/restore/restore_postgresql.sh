#!/bin/bash
###############################################################################
# restore_postgresql.sh - Restaurar dump de PostgreSQL desde S3 a una RDS de prueba
#
# Uso manual:
#   ./restore_postgresql.sh
#   ./restore_postgresql.sh s3://bucket/postgresql/mydb/monthly/mydb_monthly_20260527.sql.gz
#
# ==============================================================================
# PROPOSITO
# ==============================================================================
# Este script se ejecuta MANUALMENTE para validar la integridad de los dumps
# almacenados en S3. Descarga un dump, lo restaura en una RDS de prueba
# dedicada y ejecuta validaciones basicas de integridad.
#
# FLUJO:
#   1. Descarga el dump (.sql.gz) desde S3 al bastion
#   2. Lo descomprime
#   3. Lo restaura en la RDS de prueba con psql
#   4. Ejecuta validaciones de integridad (count de tablas, schemas, etc.)
#   5. Genera un reporte de integridad
#
# IMPORTANTE:
#   - La RDS de prueba debe existir previamente (no la crea este script)
#   - La RDS de prueba se SOBREESCRIBE con cada restore (usar una dedicada)
#   - El dump se elimina del bastion despues de restaurar
#
# ==============================================================================
# CONFIGURACION SSL
# ==============================================================================
# Variable SSL_MODE: disable | require | verify-ca | verify-full
# Default: require
###############################################################################
set -euo pipefail

# ======================== CONFIGURACION ========================
# RDS de PRUEBA donde se restaura (NO la de produccion)
RESTORE_HOST="${RESTORE_HOST:-CHANGE_ME-restore.rds.amazonaws.com}"
RESTORE_PORT="${RESTORE_PORT:-5432}"
RESTORE_USER="${RESTORE_USER:-admin}"
RESTORE_PASS="${RESTORE_PASS:-CHANGE_ME}"
RESTORE_DB="${RESTORE_DB:-restore_test}"

# S3 - se puede pasar como argumento o definir aqui
S3_DUMP_PATH="${1:-${S3_DUMP_PATH:-}}"

# SSL
SSL_MODE="${SSL_MODE:-require}"
SSL_CA_CERT="${SSL_CA_CERT:-/etc/ssl/certs/rds-global-bundle.pem}"

# Directorio temporal para descargar dumps
WORK_DIR="${WORK_DIR:-/backups/postgresql/restore}"

# Region AWS
AWS_REGION="${AWS_REGION:-us-east-1}"
# ===============================================================

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${WORK_DIR}/restore_postgresql_${TIMESTAMP}.log"
REPORT_FILE="${WORK_DIR}/integrity_report_postgresql_${TIMESTAMP}.txt"

mkdir -p "${WORK_DIR}"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOG_FILE}"
}

cleanup() {
  log "Limpiando archivos temporales..."
  [[ -n "${DUMP_FILE_LOCAL:-}" && -f "${DUMP_FILE_LOCAL}" ]] && rm -f "${DUMP_FILE_LOCAL}"
  [[ -n "${DUMP_FILE_SQL:-}" && -f "${DUMP_FILE_SQL}" ]] && rm -f "${DUMP_FILE_SQL}"
  unset PGPASSWORD
}
trap cleanup EXIT

# ============================================================
# Validaciones
# ============================================================
if [[ -z "${S3_DUMP_PATH}" ]]; then
  echo "ERROR: Debe especificar la ruta S3 del dump a restaurar." >&2
  echo "" >&2
  echo "Uso:" >&2
  echo "  ./restore_postgresql.sh s3://bucket/postgresql/mydb/monthly/mydb_monthly_20260527.sql.gz" >&2
  echo "" >&2
  echo "Para listar dumps disponibles:" >&2
  echo "  aws s3 ls s3://rds-backup-ics-dumps-short-term-464326976274/postgresql/ --recursive" >&2
  exit 1
fi

if [[ "${RESTORE_HOST}" == "CHANGE_ME-restore.rds.amazonaws.com" ]]; then
  echo "ERROR: Configure RESTORE_HOST con el endpoint de la RDS de prueba." >&2
  echo "  export RESTORE_HOST=mi-rds-restore.xxx.rds.amazonaws.com" >&2
  exit 1
fi

for tool in aws psql gzip; do
  command -v "${tool}" >/dev/null 2>&1 || {
    echo "ERROR: '${tool}' no esta instalado" >&2
    exit 1
  }
done

# ============================================================
# Configuracion SSL
# ============================================================
case "${SSL_MODE}" in
  disable|require|verify-ca|verify-full)
    export PGSSLMODE="${SSL_MODE}"
    ;;
  *)
    echo "ERROR: SSL_MODE invalido: ${SSL_MODE}" >&2
    exit 1
    ;;
esac

if [[ "${SSL_MODE}" == "verify-ca" || "${SSL_MODE}" == "verify-full" ]]; then
  if [[ ! -f "${SSL_CA_CERT}" ]]; then
    sudo mkdir -p "$(dirname "${SSL_CA_CERT}")"
    sudo curl -fsSL -o "${SSL_CA_CERT}" \
      https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
    sudo chmod 644 "${SSL_CA_CERT}"
  fi
  export PGSSLROOTCERT="${SSL_CA_CERT}"
fi

export PGPASSWORD="${RESTORE_PASS}"

# ============================================================
# INICIO
# ============================================================
DUMP_FILENAME=$(basename "${S3_DUMP_PATH}")
DUMP_FILE_LOCAL="${WORK_DIR}/${DUMP_FILENAME}"
DUMP_FILE_SQL="${DUMP_FILE_LOCAL%.gz}"

{
  echo "================================================================"
  echo " REPORTE DE INTEGRIDAD - POSTGRESQL"
  echo "================================================================"
  echo " Fecha:          $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo " Ejecutado por:  $(whoami)@$(hostname)"
  echo " Dump S3:        ${S3_DUMP_PATH}"
  echo " RDS destino:    ${RESTORE_HOST}:${RESTORE_PORT}/${RESTORE_DB}"
  echo " SSL Mode:       ${SSL_MODE}"
  echo "================================================================"
  echo ""
} | tee "${REPORT_FILE}"

log "=========================================="
log "Restore PostgreSQL - Validacion de integridad"
log "Dump: ${S3_DUMP_PATH}"
log "Destino: ${RESTORE_HOST}:${RESTORE_PORT}/${RESTORE_DB}"
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
  gzip -df "${DUMP_FILE_LOCAL}" || {
    log "ERROR: Fallo la descompresion"
    exit 1
  }
  SQL_SIZE=$(du -sh "${DUMP_FILE_SQL}" | cut -f1)
  log "  Descomprimido: ${SQL_SIZE}"
else
  DUMP_FILE_SQL="${DUMP_FILE_LOCAL}"
fi

# ---------- Paso 3: Verificar conectividad a RDS de prueba ----------
log "Paso 3: Verificando conectividad a RDS de prueba..."
psql -h "${RESTORE_HOST}" -p "${RESTORE_PORT}" -U "${RESTORE_USER}" -d "${RESTORE_DB}" \
  -c "SELECT 1;" > /dev/null 2>&1 || {
  log "ERROR: No se pudo conectar a la RDS de prueba"
  log "  Host: ${RESTORE_HOST}:${RESTORE_PORT}"
  log "  DB: ${RESTORE_DB}"
  exit 1
}
log "  Conectividad OK"

# ---------- Paso 4: Limpiar base de prueba ----------
log "Paso 4: Limpiando base de prueba (DROP schemas existentes)..."
psql -h "${RESTORE_HOST}" -p "${RESTORE_PORT}" -U "${RESTORE_USER}" -d "${RESTORE_DB}" <<SQL 2>>"${LOG_FILE}"
DO \$\$
DECLARE
  r RECORD;
BEGIN
  FOR r IN (SELECT nspname FROM pg_namespace
            WHERE nspname NOT IN ('pg_catalog','information_schema','pg_toast')
            AND nspname NOT LIKE 'pg_temp%'
            AND nspname NOT LIKE 'pg_toast_temp%') LOOP
    EXECUTE 'DROP SCHEMA IF EXISTS ' || quote_ident(r.nspname) || ' CASCADE';
  END LOOP;
END \$\$;
CREATE SCHEMA IF NOT EXISTS public;
SQL
log "  Base limpiada"

# ---------- Paso 5: Restaurar dump ----------
log "Paso 5: Restaurando dump (esto puede tardar varios minutos)..."
RESTORE_START=$(date +%s)

psql -h "${RESTORE_HOST}" -p "${RESTORE_PORT}" -U "${RESTORE_USER}" -d "${RESTORE_DB}" \
  -f "${DUMP_FILE_SQL}" \
  --set ON_ERROR_STOP=off \
  > "${WORK_DIR}/restore_output_${TIMESTAMP}.log" 2>&1

RESTORE_RC=$?
RESTORE_END=$(date +%s)
RESTORE_DURATION=$(( RESTORE_END - RESTORE_START ))

if [[ ${RESTORE_RC} -ne 0 ]]; then
  log "  WARN: psql termino con codigo ${RESTORE_RC} (algunos errores son normales en restore)"
fi
log "  Restore completado en ${RESTORE_DURATION} segundos"

# ---------- Paso 6: Validaciones de integridad ----------
log "Paso 6: Ejecutando validaciones de integridad..."

{
  echo ""
  echo "================================================================"
  echo " VALIDACIONES DE INTEGRIDAD"
  echo "================================================================"
  echo ""
  echo "--- Schemas restaurados ---"
} | tee -a "${REPORT_FILE}"

psql -h "${RESTORE_HOST}" -p "${RESTORE_PORT}" -U "${RESTORE_USER}" -d "${RESTORE_DB}" \
  --pset=pager=off -c "
SELECT schema_name
FROM information_schema.schemata
WHERE schema_name NOT IN ('pg_catalog','information_schema','pg_toast')
ORDER BY schema_name;
" 2>&1 | tee -a "${REPORT_FILE}"

{
  echo ""
  echo "--- Conteo de tablas por schema ---"
} | tee -a "${REPORT_FILE}"

psql -h "${RESTORE_HOST}" -p "${RESTORE_PORT}" -U "${RESTORE_USER}" -d "${RESTORE_DB}" \
  --pset=pager=off -c "
SELECT schemaname, COUNT(*) AS tablas
FROM pg_tables
WHERE schemaname NOT IN ('pg_catalog','information_schema')
GROUP BY schemaname
ORDER BY tablas DESC;
" 2>&1 | tee -a "${REPORT_FILE}"

{
  echo ""
  echo "--- Top 10 tablas mas grandes ---"
} | tee -a "${REPORT_FILE}"

psql -h "${RESTORE_HOST}" -p "${RESTORE_PORT}" -U "${RESTORE_USER}" -d "${RESTORE_DB}" \
  --pset=pager=off -c "
SELECT schemaname || '.' || tablename AS tabla,
       pg_size_pretty(pg_total_relation_size(schemaname || '.' || tablename)) AS size,
       n_live_tup AS filas_aprox
FROM pg_stat_user_tables
ORDER BY pg_total_relation_size(schemaname || '.' || tablename) DESC
LIMIT 10;
" 2>&1 | tee -a "${REPORT_FILE}"

{
  echo ""
  echo "--- Resumen general ---"
} | tee -a "${REPORT_FILE}"

psql -h "${RESTORE_HOST}" -p "${RESTORE_PORT}" -U "${RESTORE_USER}" -d "${RESTORE_DB}" \
  --pset=pager=off -c "
SELECT
  (SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name NOT IN ('pg_catalog','information_schema','pg_toast')) AS schemas,
  (SELECT COUNT(*) FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema')) AS tablas,
  (SELECT COUNT(*) FROM pg_views WHERE schemaname NOT IN ('pg_catalog','information_schema')) AS vistas,
  (SELECT COUNT(*) FROM pg_indexes WHERE schemaname NOT IN ('pg_catalog','pg_toast')) AS indices,
  (SELECT pg_size_pretty(pg_database_size(current_database()))) AS tamano_total;
" 2>&1 | tee -a "${REPORT_FILE}"

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
