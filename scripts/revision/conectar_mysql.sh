#!/bin/bash
###############################################################################
# conectar_mysql.sh - Utilidad para conectar a MySQL RDS y validar
#                     databases, usuarios y permisos.
#
# Uso:
#   ./conectar_mysql.sh                     # Usa SECRET_NAME por defecto
#   SECRET_NAME=mi-secret ./conectar_mysql.sh
#   ./conectar_mysql.sh mi-secret           # Pasar secret como argumento
#
# Variables de entorno soportadas:
#   SECRET_NAME    - Nombre/ARN del secret en Secrets Manager
#   AWS_REGION     - Region AWS (default: us-east-1)
#   SSL_MODE       - DISABLED|PREFERRED|REQUIRED|VERIFY_CA|VERIFY_IDENTITY (default: REQUIRED)
#   DB_HOST,DB_PORT,DB_USER,DB_PASS - Override individual de credenciales
#
# Salida: muestra info de bases, usuarios y permisos.
###############################################################################
set -euo pipefail

# ======================== CONFIGURACION ========================
SECRET_NAME="${SECRET_NAME:-${1:-mysql/rds/credentials}}"
AWS_REGION="${AWS_REGION:-us-east-1}"
SSL_MODE="${SSL_MODE:-REQUIRED}"
SSL_CA_CERT="${SSL_CA_CERT:-/etc/ssl/certs/rds-global-bundle.pem}"

# Directorio donde se guardan los reportes de auditoria
AUDIT_DIR="${AUDIT_DIR:-./audit-reports}"
# ===============================================================

# Crear directorio de auditoria
mkdir -p "${AUDIT_DIR}"

# Archivo de auditoria con timestamp
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
AUDIT_FILE="${AUDIT_DIR}/audit_mysql_${TIMESTAMP}.txt"

# Funcion para imprimir tanto en consola como en archivo de auditoria
audit_log() {
  echo "$@" | tee -a "${AUDIT_FILE}"
}

# Header del reporte de auditoria
{
  echo "================================================================"
  echo " REPORTE DE AUDITORIA - MYSQL RDS"
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
for tool in aws jq mysql; do
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
DB_PORT="${DB_PORT:-$(echo "${SECRET_JSON}" | jq -r '.port // "3306"')}"

# ---------- Validar variables criticas -----------------------
for var in DB_USER DB_PASS DB_HOST; do
  if [[ -z "${!var}" ]]; then
    echo "ERROR: ${var} esta vacio" >&2
    exit 1
  fi
done

# ---------- Validar SSL_MODE ---------------------------------
case "${SSL_MODE}" in
  DISABLED|PREFERRED|REQUIRED|VERIFY_CA|VERIFY_IDENTITY)
    ;;
  *)
    echo "ERROR: SSL_MODE invalido: '${SSL_MODE}'" >&2
    echo "Valores validos: DISABLED | PREFERRED | REQUIRED | VERIFY_CA | VERIFY_IDENTITY" >&2
    exit 1
    ;;
esac

if [[ "${SSL_MODE}" == "VERIFY_CA" || "${SSL_MODE}" == "VERIFY_IDENTITY" ]]; then
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
fi

# ---------- Crear archivo .my.cnf temporal -------------------
MYSQL_CNF=$(mktemp /tmp/mysql_conn_XXXXXX.cnf)
chmod 600 "${MYSQL_CNF}"
{
  echo "[client]"
  echo "host=${DB_HOST}"
  echo "port=${DB_PORT}"
  echo "user=${DB_USER}"
  echo "password=${DB_PASS}"
  echo "ssl-mode=${SSL_MODE}"
  if [[ "${SSL_MODE}" == "VERIFY_CA" || "${SSL_MODE}" == "VERIFY_IDENTITY" ]]; then
    echo "ssl-ca=${SSL_CA_CERT}"
  fi
} > "${MYSQL_CNF}"

cleanup() {
  rm -f "${MYSQL_CNF}"
  unset DB_PASS
}
trap cleanup EXIT

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

  mysql --defaults-extra-file="${MYSQL_CNF}" --table -e "${sql}" 2>&1 | tee -a "${AUDIT_FILE}" || \
    echo "  (error ejecutando query)" | tee -a "${AUDIT_FILE}"
}

# ---------- Verificar conectividad ---------------------------
audit_log "→ Conectando a ${DB_HOST}:${DB_PORT} (ssl-mode=${SSL_MODE})..."

mysql --defaults-extra-file="${MYSQL_CNF}" -e "SELECT 1;" > /dev/null 2>&1 || {
  audit_log "ERROR: No se pudo conectar a MySQL RDS"
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
  @@hostname              AS hostname,
  @@version               AS version,
  @@version_compile_os    AS os,
  CURRENT_USER()          AS usuario_actual,
  @@global.time_zone      AS time_zone;
"

run_sql "ESTADO SSL DE LA SESION" "
SHOW STATUS LIKE 'Ssl_cipher';
"

run_sql "PARAMETROS SSL DEL SERVIDOR" "
SHOW VARIABLES WHERE Variable_name IN (
  'have_ssl', 'require_secure_transport', 'tls_version',
  'ssl_ca', 'ssl_cert'
);
"

run_sql "RESUMEN DE BASES DE DATOS" "
SELECT
  COUNT(*) AS total_bases,
  SUM(CASE WHEN schema_name IN ('mysql','information_schema','performance_schema','sys','tmp','innodb') THEN 0 ELSE 1 END) AS bases_usuario,
  SUM(CASE WHEN schema_name IN ('mysql','information_schema','performance_schema','sys','tmp','innodb') THEN 1 ELSE 0 END) AS bases_sistema
FROM information_schema.schemata;
"

run_sql "BASES DE DATOS DE USUARIO CON TAMAÑO" "
SELECT
  s.schema_name AS database_name,
  s.default_character_set_name AS charset,
  s.default_collation_name AS collation,
  COALESCE(ROUND(SUM(t.data_length + t.index_length) / 1024 / 1024, 2), 0) AS size_mb
FROM information_schema.schemata s
LEFT JOIN information_schema.tables t ON t.table_schema = s.schema_name
WHERE s.schema_name NOT IN ('mysql','information_schema','performance_schema','sys','tmp','innodb')
GROUP BY s.schema_name, s.default_character_set_name, s.default_collation_name
ORDER BY size_mb DESC;
"

run_sql "USUARIOS DEL SERVIDOR" "
SELECT
  User AS usuario,
  Host AS host,
  account_locked AS bloqueado,
  password_expired AS pass_expirado
FROM mysql.user
ORDER BY User, Host;
"

run_sql "PRIVILEGIOS DEL USUARIO ACTUAL" "
SHOW GRANTS FOR CURRENT_USER();
"

run_sql "ROLES (MySQL 8+)" "
SELECT * FROM information_schema.applicable_roles
WHERE GRANTEE = CURRENT_USER();
"

run_sql "PRIVILEGIOS RELEVANTES PARA DUMP" "
SELECT
  PRIVILEGE_TYPE,
  IS_GRANTABLE
FROM information_schema.user_privileges
WHERE GRANTEE = CONCAT(\"'\", REPLACE(CURRENT_USER(), '@', \"'@'\"), \"'\")
  AND PRIVILEGE_TYPE IN (
    'SELECT','LOCK TABLES','SHOW VIEW','EVENT','TRIGGER',
    'RELOAD','PROCESS','REPLICATION CLIENT','REPLICATION SLAVE'
  )
ORDER BY PRIVILEGE_TYPE;
"

run_sql "TOP 10 TABLAS POR TAMAÑO (todas las bases)" "
SELECT
  table_schema AS db,
  table_name AS tabla,
  table_rows AS filas,
  ROUND(data_length / 1024 / 1024, 2) AS data_mb,
  ROUND(index_length / 1024 / 1024, 2) AS index_mb
FROM information_schema.tables
WHERE table_schema NOT IN ('mysql','information_schema','performance_schema','sys','tmp','innodb')
ORDER BY (data_length + index_length) DESC
LIMIT 10;
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
