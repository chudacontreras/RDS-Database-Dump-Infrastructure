#!/bin/bash
###############################################################################
# conectar_oracle.sh - Utilidad para conectar a Oracle RDS y validar
#                      schemas, usuarios y permisos.
#
# Uso:
#   ./conectar_oracle.sh                    # Usa SECRET_NAME por defecto
#   SECRET_NAME=mi-secret ./conectar_oracle.sh
#   ./conectar_oracle.sh mi-secret          # Pasar secret como argumento
#
# Variables de entorno soportadas:
#   SECRET_NAME    - Nombre/ARN del secret en Secrets Manager
#   AWS_REGION     - Region AWS (default: us-east-1)
#   SSL_MODE       - "disable" (TCP) o "require" (TCPS) (default: disable)
#   DB_HOST,DB_PORT,DB_USER,DB_PASS,DB_SERVICE - Override individual de credenciales
#
# Salida: muestra info de schemas, usuarios y permisos de la instancia.
###############################################################################
set -euo pipefail

# ======================== CONFIGURACION ========================
SECRET_NAME="${SECRET_NAME:-${1:-oracle/rds/credentials}}"
AWS_REGION="${AWS_REGION:-us-east-1}"
SSL_MODE="${SSL_MODE:-disable}"   # "disable" (TCP) o "require" (TCPS)

# Directorio donde se guardan los reportes de auditoria
AUDIT_DIR="${AUDIT_DIR:-./audit-reports}"
# ===============================================================

# Crear directorio de auditoria
mkdir -p "${AUDIT_DIR}"

# Archivo de auditoria con timestamp
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
AUDIT_FILE="${AUDIT_DIR}/audit_oracle_${TIMESTAMP}.txt"

# Funcion para imprimir tanto en consola como en archivo de auditoria
audit_log() {
  echo "$@" | tee -a "${AUDIT_FILE}"
}

# Header del reporte de auditoria
{
  echo "================================================================"
  echo " REPORTE DE AUDITORIA - ORACLE RDS"
  echo "================================================================"
  echo " Fecha:            $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo " Ejecutado por:    $(whoami)@$(hostname)"
  echo " Caller identity:  $(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null || echo 'N/A')"
  echo " Secret usado:     ${SECRET_NAME}"
  echo " Region AWS:       ${AWS_REGION}"
  echo " SSL Mode:         ${SSL_MODE}"
  echo " Archivo reporte:  ${AUDIT_FILE}"
  echo "================================================================"
  echo ""
} | tee "${AUDIT_FILE}"

# ---------- Detectar Oracle Instant Client automaticamente ----
ORACLE_LIB=$(ls -d /usr/lib/oracle/*/client64/lib 2>/dev/null | sort -V | tail -1 || true)
if [[ -n "${ORACLE_LIB}" ]]; then
  export LD_LIBRARY_PATH="${ORACLE_LIB}:${LD_LIBRARY_PATH:-}"
  export PATH="$(dirname "${ORACLE_LIB}")/bin:${PATH}"
fi

# ---------- Validar herramientas requeridas ------------------
for tool in aws jq sqlplus; do
  command -v "${tool}" >/dev/null 2>&1 || {
    echo "ERROR: '${tool}' no esta instalado o no esta en PATH" >&2
    exit 1
  }
done

# ---------- Recuperar credenciales ---------------------------
audit_log "→ Recuperando credenciales desde Secrets Manager: ${SECRET_NAME}"
SECRET_JSON=$(aws secretsmanager get-secret-value \
  --secret-id "${SECRET_NAME}" \
  --region "${AWS_REGION}" \
  --query 'SecretString' \
  --output text 2>&1) || {
  audit_log "ERROR: No se pudo recuperar el secret. Detalle:"
  audit_log "${SECRET_JSON}"

  # Diagnostico especifico para errores comunes
  if echo "${SECRET_JSON}" | grep -qi "Access to KMS is not allowed\|kms:Decrypt"; then
    audit_log ""
    audit_log "DIAGNOSTICO: El secret esta cifrado con una KMS key customizada (CMK)"
    audit_log "y el IAM role actual no tiene permiso 'kms:Decrypt' sobre esa key."
    audit_log ""
    audit_log "Para identificar la KMS key del secret:"
    audit_log "  aws secretsmanager describe-secret --secret-id ${SECRET_NAME} \\"
    audit_log "    --region ${AWS_REGION} --query KmsKeyId"
  elif echo "${SECRET_JSON}" | grep -qi "AccessDeniedException"; then
    audit_log ""
    audit_log "DIAGNOSTICO: El IAM role no tiene permiso 'secretsmanager:GetSecretValue'"
    audit_log "sobre el secret '${SECRET_NAME}'."
  elif echo "${SECRET_JSON}" | grep -qi "ResourceNotFoundException"; then
    audit_log ""
    audit_log "DIAGNOSTICO: El secret '${SECRET_NAME}' no existe en la region ${AWS_REGION}."
    audit_log "Verifique con: aws secretsmanager list-secrets --region ${AWS_REGION}"
  fi

  audit_log ""
  audit_log "Reporte guardado en: ${AUDIT_FILE}"
  exit 1
}

DB_USER="${DB_USER:-$(echo "${SECRET_JSON}" | jq -r '.username // empty')}"
DB_PASS="${DB_PASS:-$(echo "${SECRET_JSON}" | jq -r '.password // empty')}"
DB_HOST="${DB_HOST:-$(echo "${SECRET_JSON}" | jq -r '.host // empty')}"
DB_PORT="${DB_PORT:-$(echo "${SECRET_JSON}" | jq -r '.port // "1521"')}"
DB_SERVICE="${DB_SERVICE:-$(echo "${SECRET_JSON}" | jq -r '.dbname // empty')}"

# ---------- Validar variables criticas -----------------------
for var in DB_USER DB_PASS DB_HOST DB_SERVICE; do
  if [[ -z "${!var}" ]]; then
    echo "ERROR: ${var} esta vacio." >&2
    if [[ "${var}" == "DB_SERVICE" ]]; then
      echo "  Los secrets de AWS RDS no incluyen 'dbname' por defecto." >&2
      echo "  Defina DB_SERVICE como variable de entorno: DB_SERVICE=ORCL ./conectar_oracle.sh" >&2
    fi
    exit 1
  fi
done

# ---------- Determinar protocolo SSL -------------------------
case "${SSL_MODE}" in
  disable) PROTOCOL="TCP" ;;
  require) PROTOCOL="TCPS" ;;
  *)
    echo "ERROR: SSL_MODE invalido: '${SSL_MODE}'. Usar 'disable' o 'require'." >&2
    exit 1
    ;;
esac

TNS_CONNECT="(DESCRIPTION=(ADDRESS=(PROTOCOL=${PROTOCOL})(HOST=${DB_HOST})(PORT=${DB_PORT}))(CONNECT_DATA=(SERVICE_NAME=${DB_SERVICE})))"

# ---------- Crear archivo temporal de login seguro -----------
LOGIN_SCRIPT=$(mktemp /tmp/oracle_conn_XXXXXX.sql)
chmod 600 "${LOGIN_SCRIPT}"

cleanup() {
  rm -f "${LOGIN_SCRIPT}"
  unset DB_PASS
}
trap cleanup EXIT

# ---------- Construir SQL de validacion ----------------------
cat > "${LOGIN_SCRIPT}" <<EOSQL
CONNECT ${DB_USER}/"${DB_PASS}"@${TNS_CONNECT}
SET PAGESIZE 100
SET LINESIZE 200
SET FEEDBACK OFF
SET HEADING ON
SET TRIMSPOOL ON
COLUMN username FORMAT A30
COLUMN account_status FORMAT A20
COLUMN role FORMAT A30
COLUMN granted_role FORMAT A30
COLUMN privilege FORMAT A40
COLUMN owner FORMAT A20

PROMPT
PROMPT ============================================================
PROMPT  CONEXION ESTABLECIDA
PROMPT ============================================================
SELECT 'Database: ' || sys_context('USERENV','DB_NAME')      AS info FROM dual
UNION ALL
SELECT 'Service:  ' || sys_context('USERENV','SERVICE_NAME') FROM dual
UNION ALL
SELECT 'Host:     ' || sys_context('USERENV','SERVER_HOST')  FROM dual
UNION ALL
SELECT 'Usuario:  ' || sys_context('USERENV','SESSION_USER') FROM dual
UNION ALL
SELECT 'Version:  ' || (SELECT banner FROM v\$version WHERE rownum=1) FROM dual;

PROMPT
PROMPT ============================================================
PROMPT  RESUMEN DE SCHEMAS
PROMPT ============================================================
SELECT
  COUNT(*) AS total_schemas,
  SUM(CASE WHEN oracle_maintained='N' THEN 1 ELSE 0 END) AS schemas_usuario,
  SUM(CASE WHEN oracle_maintained='Y' THEN 1 ELSE 0 END) AS schemas_oracle
FROM dba_users;

PROMPT
PROMPT ============================================================
PROMPT  SCHEMAS DE USUARIO (oracle_maintained = 'N')
PROMPT ============================================================
SELECT
  username,
  account_status,
  TO_CHAR(created, 'YYYY-MM-DD') AS created
FROM dba_users
WHERE oracle_maintained = 'N'
ORDER BY username;

PROMPT
PROMPT ============================================================
PROMPT  ROLES DEL USUARIO ACTUAL (${DB_USER})
PROMPT ============================================================
SELECT granted_role, admin_option, default_role
FROM user_role_privs
ORDER BY granted_role;

PROMPT
PROMPT ============================================================
PROMPT  PRIVILEGIOS DE SISTEMA DEL USUARIO ACTUAL
PROMPT ============================================================
SELECT privilege, admin_option
FROM user_sys_privs
ORDER BY privilege;

PROMPT
PROMPT ============================================================
PROMPT  PRIVILEGIOS RELEVANTES PARA DUMP/EXPORT
PROMPT ============================================================
SELECT privilege || ' (system)' AS tiene
FROM user_sys_privs
WHERE privilege IN (
  'EXP_FULL_DATABASE',
  'IMP_FULL_DATABASE',
  'DATAPUMP_EXP_FULL_DATABASE',
  'DATAPUMP_IMP_FULL_DATABASE',
  'CREATE ANY DIRECTORY',
  'READ ANY TABLE',
  'SELECT ANY DICTIONARY'
)
UNION ALL
SELECT granted_role || ' (role)'
FROM user_role_privs
WHERE granted_role IN (
  'EXP_FULL_DATABASE',
  'IMP_FULL_DATABASE',
  'DATAPUMP_EXP_FULL_DATABASE',
  'DATAPUMP_IMP_FULL_DATABASE',
  'SELECT_CATALOG_ROLE',
  'DBA',
  'RDS_SUPERUSER_ROLE'
)
ORDER BY 1;

PROMPT
PROMPT ============================================================
PROMPT  TOP 10 OBJETOS POR SCHEMA DE USUARIO
PROMPT ============================================================
SELECT owner, COUNT(*) AS total_objetos
FROM dba_objects
WHERE owner IN (SELECT username FROM dba_users WHERE oracle_maintained='N')
GROUP BY owner
ORDER BY total_objetos DESC
FETCH FIRST 10 ROWS ONLY;

PROMPT
PROMPT ============================================================
PROMPT  INTEGRACION S3 (rdsadmin_s3_tasks disponible?)
PROMPT ============================================================
SELECT
  CASE
    WHEN COUNT(*) > 0 THEN 'SI - Integracion S3 habilitada'
    ELSE 'NO - Falta opcion S3_INTEGRATION en el option group'
  END AS s3_integration_status
FROM all_procedures
WHERE owner = 'RDSADMIN'
  AND object_name = 'RDSADMIN_S3_TASKS';

PROMPT
PROMPT ============================================================
PROMPT  Validacion completada
PROMPT ============================================================
EXIT;
EOSQL

# ---------- Ejecutar -----------------------------------------
audit_log "→ Conectando a ${DB_HOST}:${DB_PORT}/${DB_SERVICE} (${PROTOCOL})..."
audit_log ""

# Ejecutar sqlplus y enviar salida tanto a consola como al archivo de auditoria
sqlplus -S -L /nolog @"${LOGIN_SCRIPT}" 2>&1 | tee -a "${AUDIT_FILE}"
SQLPLUS_RC=${PIPESTATUS[0]}

# Footer del reporte
{
  echo ""
  echo "================================================================"
  echo " Reporte completado: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo " Archivo: ${AUDIT_FILE}"
  if [[ ${SQLPLUS_RC} -eq 0 ]]; then
    echo " Estado: EXITOSO"
  else
    echo " Estado: FALLO (codigo ${SQLPLUS_RC})"
  fi
  echo "================================================================"
} | tee -a "${AUDIT_FILE}"

echo ""
echo "Reporte guardado en: ${AUDIT_FILE}"
exit ${SQLPLUS_RC}
