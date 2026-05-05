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

log "Ejecutando Data Pump export via RDS..."

# Generar el script PL/SQL para ejecutar DBMS_DATAPUMP en RDS
DUMP_RDS_FILE="${DB_IDENTIFIER}_monthly_${TIMESTAMP}.dmp"
DATAPUMP_SQL=$(cat <<EOF
SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 200
DECLARE
  v_hdnl   NUMBER;
  v_status VARCHAR2(200);
  v_job_state VARCHAR2(30);
  v_sts    ku\$_Status;
BEGIN
  -- Crear job de Data Pump Export
  v_hdnl := DBMS_DATAPUMP.OPEN(
    operation => 'EXPORT',
    job_mode  => '$(if [[ -n "${SCHEMAS}" ]]; then echo "SCHEMA"; else echo "FULL"; fi)',
    job_name  => 'MONTHLY_EXPORT_${TIMESTAMP}'
  );

  -- Archivo de dump en el directorio DATA_PUMP_DIR de RDS
  DBMS_DATAPUMP.ADD_FILE(
    handle    => v_hdnl,
    filename  => '${DUMP_RDS_FILE}',
    directory => 'DATA_PUMP_DIR',
    filetype  => DBMS_DATAPUMP.KU\$_FILE_TYPE_DUMP_FILE
  );

  -- Log file
  DBMS_DATAPUMP.ADD_FILE(
    handle    => v_hdnl,
    filename  => '${DB_IDENTIFIER}_monthly_${TIMESTAMP}.log',
    directory => 'DATA_PUMP_DIR',
    filetype  => DBMS_DATAPUMP.KU\$_FILE_TYPE_LOG_FILE
  );

$(if [[ -n "${SCHEMAS}" ]]; then
  IFS=',' read -ra SCHEMA_ARR <<< "${SCHEMAS}"
  for schema in "${SCHEMA_ARR[@]}"; do
    echo "  DBMS_DATAPUMP.METADATA_FILTER(v_hdnl, 'SCHEMA_EXPR', 'IN (''${schema}'')');"
  done
fi)

  -- Compression
  DBMS_DATAPUMP.SET_PARAMETER(v_hdnl, 'COMPRESSION', 'ALL');

  -- Iniciar el job
  DBMS_DATAPUMP.START_JOB(v_hdnl);

  -- Esperar a que termine
  DBMS_DATAPUMP.WAIT_FOR_JOB(v_hdnl, v_job_state);
  DBMS_OUTPUT.PUT_LINE('Job finalizado con estado: ' || v_job_state);

  IF v_job_state != 'COMPLETED' THEN
    RAISE_APPLICATION_ERROR(-20001, 'Data Pump export fallo con estado: ' || v_job_state);
  END IF;
END;
/
EXIT;
EOF
)

echo "${DATAPUMP_SQL}" | sqlplus -S "${CONNECTION_STRING}" 2>&1 | tee -a "${LOG_FILE}"
SQLPLUS_RC=${PIPESTATUS[1]}

if [[ ${SQLPLUS_RC} -ne 0 ]]; then
  log "ERROR: Fallo el Data Pump export"
  exit 1
fi

log "Export completado en RDS. Transfiriendo dump a S3..."

# Transferir el dump desde RDS a S3 usando el procedimiento de RDS
TRANSFER_SQL=$(cat <<EOF
SET SERVEROUTPUT ON
BEGIN
  rdsadmin.rdsadmin_util.upload_to_s3(
    p_bucket_name    => '${S3_BUCKET}',
    p_s3_prefix      => 'oracle/${DB_IDENTIFIER}/monthly/',
    p_directory_name => 'DATA_PUMP_DIR',
    p_file_name      => '${DUMP_RDS_FILE}'
  );
  DBMS_OUTPUT.PUT_LINE('Upload a S3 completado');
END;
/
EXIT;
EOF
)

echo "${TRANSFER_SQL}" | sqlplus -S "${CONNECTION_STRING}" 2>&1 | tee -a "${LOG_FILE}"
SQLPLUS_RC=${PIPESTATUS[1]}

if [[ ${SQLPLUS_RC} -ne 0 ]]; then
  log "WARN: rdsadmin.upload_to_s3 no disponible. Descargando dump localmente..."

  # Alternativa: descargar el dump via UTL_FILE y subir manualmente
  # Descargar usando transferencia por bloques via SQL*Plus
  DOWNLOAD_SQL=$(cat <<EOF
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 32767 TRIMSPOOL ON
SPOOL ${DUMP_FILE_RAW}
SELECT * FROM TABLE(rdsadmin.rds_file_util.read_text_file('DATA_PUMP_DIR', '${DUMP_RDS_FILE}'));
SPOOL OFF
EXIT;
EOF
)

  # Si la descarga directa no es viable, usar el metodo de S3 integration
  log "Para usar este script, configure la integracion S3 en su instancia RDS Oracle."
  log "Ref: https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/oracle-s3-integration.html"
  log "Alternativa: use SELECT rdsadmin.rdsadmin_s3_tasks.upload_to_s3(...) FROM DUAL;"

  # Intentar con rdsadmin_s3_tasks (disponible en versiones mas recientes)
  TRANSFER_SQL2=$(cat <<EOF
SET SERVEROUTPUT ON
DECLARE
  v_task_id VARCHAR2(100);
BEGIN
  v_task_id := rdsadmin.rdsadmin_s3_tasks.upload_to_s3(
    p_bucket_name    => '${S3_BUCKET}',
    p_prefix         => 'oracle/${DB_IDENTIFIER}/monthly/',
    p_s3_prefix      => 'oracle/${DB_IDENTIFIER}/monthly/',
    p_directory_name => 'DATA_PUMP_DIR'
  );
  DBMS_OUTPUT.PUT_LINE('Task ID: ' || v_task_id);
END;
/
EXIT;
EOF
)

  echo "${TRANSFER_SQL2}" | sqlplus -S "${CONNECTION_STRING}" 2>&1 | tee -a "${LOG_FILE}"
  SQLPLUS_RC=${PIPESTATUS[1]}

  if [[ ${SQLPLUS_RC} -ne 0 ]]; then
    log "ERROR: No se pudo transferir el dump a S3. Configure la integracion S3 en RDS."
    exit 1
  fi
fi

# Limpiar el dump del directorio DATA_PUMP_DIR en RDS
CLEANUP_SQL=$(cat <<EOF
BEGIN
  UTL_FILE.FREMOVE('DATA_PUMP_DIR', '${DUMP_RDS_FILE}');
  UTL_FILE.FREMOVE('DATA_PUMP_DIR', '${DB_IDENTIFIER}_monthly_${TIMESTAMP}.log');
END;
/
EXIT;
EOF
)
echo "${CLEANUP_SQL}" | sqlplus -S "${CONNECTION_STRING}" 2>&1 | tee -a "${LOG_FILE}"

S3_KEY="oracle/${DB_IDENTIFIER}/monthly/${DUMP_RDS_FILE}"
log "Dump mensual Oracle completado: s3://${S3_BUCKET}/${S3_KEY}"
