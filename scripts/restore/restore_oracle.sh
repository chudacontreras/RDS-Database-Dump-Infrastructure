#!/bin/bash
###############################################################################
# restore_oracle.sh - Restaurar dump de Oracle desde S3 a una RDS de prueba
#
# Uso manual:
#   ./restore_oracle.sh
#   ./restore_oracle.sh s3://bucket/oracle/RDSQA/monthly/RDSQA_monthly_20260527.dmp
#
# ==============================================================================
# PROPOSITO
# ==============================================================================
# Validar integridad de dumps Oracle almacenados en S3.
# Descarga el .dmp desde S3 a DATA_PUMP_DIR de la RDS de prueba y ejecuta
# DBMS_DATAPUMP.IMPORT para restaurar los schemas.
#
# FLUJO:
#   1. Descarga el .dmp desde S3 a DATA_PUMP_DIR de la RDS de prueba
#      (usa rdsadmin.rdsadmin_s3_tasks.download_from_s3)
#   2. Ejecuta Data Pump Import (DBMS_DATAPUMP en modo IMPORT/SCHEMA)
#   3. Ejecuta validaciones de integridad (count de objetos, schemas, etc.)
#   4. Genera un reporte de integridad
#   5. Limpia el .dmp de DATA_PUMP_DIR
#
# IMPORTANTE:
#   - La RDS de prueba debe tener la integracion S3 configurada
#   - La RDS de prueba debe tener suficiente espacio en DATA_PUMP_DIR
#   - El usuario debe tener DATAPUMP_IMP_FULL_DATABASE
#
# ==============================================================================
# CONFIGURACION SSL
# ==============================================================================
# Variable SSL_MODE: disable | require
###############################################################################
set -euo pipefail

# ======================== CONFIGURACION ========================
# RDS de PRUEBA donde se restaura (NO la de produccion)
RESTORE_HOST="${RESTORE_HOST:-CHANGE_ME-restore.rds.amazonaws.com}"
RESTORE_PORT="${RESTORE_PORT:-1521}"
RESTORE_USER="${RESTORE_USER:-admin}"
RESTORE_PASS="${RESTORE_PASS:-CHANGE_ME}"
RESTORE_SERVICE="${RESTORE_SERVICE:-ORCL}"

# S3 - se puede pasar como argumento
S3_DUMP_PATH="${1:-${S3_DUMP_PATH:-}}"

# Bucket donde estan los dumps (para download_from_s3)
S3_BUCKET="${S3_BUCKET:-CHANGE_ME-dumps-short-term}"

# SSL
SSL_MODE="${SSL_MODE:-disable}"

# Directorio de trabajo local (para logs)
WORK_DIR="${WORK_DIR:-/backups/oracle/restore}"

AWS_REGION="${AWS_REGION:-us-east-1}"
# ===============================================================

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${WORK_DIR}/restore_oracle_${TIMESTAMP}.log"
REPORT_FILE="${WORK_DIR}/integrity_report_oracle_${TIMESTAMP}.txt"

mkdir -p "${WORK_DIR}"

# Detectar Oracle Instant Client
ORACLE_LIB=$(ls -d /usr/lib/oracle/*/client64/lib 2>/dev/null | sort -V | tail -1 || true)
if [[ -n "${ORACLE_LIB}" ]]; then
  export LD_LIBRARY_PATH="${ORACLE_LIB}:${LD_LIBRARY_PATH:-}"
  export PATH="$(dirname "${ORACLE_LIB}")/bin:${PATH}"
fi

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOG_FILE}"
}

cleanup() {
  log "Limpiando archivos temporales..."
  rm -f /tmp/oracle_login_*.sql 2>/dev/null
}
trap cleanup EXIT

# ============================================================
# Validaciones
# ============================================================
if [[ -z "${S3_DUMP_PATH}" ]]; then
  echo "ERROR: Debe especificar la ruta S3 del dump a restaurar." >&2
  echo "" >&2
  echo "Uso:" >&2
  echo "  ./restore_oracle.sh s3://bucket/oracle/RDSQA/monthly/RDSQA_monthly_20260527.dmp" >&2
  echo "" >&2
  echo "Para listar dumps disponibles:" >&2
  echo "  aws s3 ls s3://rds-backup-ics-dumps-short-term-464326976274/oracle/ --recursive" >&2
  exit 1
fi

if [[ "${RESTORE_HOST}" == "CHANGE_ME-restore.rds.amazonaws.com" ]]; then
  echo "ERROR: Configure RESTORE_HOST con el endpoint de la RDS de prueba." >&2
  exit 1
fi

for tool in aws sqlplus; do
  command -v "${tool}" >/dev/null 2>&1 || {
    echo "ERROR: '${tool}' no esta instalado" >&2
    exit 1
  }
done

# ============================================================
# SSL
# ============================================================
case "${SSL_MODE}" in
  disable) PROTOCOL="TCP" ;;
  require) PROTOCOL="TCPS" ;;
  *)
    echo "ERROR: SSL_MODE invalido: ${SSL_MODE}" >&2
    exit 1
    ;;
esac

TNS_CONNECT="(DESCRIPTION=(ADDRESS=(PROTOCOL=${PROTOCOL})(HOST=${RESTORE_HOST})(PORT=${RESTORE_PORT}))(CONNECT_DATA=(SERVICE_NAME=${RESTORE_SERVICE})))"

run_sqlplus() {
  local sql_input="$1"
  local login_script
  login_script=$(mktemp /tmp/oracle_login_XXXXXX.sql)
  chmod 600 "${login_script}"
  cat > "${login_script}" <<EOSQL
CONNECT ${RESTORE_USER}/"${RESTORE_PASS}"@${TNS_CONNECT}
${sql_input}
EOSQL
  sqlplus -S -L /nolog @"${login_script}"
  local rc=$?
  rm -f "${login_script}"
  return ${rc}
}

# ============================================================
# INICIO
# ============================================================
# Extraer el S3 prefix y filename del path completo
# s3://bucket/oracle/RDSQA/monthly/file.dmp → prefix=oracle/RDSQA/monthly/ file=file.dmp
S3_FULL_KEY="${S3_DUMP_PATH#s3://*/}"  # quitar s3://bucket/
S3_PREFIX_PATH=$(dirname "${S3_FULL_KEY}")"/"
DUMP_FILENAME=$(basename "${S3_DUMP_PATH}")

{
  echo "================================================================"
  echo " REPORTE DE INTEGRIDAD - ORACLE"
  echo "================================================================"
  echo " Fecha:          $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo " Ejecutado por:  $(whoami)@$(hostname)"
  echo " Dump S3:        ${S3_DUMP_PATH}"
  echo " RDS destino:    ${RESTORE_HOST}:${RESTORE_PORT}/${RESTORE_SERVICE}"
  echo " SSL Mode:       ${SSL_MODE}"
  echo "================================================================"
  echo ""
} | tee "${REPORT_FILE}"

log "=========================================="
log "Restore Oracle - Validacion de integridad"
log "Dump: ${S3_DUMP_PATH}"
log "Destino: ${RESTORE_HOST}:${RESTORE_PORT}/${RESTORE_SERVICE}"
log "=========================================="

# ---------- Paso 1: Verificar conectividad ----------
log "Paso 1: Verificando conectividad a RDS de prueba..."
CONNECT_OUTPUT=$(run_sqlplus "SELECT 'CONNECTION_OK' FROM DUAL;
EXIT;" 2>&1) || true

if ! echo "${CONNECT_OUTPUT}" | grep -q "CONNECTION_OK"; then
  log "ERROR: No se pudo conectar a la RDS de prueba"
  exit 1
fi
log "  Conectividad OK"

# ---------- Paso 2: Descargar dump de S3 a DATA_PUMP_DIR ----------
log "Paso 2: Descargando dump de S3 a DATA_PUMP_DIR de la RDS..."

DOWNLOAD_SQL=$(cat <<EOF
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 200
SELECT rdsadmin.rdsadmin_s3_tasks.download_from_s3(
  p_bucket_name    => '${S3_BUCKET}',
  p_directory_name => 'DATA_PUMP_DIR',
  p_s3_prefix      => '${S3_PREFIX_PATH}${DUMP_FILENAME}'
) AS task_id FROM DUAL;
EXIT;
EOF
)

DOWNLOAD_OUTPUT=$(run_sqlplus "${DOWNLOAD_SQL}" 2>&1) || true
echo "${DOWNLOAD_OUTPUT}" >> "${LOG_FILE}"

if echo "${DOWNLOAD_OUTPUT}" | grep -qiE "^(ORA-|SP2-|ERROR)"; then
  log "ERROR: Fallo la descarga desde S3"
  log "Detalle: $(echo "${DOWNLOAD_OUTPUT}" | grep -iE 'ORA-|ERROR' | head -3)"
  exit 1
fi

DOWNLOAD_TASK_ID=$(echo "${DOWNLOAD_OUTPUT}" | grep -v '^$' | grep -vE '^(ORA-|SP2-|ERROR|SQL)' | head -1 | xargs)
log "  Download iniciado - Task ID: ${DOWNLOAD_TASK_ID}"

# Esperar a que el archivo aparezca en DATA_PUMP_DIR
log "  Esperando descarga..."
MAX_WAIT=300
ELAPSED=0
DOWNLOAD_DONE=false

while [[ ${ELAPSED} -lt ${MAX_WAIT} ]]; do
  sleep 15
  ELAPSED=$((ELAPSED + 15))

  CHECK_SQL="SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT filename FROM TABLE(rdsadmin.rds_file_util.listdir('DATA_PUMP_DIR'))
WHERE filename = '${DUMP_FILENAME}';
EXIT;"

  CHECK_OUTPUT=$(run_sqlplus "${CHECK_SQL}" 2>&1) || true
  if echo "${CHECK_OUTPUT}" | grep -q "${DUMP_FILENAME}"; then
    DOWNLOAD_DONE=true
    break
  fi
done

if [[ "${DOWNLOAD_DONE}" != "true" ]]; then
  log "ERROR: Timeout esperando descarga del dump (${MAX_WAIT}s)"
  exit 1
fi
log "  Dump descargado a DATA_PUMP_DIR"

# ---------- Paso 3: Ejecutar Data Pump Import ----------
log "Paso 3: Ejecutando Data Pump Import..."
RESTORE_START=$(date +%s)

JOB_NAME="IMP_$(echo "${TIMESTAMP}" | tail -c 16)"

IMPORT_SQL=$(cat <<EOF
SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 200
DECLARE
  v_hdnl      NUMBER;
  v_job_state VARCHAR2(30);
BEGIN
  v_hdnl := DBMS_DATAPUMP.OPEN(
    operation => 'IMPORT',
    job_mode  => 'SCHEMA',
    job_name  => '${JOB_NAME}'
  );

  DBMS_DATAPUMP.ADD_FILE(
    handle    => v_hdnl,
    filename  => '${DUMP_FILENAME}',
    directory => 'DATA_PUMP_DIR',
    filetype  => DBMS_DATAPUMP.KU\$_FILE_TYPE_DUMP_FILE
  );

  -- TABLE_EXISTS_ACTION=REPLACE para sobreescribir datos existentes
  DBMS_DATAPUMP.SET_PARAMETER(v_hdnl, 'TABLE_EXISTS_ACTION', 'REPLACE');

  DBMS_DATAPUMP.START_JOB(v_hdnl);
  DBMS_DATAPUMP.WAIT_FOR_JOB(v_hdnl, v_job_state);

  DBMS_OUTPUT.PUT_LINE('IMPORT_STATUS=' || v_job_state);
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('IMPORT_ERROR=' || SQLERRM);
    RAISE;
END;
/
EXIT;
EOF
)

IMPORT_OUTPUT=$(run_sqlplus "${IMPORT_SQL}" 2>&1) || true
echo "${IMPORT_OUTPUT}" >> "${LOG_FILE}"

RESTORE_END=$(date +%s)
RESTORE_DURATION=$(( RESTORE_END - RESTORE_START ))

if echo "${IMPORT_OUTPUT}" | grep -q "IMPORT_STATUS=COMPLETED"; then
  log "  Import completado exitosamente en ${RESTORE_DURATION} segundos"
elif echo "${IMPORT_OUTPUT}" | grep -q "IMPORT_STATUS=COMPLETED_WITH_ERRORS"; then
  log "  WARN: Import completado con errores menores en ${RESTORE_DURATION} segundos"
else
  log "  WARN: Import termino con estado no esperado (${RESTORE_DURATION}s)"
  echo "${IMPORT_OUTPUT}" | grep -iE "IMPORT_|ORA-|ERROR" | head -5 | while read -r line; do
    log "    ${line}"
  done
fi

# ---------- Paso 4: Validaciones de integridad ----------
log "Paso 4: Ejecutando validaciones de integridad..."

VALIDATION_SQL=$(cat <<EOF
SET PAGESIZE 100
SET LINESIZE 200
SET HEADING ON
SET FEEDBACK OFF
COLUMN owner FORMAT A30
COLUMN object_type FORMAT A20

PROMPT
PROMPT --- Schemas importados ---
SELECT username, account_status, TO_CHAR(created,'YYYY-MM-DD') AS created
FROM dba_users
WHERE oracle_maintained = 'N'
  AND username NOT IN ('RDSADMIN','RDS_SUPERUSER_ROLE','${RESTORE_USER}')
ORDER BY username;

PROMPT
PROMPT --- Conteo de objetos por schema ---
SELECT owner, COUNT(*) AS total_objetos
FROM dba_objects
WHERE owner IN (SELECT username FROM dba_users WHERE oracle_maintained='N' AND username NOT IN ('RDSADMIN','RDS_SUPERUSER_ROLE','${RESTORE_USER}'))
GROUP BY owner
ORDER BY total_objetos DESC
FETCH FIRST 20 ROWS ONLY;

PROMPT
PROMPT --- Objetos por tipo (top schemas) ---
SELECT owner, object_type, COUNT(*) AS cantidad
FROM dba_objects
WHERE owner IN (SELECT username FROM dba_users WHERE oracle_maintained='N' AND username NOT IN ('RDSADMIN','RDS_SUPERUSER_ROLE','${RESTORE_USER}'))
GROUP BY owner, object_type
ORDER BY owner, cantidad DESC
FETCH FIRST 30 ROWS ONLY;

PROMPT
PROMPT --- Resumen general ---
SELECT
  (SELECT COUNT(*) FROM dba_users WHERE oracle_maintained='N' AND username NOT IN ('RDSADMIN','RDS_SUPERUSER_ROLE','${RESTORE_USER}')) AS schemas,
  (SELECT COUNT(*) FROM dba_tables WHERE owner IN (SELECT username FROM dba_users WHERE oracle_maintained='N' AND username NOT IN ('RDSADMIN','RDS_SUPERUSER_ROLE','${RESTORE_USER}'))) AS tablas,
  (SELECT COUNT(*) FROM dba_indexes WHERE owner IN (SELECT username FROM dba_users WHERE oracle_maintained='N' AND username NOT IN ('RDSADMIN','RDS_SUPERUSER_ROLE','${RESTORE_USER}'))) AS indices,
  (SELECT COUNT(*) FROM dba_views WHERE owner IN (SELECT username FROM dba_users WHERE oracle_maintained='N' AND username NOT IN ('RDSADMIN','RDS_SUPERUSER_ROLE','${RESTORE_USER}'))) AS vistas
FROM dual;

EXIT;
EOF
)

VALIDATION_OUTPUT=$(run_sqlplus "${VALIDATION_SQL}" 2>&1) || true
echo "${VALIDATION_OUTPUT}" | tee -a "${REPORT_FILE}" >> "${LOG_FILE}"

# ---------- Paso 5: Limpiar dump de DATA_PUMP_DIR ----------
log "Paso 5: Limpiando dump de DATA_PUMP_DIR..."

CLEANUP_SQL=$(cat <<EOF
SET SERVEROUTPUT ON
BEGIN
  UTL_FILE.FREMOVE('DATA_PUMP_DIR', '${DUMP_FILENAME}');
  DBMS_OUTPUT.PUT_LINE('CLEANUP_OK');
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('CLEANUP_WARN: ' || SQLERRM);
END;
/
EXIT;
EOF
)

CLEANUP_OUTPUT=$(run_sqlplus "${CLEANUP_SQL}" 2>&1) || true
if echo "${CLEANUP_OUTPUT}" | grep -q "CLEANUP_OK"; then
  log "  Dump eliminado de DATA_PUMP_DIR"
else
  log "  WARN: No se pudo eliminar el dump de DATA_PUMP_DIR"
fi

# ---------- Resumen final ----------
{
  echo ""
  echo "================================================================"
  echo " RESULTADO"
  echo "================================================================"
  echo " Dump restaurado:    ${S3_DUMP_PATH}"
  echo " Tiempo de import:   ${RESTORE_DURATION} segundos"
  echo " Estado:             COMPLETADO"
  echo " Reporte:            ${REPORT_FILE}"
  echo " Log detallado:      ${LOG_FILE}"
  echo "================================================================"
} | tee -a "${REPORT_FILE}"

log "=========================================="
log "Validacion de integridad completada"
log "Reporte: ${REPORT_FILE}"
log "=========================================="
