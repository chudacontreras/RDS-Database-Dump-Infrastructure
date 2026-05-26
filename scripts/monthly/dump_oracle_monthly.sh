#!/bin/bash
###############################################################################
# dump_oracle_monthly.sh - Dump mensual de Oracle RDS → bucket short-term (1 año)
#
# Crontab: 0 2 5 * * /opt/scripts/monthly/dump_oracle_monthly.sh
#
# Uso manual:
#   ./dump_oracle_monthly.sh
#
# Modos de export:
#   - SCHEMAS=""                → FULL export (requiere DATAPUMP_EXP_FULL_DATABASE)
#                                 Exporta TODA la instancia (incluye system schemas).
#   - SCHEMAS="ALL"             → Descubre y exporta TODOS los schemas de usuario
#                                 (excluye Oracle-maintained: SYS, SYSTEM, RDSADMIN, etc.)
#                                 Recomendado para garantizar backup completo sin requerir
#                                 el privilegio FULL_DATABASE.
#   - SCHEMAS="SCHEMA1,SCHEMA2" → SCHEMA export (solo los schemas indicados)
#
# Prerequisitos:
#   - Oracle Instant Client con sqlplus instalado
#   - Integración S3 configurada en la instancia RDS Oracle
#   - Para FULL export: GRANT DATAPUMP_EXP_FULL_DATABASE TO <usuario>;
#
# Configurar variables en la seccion CONFIGURACION antes de usar.
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
# Para SABER si tu RDS Oracle requiere SSL:
#   - Console RDS → tu instancia → Configuration → buscar "Option Group"
#   - Si el option group tiene la opcion "SSL", esta habilitado
###############################################################################
set -euo pipefail

# ======================== CONFIGURACION ========================
SCHEMAS="${SCHEMAS:-}"  # Vacio=FULL, "ALL"=todos los schemas, "S1,S2"=especificos. Override con env var.
S3_BUCKET="${S3_BUCKET:-CHANGE_ME-dumps-short-term}"
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
DB_HOST="${DB_HOST:-$(echo "${SECRET_JSON}" | jq -r '.host // empty')}"
DB_PORT="${DB_PORT:-$(echo "${SECRET_JSON}" | jq -r '.port // "1521"')}"
DB_USER="${DB_USER:-$(echo "${SECRET_JSON}" | jq -r '.username // empty')}"
DB_PASS="${DB_PASS:-$(echo "${SECRET_JSON}" | jq -r '.password // empty')}"
# IMPORTANTE: Los secrets gestionados por AWS RDS NO incluyen 'dbname' por defecto.
# Para Oracle el dbname corresponde al SERVICE_NAME (ej: ORCL, RDSQA).
# Si tu secret no lo tiene, defina DB_SERVICE aqui o exportela como variable de entorno:
#   DB_SERVICE=RDSQA ./dump_oracle_monthly.sh
DB_SERVICE="${DB_SERVICE:-$(echo "${SECRET_JSON}" | jq -r '.dbname // empty')}"
# ---------------------------------------------------------------

# ---------- OPCION 2: Credenciales hardcodeadas ----------------
# DB_HOST="CHANGE_ME.rds.amazonaws.com"
# DB_PORT="1521"
# DB_USER="admin"
# DB_PASS='CHANGE_ME'
# DB_SERVICE="ORCL"
# ---------------------------------------------------------------

# Validar que las variables criticas tengan valor
if [[ -z "${DB_HOST}" || -z "${DB_USER}" || -z "${DB_PASS}" || -z "${DB_SERVICE}" ]]; then
  echo "ERROR: Faltan credenciales requeridas. Verifique:" >&2
  [[ -z "${DB_HOST}" ]] && echo "  - DB_HOST esta vacio" >&2
  [[ -z "${DB_USER}" ]] && echo "  - DB_USER esta vacio" >&2
  [[ -z "${DB_PASS}" ]] && echo "  - DB_PASS esta vacio" >&2
  [[ -z "${DB_SERVICE}" ]] && echo "  - DB_SERVICE esta vacio (los secrets de AWS RDS no incluyen 'dbname'). Defina DB_SERVICE como variable de entorno: DB_SERVICE=ORCL ./script.sh" >&2
  exit 1
fi

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
  # Limpiar archivos temporales de login si quedaron
  rm -f /tmp/oracle_login_*.sql 2>/dev/null
}
trap cleanup EXIT

DB_IDENTIFIER="${DB_SERVICE}"
DUMP_RDS_FILE="${DB_IDENTIFIER}_monthly_${TIMESTAMP}.dmp"
DUMP_RDS_LOG="${DB_IDENTIFIER}_monthly_${TIMESTAMP}.log"
S3_PREFIX="oracle/${DB_IDENTIFIER}/monthly/"

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
# Usa archivo temporal con permisos 600 que se elimina inmediatamente despues
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
log "Dump MENSUAL Oracle RDS → bucket short-term"
log "Host: ${DB_HOST}:${DB_PORT} | Service: ${DB_SERVICE}"
log "Protocol: ${PROTOCOL} (SSL_MODE=${SSL_MODE})"
if [[ -z "${SCHEMAS}" ]]; then
  log "Modo: ALL SCHEMAS (auto-descubrimiento, SE2 compatible)"
elif [[ "${SCHEMAS}" == "ALL" ]]; then
  log "Modo: ALL SCHEMAS (auto-descubrimiento)"
else
  log "Modo: SCHEMA (${SCHEMAS})"
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
# SCHEMAS=""             → FULL export (todos los schemas excepto los de Oracle)
# SCHEMAS="ALL"          → Descubrir y exportar TODOS los schemas no-system
# SCHEMAS="USR1,USR2"    → Exportar solo los schemas indicados

# Validar valor de SCHEMAS para evitar errores comunes
case "${SCHEMAS^^}" in
  FULL)
    log "ERROR: SCHEMAS='FULL' no es un valor valido."
    log "  Para FULL export ejecute SIN la variable: ./dump_oracle_monthly.sh"
    log "  Para todos los schemas de usuario:  SCHEMAS=ALL ./dump_oracle_monthly.sh"
    log "  Para schemas especificos:           SCHEMAS=\"S1,S2\" ./dump_oracle_monthly.sh"
    exit 1
    ;;
esac

# ==============================================================================
# Oracle Standard Edition 2 NO soporta DBMS_DATAPUMP en modo FULL.
# Por eso, tanto SCHEMAS="" (FULL) como SCHEMAS="ALL" se resuelven igual:
# descubrir todos los schemas de usuario y exportarlos en modo SCHEMA.
# ==============================================================================

if [[ -z "${SCHEMAS}" || "${SCHEMAS}" == "ALL" ]]; then
  log "Descubriendo todos los schemas de usuario (SE2 no soporta modo FULL)..."

  DISCOVER_SCHEMAS_SQL="SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 200
SELECT username FROM dba_users
WHERE oracle_maintained = 'N'
  AND username NOT IN ('RDSADMIN', 'RDS_SUPERUSER_ROLE')
ORDER BY username;
EXIT;"

  DISCOVERED_OUTPUT=$(run_sqlplus "${DISCOVER_SCHEMAS_SQL}" 2>&1) || true

  if ! check_sqlplus_output "${DISCOVERED_OUTPUT}" "Listar schemas"; then
    log "ERROR: No se pudieron listar los schemas."
    log "Solucion: GRANT SELECT_CATALOG_ROLE TO ${DB_USER};"
    exit 1
  fi

  # Filtrar lineas vacias y extraer solo nombres de schema
  DISCOVERED_SCHEMAS=$(echo "${DISCOVERED_OUTPUT}" | grep -v '^$' | grep -vE '^(Connect|Last|SQL|Disconnect|Version)' | awk '{print $1}' | grep -v '^$')

  if [[ -z "${DISCOVERED_SCHEMAS}" ]]; then
    log "ERROR: No se encontraron schemas de usuario para respaldar"
    exit 1
  fi

  SCHEMA_COUNT=$(echo "${DISCOVERED_SCHEMAS}" | wc -l | xargs)
  log "Schemas encontrados: ${SCHEMA_COUNT}"

  # Construir lista IN ('S1','S2','S3',...) para METADATA_FILTER
  SCHEMA_IN_LIST=$(echo "${DISCOVERED_SCHEMAS}" | awk '{printf "'\''%s'\'',",$1}' | sed 's/,$//')
  EXPORT_MODE="SCHEMA"
  SCHEMA_FILTER="  DBMS_DATAPUMP.METADATA_FILTER(v_hdnl, 'SCHEMA_LIST', '${SCHEMA_IN_LIST}');"

else
  # Schemas especificos proporcionados por el usuario
  EXPORT_MODE="SCHEMA"
  IFS=',' read -ra SCHEMA_ARR <<< "${SCHEMAS}"
  SCHEMA_IN_LIST=""
  for schema in "${SCHEMA_ARR[@]}"; do
    schema=$(echo "${schema}" | xargs | tr '[:lower:]' '[:upper:]')
    SCHEMA_IN_LIST="${SCHEMA_IN_LIST}'${schema}',"
  done
  SCHEMA_IN_LIST="${SCHEMA_IN_LIST%,}"  # quitar ultima coma
  SCHEMA_FILTER="  DBMS_DATAPUMP.METADATA_FILTER(v_hdnl, 'SCHEMA_LIST', '${SCHEMA_IN_LIST}');"
  log "Schemas a exportar: ${SCHEMAS}"
fi

# ---------- Ejecutar Data Pump Export ----------
log "Ejecutando Data Pump export (modo: ${EXPORT_MODE})..."

# Generar nombre de job unico (max 30 chars en Oracle)
JOB_NAME="EXP_$(echo "${TIMESTAMP}" | tail -c 16)"

# Limpiar jobs huerfanos previos que pudieron quedar de ejecuciones fallidas
CLEANUP_JOBS_SQL=$(cat <<EOF
SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 200
DECLARE
  v_state VARCHAR2(30);
BEGIN
  -- Intentar detener y eliminar jobs huerfanos del mismo usuario
  FOR rec IN (
    SELECT owner_name, job_name, state
    FROM dba_datapump_jobs
    WHERE owner_name = USER
      AND state IN ('NOT RUNNING', 'DEFINING')
      AND job_name LIKE 'EXP_%'
  ) LOOP
    BEGIN
      DBMS_DATAPUMP.ATTACH(job_name => rec.job_name, job_owner => rec.owner_name);
      DBMS_DATAPUMP.STOP_JOB(DBMS_DATAPUMP.ATTACH(job_name => rec.job_name, job_owner => rec.owner_name), immediate => 1);
    EXCEPTION
      WHEN OTHERS THEN NULL;
    END;
    BEGIN
      EXECUTE IMMEDIATE 'DROP TABLE ' || USER || '."' || rec.job_name || '" PURGE';
    EXCEPTION
      WHEN OTHERS THEN NULL;
    END;
    DBMS_OUTPUT.PUT_LINE('Limpiado job huerfano: ' || rec.job_name);
  END LOOP;
END;
/
EXIT;
EOF
)

CLEANUP_OUTPUT=$(run_sqlplus "${CLEANUP_JOBS_SQL}" 2>&1) || true
if echo "${CLEANUP_OUTPUT}" | grep -q "Limpiado job"; then
  log "Se limpiaron jobs huerfanos de ejecuciones previas"
  echo "${CLEANUP_OUTPUT}" | grep "Limpiado" >> "${LOG_FILE}"
fi

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
    job_name  => '${JOB_NAME}'
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

  -- NOTA: COMPRESSION=ALL requiere Enterprise Edition (Advanced Compression).
  -- En Standard Edition 2 usar METADATA_ONLY o no comprimir.
  DBMS_DATAPUMP.SET_PARAMETER(v_hdnl, 'COMPRESSION', 'METADATA_ONLY');

  DBMS_DATAPUMP.START_JOB(v_hdnl);
  DBMS_DATAPUMP.WAIT_FOR_JOB(v_hdnl, v_job_state);

  DBMS_OUTPUT.PUT_LINE('DATAPUMP_STATUS=' || v_job_state);

  IF v_job_state != 'COMPLETED' THEN
    RAISE_APPLICATION_ERROR(-20001, 'Data Pump export fallo: ' || v_job_state);
  END IF;
EXCEPTION
  WHEN OTHERS THEN
    DBMS_OUTPUT.PUT_LINE('DATAPUMP_ERROR_CODE=' || SQLCODE);
    DBMS_OUTPUT.PUT_LINE('DATAPUMP_ERROR_MSG=' || SQLERRM);
    DBMS_OUTPUT.PUT_LINE('DATAPUMP_ERROR_STACK=' || DBMS_UTILITY.FORMAT_ERROR_STACK);
    DBMS_OUTPUT.PUT_LINE('DATAPUMP_ERROR_BACKTRACE=' || DBMS_UTILITY.FORMAT_ERROR_BACKTRACE);
    RAISE;
END;
/
EXIT;
EOF
)

DATAPUMP_OUTPUT=$(run_sqlplus "${DATAPUMP_SQL}" 2>&1) || true
echo "${DATAPUMP_OUTPUT}" >> "${LOG_FILE}"

# Validar output
if ! check_sqlplus_output "${DATAPUMP_OUTPUT}" "Data Pump Export"; then
  log "ERROR: Fallo el Data Pump export."

  # Mostrar diagnostico detallado si esta disponible
  if echo "${DATAPUMP_OUTPUT}" | grep -q "DATAPUMP_ERROR_MSG"; then
    log "Detalle del error:"
    echo "${DATAPUMP_OUTPUT}" | grep "DATAPUMP_ERROR" | while read -r line; do
      log "  ${line}"
    done
  fi

  # Diagnostico especifico por codigo de error
  if echo "${DATAPUMP_OUTPUT}" | grep -q "ORA-39006"; then
    log "DIAGNOSTICO: ORA-39006 = Error interno de Data Pump."
    log "  Posible causa: la version Standard Edition 2 no soporta FULL export."
    log "  Solucion: usar SCHEMAS=ALL o SCHEMAS=\"SCHEMA1,SCHEMA2\""
  elif echo "${DATAPUMP_OUTPUT}" | grep -q "ORA-39002"; then
    log "DIAGNOSTICO: ORA-39002 = Operacion invalida."
    log "  Posibles causas:"
    log "    1. Falta DATAPUMP_EXP_FULL_DATABASE (verificar con conectar_oracle.sh)"
    log "    2. Oracle Standard Edition 2 no soporta FULL export via DBMS_DATAPUMP"
    log "    3. Job con el mismo nombre ya existe (se intento limpiar automaticamente)"
    log "  Solucion: probar con SCHEMAS=ALL o verificar la edicion de Oracle:"
    log "    SELECT banner FROM v\$version;"
  fi

  log "Para FULL export: GRANT DATAPUMP_EXP_FULL_DATABASE TO ${DB_USER};"
  log "Para SCHEMA export: SCHEMAS=\"SCHEMA1,SCHEMA2\" ./dump_oracle_monthly.sh"
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
log "Dump mensual Oracle completado: s3://${S3_BUCKET}/${S3_PREFIX}${DUMP_RDS_FILE}"
log "=========================================="
