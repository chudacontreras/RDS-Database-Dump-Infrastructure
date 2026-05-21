#!/bin/bash
###############################################################################
# conectar_postgresql.sh - Utilidad para conectar a PostgreSQL RDS y validar
#                          databases, usuarios, roles y permisos.
#
# Uso:
#   ./conectar_postgresql.sh                     # Usa SECRET_NAME por defecto
#   SECRET_NAME=mi-secret ./conectar_postgresql.sh
#   ./conectar_postgresql.sh mi-secret           # Pasar secret como argumento
#
# Variables de entorno soportadas:
#   SECRET_NAME    - Nombre/ARN del secret en Secrets Manager
#   AWS_REGION     - Region AWS (default: us-east-1)
#   SSL_MODE       - disable | require | verify-ca | verify-full (default: require)
#   DB_HOST,DB_PORT,DB_USER,DB_PASS,DB_NAME - Override individual de credenciales
#
# Salida: muestra info de bases, usuarios, roles y permisos.
###############################################################################
set -euo pipefail

# ======================== CONFIGURACION ========================
SECRET_NAME="${SECRET_NAME:-${1:-postgresql/rds/credentials}}"
AWS_REGION="${AWS_REGION:-us-east-1}"
SSL_MODE="${SSL_MODE:-require}"
SSL_CA_CERT="${SSL_CA_CERT:-/etc/ssl/certs/rds-global-bundle.pem}"

# Directorio donde se guardan los reportes de auditoria
AUDIT_DIR="${AUDIT_DIR:-./audit-reports}"
# ===============================================================

# Crear directorio de auditoria
mkdir -p "${AUDIT_DIR}"

# Archivo de auditoria con timestamp
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
AUDIT_FILE="${AUDIT_DIR}/audit_postgresql_${TIMESTAMP}.txt"

# Funcion para imprimir tanto en consola como en archivo de auditoria
audit_log() {
  echo "$@" | tee -a "${AUDIT_FILE}"
}

# Header del reporte de auditoria
{
  echo "================================================================"
  echo " REPORTE DE AUDITORIA - POSTGRESQL RDS"
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

# ---------- Validar herramientas requeridas ------------------
for tool in aws jq psql; do
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

  if echo "${SECRET_JSON}" | grep -qi "Access to KMS is not allowed\|kms:Decrypt"; then
    audit_log ""
    audit_log "DIAGNOSTICO: El secret esta cifrado con una KMS key customizada (CMK)"
    audit_log "y el IAM role actual no tiene permiso 'kms:Decrypt' sobre esa key."
    audit_log ""
    audit_log "Para identificar la KMS key del secret:"
    audit_log "  aws secretsmanager describe-secret --secret-id ${SECRET_NAME} \\"
    audit_log "    --region ${AWS_REGION} --query KmsKeyId"
  elif echo "${SECRET_JSON}" | grep -qi "ResourceNotFoundException"; then
    audit_log ""
    audit_log "DIAGNOSTICO: El secret '${SECRET_NAME}' no existe en la region ${AWS_REGION}."
  fi

  audit_log ""
  audit_log "Reporte guardado en: ${AUDIT_FILE}"
  exit 1
}

DB_USER="${DB_USER:-$(echo "${SECRET_JSON}" | jq -r '.username // empty')}"
DB_PASS="${DB_PASS:-$(echo "${SECRET_JSON}" | jq -r '.password // empty')}"
DB_HOST="${DB_HOST:-$(echo "${SECRET_JSON}" | jq -r '.host // empty')}"
DB_PORT="${DB_PORT:-$(echo "${SECRET_JSON}" | jq -r '.port // "5432"')}"
# Para validacion conectamos a 'postgres' (siempre existe). Permite override con DB_NAME.
DB_NAME="${DB_NAME:-$(echo "${SECRET_JSON}" | jq -r '.dbname // "postgres"')}"

# ---------- Validar variables criticas -----------------------
for var in DB_USER DB_PASS DB_HOST; do
  if [[ -z "${!var}" ]]; then
    echo "ERROR: ${var} esta vacio" >&2
    exit 1
  fi
done

# ---------- Configurar SSL -----------------------------------
case "${SSL_MODE}" in
  disable|require|verify-ca|verify-full)
    export PGSSLMODE="${SSL_MODE}"
    ;;
  *)
    echo "ERROR: SSL_MODE invalido: '${SSL_MODE}'" >&2
    echo "Valores validos: disable | require | verify-ca | verify-full" >&2
    exit 1
    ;;
esac

if [[ "${SSL_MODE}" == "verify-ca" || "${SSL_MODE}" == "verify-full" ]]; then
  if [[ ! -f "${SSL_CA_CERT}" ]]; then
    echo "→ Descargando certificado CA de AWS RDS..."
    sudo mkdir -p "$(dirname "${SSL_CA_CERT}")"
    sudo curl -fsSL -o "${SSL_CA_CERT}" \
      https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem || {
      echo "ERROR: No se pudo descargar el certificado CA" >&2
      exit 1
    }
    sudo chmod 644 "${SSL_CA_CERT}"
  fi
  export PGSSLROOTCERT="${SSL_CA_CERT}"
fi

# ---------- Cleanup en EXIT ----------------------------------
cleanup() {
  unset PGPASSWORD DB_PASS
}
trap cleanup EXIT

export PGPASSWORD="${DB_PASS}"

# ---------- Funcion helper para ejecutar SQL -----------------
run_sql() {
  local title="$1"
  local sql="$2"

  {
    echo ""
    echo "============================================================"
    echo " ${title}"
    echo "============================================================"
  } | tee -a "${AUDIT_FILE}"

  psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" \
    --pset=pager=off -c "${sql}" 2>&1 | tee -a "${AUDIT_FILE}" || \
    echo "  (error ejecutando query)" | tee -a "${AUDIT_FILE}"
}

# ---------- Verificar conectividad ---------------------------
audit_log "→ Conectando a ${DB_HOST}:${DB_PORT}/${DB_NAME} (sslmode=${SSL_MODE})..."

psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" \
  -c "SELECT 1;" > /dev/null 2>&1 || {
  audit_log "ERROR: No se pudo conectar a PostgreSQL RDS"
  audit_log "Verifique credenciales y SSL_MODE (actual: ${SSL_MODE})"
  audit_log ""
  audit_log "Reporte guardado en: ${AUDIT_FILE}"
  exit 1
}

# ============================================================
# CONSULTAS DE VALIDACION
# ============================================================

run_sql "INFORMACION DE LA INSTANCIA" "
SELECT
  current_database()                        AS database,
  current_user                              AS usuario_actual,
  inet_server_addr()::text                  AS server_ip,
  inet_server_port()                        AS server_port,
  version()                                 AS version;
"

run_sql "RESUMEN DE BASES DE DATOS" "
SELECT
  COUNT(*) FILTER (WHERE datistemplate = false AND datallowconn = true AND datname NOT IN ('rdsadmin'))
    AS bases_usuario,
  COUNT(*) FILTER (WHERE datistemplate = true)
    AS plantillas,
  COUNT(*) AS total
FROM pg_database;
"

run_sql "BASES DE DATOS DE USUARIO" "
SELECT
  d.datname AS database,
  pg_catalog.pg_get_userbyid(d.datdba) AS owner,
  pg_catalog.pg_encoding_to_char(d.encoding) AS encoding,
  pg_size_pretty(pg_database_size(d.datname)) AS size
FROM pg_database d
WHERE d.datistemplate = false
  AND d.datallowconn = true
  AND d.datname NOT IN ('rdsadmin')
ORDER BY pg_database_size(d.datname) DESC;
"

run_sql "USUARIOS Y ROLES" "
SELECT
  rolname,
  rolsuper        AS superuser,
  rolcreaterole   AS create_role,
  rolcreatedb     AS create_db,
  rolcanlogin     AS login,
  rolreplication  AS replication
FROM pg_roles
WHERE rolname NOT LIKE 'pg_%'
  AND rolname NOT LIKE 'rds%'
ORDER BY rolname;
"

run_sql "ROLES DEL USUARIO ACTUAL" "
SELECT r.rolname AS role_otorgado
FROM pg_auth_members m
JOIN pg_roles r ON r.oid = m.roleid
JOIN pg_roles u ON u.oid = m.member
WHERE u.rolname = current_user
ORDER BY r.rolname;
"

run_sql "PRIVILEGIOS DEL USUARIO ACTUAL" "
SELECT
  current_setting('is_superuser')::boolean AS is_superuser,
  pg_has_role(current_user, 'rds_superuser', 'MEMBER') AS is_rds_superuser,
  has_database_privilege(current_user, current_database(), 'CONNECT') AS connect,
  has_database_privilege(current_user, current_database(), 'CREATE')  AS create_obj;
"

run_sql "PARAMETROS SSL" "
SELECT name, setting
FROM pg_settings
WHERE name IN ('ssl', 'rds.force_ssl', 'rds.rds_superuser_reserved_connections')
ORDER BY name;
"

run_sql "EXTENSIONES INSTALADAS" "
SELECT extname, extversion
FROM pg_extension
ORDER BY extname;
"

echo ""
echo "============================================================"
echo " Validacion completada"
echo "============================================================"

# Footer del reporte
{
  echo ""
  echo "================================================================"
  echo " Reporte completado: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo " Archivo: ${AUDIT_FILE}"
  echo " Estado: EXITOSO"
  echo "================================================================"
} | tee -a "${AUDIT_FILE}"

echo ""
echo "Reporte guardado en: ${AUDIT_FILE}"
