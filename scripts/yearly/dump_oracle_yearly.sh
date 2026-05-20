#!/bin/bash
###############################################################################
# dump_oracle_yearly.sh - Dump anual de Oracle RDS → bucket long-term (8 años)
#
# Crontab: 0 2 10 1 * /opt/scripts/yearly/dump_oracle_yearly.sh
#
# Uso manual:
#   ./dump_oracle_yearly.sh
#
# Modos de export:
#   - SCHEMAS="" (vacio)        → FULL export (requiere DATAPUMP_EXP_FULL_DATABASE)
#   - SCHEMAS="SCHEMA1,SCHEMA2" → SCHEMA export (solo los schemas indicados)
#
# Prerequisitos:
#   - Oracle Instant Client con sqlplus instalado
#   - Integración S3 configurada en la instancia RDS Oracle
#   - Para FULL export: GRANT DATAPUMP_EXP_FULL_DATABASE TO <usuario>;
#
# ==============================================================================
# CONFIGURACION SSL/TCPS
# ==============================================================================
# Variable SSL_MODE controla el protocolo de conexion a Oracle:
#
#   "disable"  → Conexion TCP normal sin SSL.
#                Usar solo si la instancia RDS Oracle NO tiene SSL configurado.
#                Equivale a (PROTOCOL=TCP) en el TNS descriptor.
#
#   "require"  → Conexion TCPS (TCP con SSL) sin validar certificado.
#                Equivale a (PROTOCOL=TCPS) en el TNS descriptor.
#                Recomendado para la mayoría de casos con RDS Oracle SSL.
#
# Para HABILITAR SSL en RDS Oracle:
#   1. Crear/usar un Option Group con la opcion "SSL" agregada
#   2. Asociar el Option Group a la instancia RDS
#   3. Por defecto el puerto SSL es 2484, pero RDS Oracle puede usar 1521
#   4. Verificar el puerto SSL en RDS Console → Configuration → SSL_PORT
#
# Configurar variables en la seccion CONFIGURACION antes de usar.
###############################################################################
set -euo pipefail

# ======================== CONFIGURACION ========================
SCHEMAS=""  # Dejar vacio para FULL, o "SCHEMA1,SCHEMA2"
S3_BUCKET="${S3_BUCKET:-CHANGE_ME-dumps-long-term}"
AWS_REGION="${AWS_REGION:-us-east-1}"

# ----- SSL: Cambiar a "disable" si la RDS NO usa SSL -----
SSL_MODE="${SSL_MODE:-disable}"
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
# DB_PASS='CHANGE_ME'  # Usar comillas simples si tiene caracteres especiales
# DB_SERVICE="ORCL"
# ---------------------------------------------------------------

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
  rm -f /tmp/oracle_login_*.sql 2>/dev/null
}
trap cleanup EXIT

DB_IDENTIFIER="${DB_SERVICE}"
DUMP_RDS_FILE="${DB_IDENTIFIER}_yearly_${TIMESTAMP}.dmp"
DUMP_RDS_LOG="${DB_IDENTIFIER}_yearly_${TIMESTAMP}.log"
S3_PREFIX="oracle/${DB_IDENTIFIER}/yearly/"

# ============================================================
# Configuracion SSL/TCPS
# ============================================================
case "${SSL_MODE}" in
  disable)
    PROTOCOL="TCP"
    ;;
  require)
    PROTOCOL="TCPS"
    ;;
  *)
    echo "ERROR: SSL_MODE invalido: ${SSL_MODE}" >&2
    echo "Valores validos: disable | require" >&2
    exit 1
    ;;
esac

# Construir TNS connect descriptor con el protocolo correcto
TNS_CONNECT="(DESCRIPTION=(ADDRESS=(PROTOCOL=${PROTOCOL})(HOST=${DB_HOST})(PORT=${DB_PORT}))(CONNECT_DATA=(SERVICE_NAME=${DB_SERVICE})))"

# ==============================================================================
# Funcion: run_sqlplus
# Ejecuta SQL via sqlplus de forma segura (maneja passwords con caracteres especiales)
# ==============================================================================
run_sqlplus() {
  local sql_input="$1"
  local login_script
  login_script=$(mktemp /tmp/oracle_login_XXXXXX.sql)
  chmod 600 "${login_script}"

  cat > "${login_script}" <<EOSQL
CONNECT ${DB_USER}/"${DB_PASS}"@${TNS_CONNECT}
${sql_input}
EOSQL

  sqlplus -S -L /nolog @"${login_script}"
  local rc=$?
  rm -f "${login_script}"
  return ${rc}
}

# ==============================================================================
# Funcion: check_sqlplus_output
# Valida que el output de sqlplus no contenga errores ORA- o SP2-
# ==============================================================================
check_sqlplus_output() {
  local output="$1"
  local step_name="$2"

  if echo "${output}" | grep -qiE "^(ORA-|SP2-|ERROR)"; then
    log "ERROR en ${step_name}:"
    echo "${output}" | grep -iE "^(ORA-|SP2-|ERROR)" | while read -r line; do
      log "  ${line}"
    done
    return 1
  fi
  return 0
}

# ==============================================================================
# INICIO DEL DUMP
# ==============================================================================
log "=========================================="
log "Dump ANUAL Oracle RDS → bucket long-term (8 años)"
log "Host: ${DB_HOST}:${DB_PORT} | Service: ${DB_SERVICE}"
log "Protocol: ${PROTOCOL} (SSL_MODE=${SSL_MODE})"
if [[ -n "${SCHEMAS}" ]]; then
  log "Modo: SCHEMA (${SCHEMAS})"
else
  log "Modo: FULL (requiere DATAPUMP_EXP_FULL_DATABASE)"
fi
log "=========================================="

# ---------- Verificar conectividad ----------
log "Verificando conectividad..."
CONNECT_OUTPUT=$(run_sqlplus "SELECT 'CONNECTION_OK' FROM DUAL;
EXIT;" 2>&1) || true

if ! echo "${CONNECT_OUTPUT}" | grep -q "CONNECTION_OK"; then
  log "ERROR: No se pudo conectar a Oracle RDS"
  log "Output: ${CONNECT_OUTPUT}"
  exit 1
fi
log "Conectividad OK"

# ---------- Determinar modo de export ----------
if [[ -n "${SCHEMAS}" ]]; then
  EXPORT_MODE="SCHEMA"
  SCHEMA_FILTER=""
  IFS=',' read -ra SCHEMA_ARR <<< "${SCHEMAS}"
  for schema in "${SCHEMA_ARR[@]}"; do
    schema=$(echo "${schema}" | xargs)
    SCHEMA_FILTER="${SCHEMA_FILTER}  DBMS_DATAPUMP.METADATA_FILTER(v_hdnl, 'SCHEMA_EXPR', 'IN (''${schema}'')');"$'\n'
  done
else
  EXPORT_MODE="FULL"
  SCHEMA_FILTER=""
fi

# ---------- Ejecutar Data Pump Export ----------
log "Ejecutando Data Pump export (modo: ${EXPORT_MODE})..."

DATAPUMP_SQL=$(cat <<EOF
SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 200
DECLARE
  v_hdnl      NUMBER;
  v_job_state VARCHAR2(30);
BEGIN
  v_hdnl := DBMS_DATAPUMP.OPEN(
    operation => 'EXPORT',
    job_mode  => '${EXPORT_MODE}',
    job_name  => 'YEARLY_EXP_${TIMESTAMP}'
  );

  DBMS_DATAPUMP.ADD_FILE(
    handle    => v_hdnl,
    filename  => '${DUMP_RDS_FILE}',
    directory => 'DATA_PUMP_DIR',
    filetype  => DBMS_DATAPUMP.KU\$_FILE_TYPE_DUMP_FILE
  );

  DBMS_DATAPUMP.ADD_FILE(
    handle    => v_hdnl,
    filename  => '${DUMP_RDS_LOG}',
    directory => 'DATA_PUMP_DIR',
    filetype  => DBMS_DATAPUMP.KU\$_FILE_TYPE_LOG_FILE
  );

${SCHEMA_FILTER}
  DBMS_DATAPUMP.SET_PARAMETER(v_hdnl, 'COMPRESSION', 'ALL');

  DBMS_DATAPUMP.START_JOB(v_hdnl);
  DBMS_DATAPUMP.WAIT_FOR_JOB(v_hdnl, v_job_state);

  DBMS_OUTPUT.PUT_LINE('DATAPUMP_STATUS=' || v_job_state);

  IF v_job_state != 'COMPLETED' THEN
    RAISE_APPLICATION_ERROR(-20001, 'Data Pump export fallo: ' || v_job_state);
  END IF;
END;
/
EXIT;
EOF
)

DATAPUMP_OUTPUT=$(run_sqlplus "${DATAPUMP_SQL}" 2>&1) || true
echo "${DATAPUMP_OUTPUT}" >> "${LOG_FILE}"

if ! check_sqlplus_output "${DATAPUMP_OUTPUT}" "Data Pump Export"; then
  log "ERROR: Fallo el Data Pump export. Revise los privilegios del usuario."
  log "Para FULL export ejecute: GRANT DATAPUMP_EXP_FULL_DATABASE TO ${DB_USER};"
  log "Para SCHEMA export configure: SCHEMAS=\"SCHEMA1,SCHEMA2\""
  exit 1
fi

if ! echo "${DATAPUMP_OUTPUT}" | grep -q "DATAPUMP_STATUS=COMPLETED"; then
  log "ERROR: Data Pump no completo exitosamente"
  log "Output: ${DATAPUMP_OUTPUT}"
  exit 1
fi

log "Data Pump export completado exitosamente"

# ---------- Transferir dump a S3 via rdsadmin_s3_tasks ----------
log "Transfiriendo dump a S3: s3://${S3_BUCKET}/${S3_PREFIX}..."

TRANSFER_SQL=$(cat <<EOF
SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 200
DECLARE
  v_task_id VARCHAR2(100);
BEGIN
  v_task_id := rdsadmin.rdsadmin_s3_tasks.upload_to_s3(
    p_bucket_name    => '${S3_BUCKET}',
    p_prefix         => '${S3_PREFIX}',
    p_directory_name => 'DATA_PUMP_DIR'
  );
  DBMS_OUTPUT.PUT_LINE('S3_TASK_ID=' || v_task_id);
END;
/
EXIT;
EOF
)

TRANSFER_OUTPUT=$(run_sqlplus "${TRANSFER_SQL}" 2>&1) || true
echo "${TRANSFER_OUTPUT}" >> "${LOG_FILE}"

if ! check_sqlplus_output "${TRANSFER_OUTPUT}" "Upload a S3"; then
  log "ERROR: Fallo la transferencia a S3"
  log "Verifique que la integracion S3 esta configurada:"
  log "  1. Option Group con S3_INTEGRATION"
  log "  2. IAM Role asociado a la instancia RDS"
  log "  Ref: https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/oracle-s3-integration.html"
  exit 1
fi

# Extraer task ID
S3_TASK_ID=$(echo "${TRANSFER_OUTPUT}" | grep "S3_TASK_ID=" | sed 's/S3_TASK_ID=//')
log "Upload iniciado - Task ID: ${S3_TASK_ID}"

# Esperar a que el task complete (polling cada 10 segundos, max 5 minutos)
log "Esperando a que el upload complete..."
MAX_WAIT=300
ELAPSED=0
UPLOAD_DONE=false

while [[ ${ELAPSED} -lt ${MAX_WAIT} ]]; do
  sleep 10
  ELAPSED=$((ELAPSED + 10))

  STATUS_SQL=$(cat <<EOF
SET HEADING OFF FEEDBACK OFF PAGESIZE 0
SELECT text FROM TABLE(rdsadmin.rds_file_util.read_text_file('BDUMP', 'dbtask-${S3_TASK_ID}.log'));
EXIT;
EOF
)

  STATUS_OUTPUT=$(run_sqlplus "${STATUS_SQL}" 2>&1) || true

  if echo "${STATUS_OUTPUT}" | grep -qi "finished successfully"; then
    UPLOAD_DONE=true
    break
  elif echo "${STATUS_OUTPUT}" | grep -qi "error\|failed"; then
    log "ERROR: Upload a S3 fallo"
    log "${STATUS_OUTPUT}"
    exit 1
  fi
done

if [[ "${UPLOAD_DONE}" == "true" ]]; then
  log "Upload a S3 completado exitosamente"
else
  log "WARN: Timeout esperando upload (${MAX_WAIT}s). Verificar manualmente con Task ID: ${S3_TASK_ID}"
fi

# ---------- Limpiar archivos en DATA_PUMP_DIR ----------
log "Limpiando archivos temporales en RDS..."

CLEANUP_SQL=$(cat <<EOF
SET SERVEROUTPUT ON
BEGIN
  UTL_FILE.FREMOVE('DATA_PUMP_DIR', '${DUMP_RDS_FILE}');
  UTL_FILE.FREMOVE('DATA_PUMP_DIR', '${DUMP_RDS_LOG}');
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
echo "${CLEANUP_OUTPUT}" >> "${LOG_FILE}"

if echo "${CLEANUP_OUTPUT}" | grep -q "CLEANUP_OK"; then
  log "Archivos temporales eliminados de DATA_PUMP_DIR"
else
  log "WARN: No se pudieron eliminar todos los archivos temporales"
fi

log "=========================================="
log "Dump anual Oracle completado: s3://${S3_BUCKET}/${S3_PREFIX}${DUMP_RDS_FILE}"
log "=========================================="
