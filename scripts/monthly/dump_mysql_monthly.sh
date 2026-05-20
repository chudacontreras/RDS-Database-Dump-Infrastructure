#!/bin/bash
###############################################################################
# dump_mysql_monthly.sh - Dump mensual de MySQL RDS → bucket short-term (1 año)
#
# Crontab: 0 2 5 * * /opt/scripts/monthly/dump_mysql_monthly.sh
#
# Uso manual:
#   ./dump_mysql_monthly.sh
#
# ==============================================================================
# CONFIGURACION SSL
# ==============================================================================
# Variable SSL_MODE controla el comportamiento de SSL:
#
#   "DISABLED"   → SIN SSL. Usar solo si la RDS NO tiene SSL forzado.
#                  Equivale a --skip-ssl (en MySQL 8) o --ssl-mode=DISABLED.
#                  Si la RDS exige SSL, este modo FALLARA.
#
#   "PREFERRED"  → Usar SSL si esta disponible, sino conectar sin SSL.
#                  Default de MySQL 8 cuando se omite el flag.
#
#   "REQUIRED"   → SSL obligatorio sin validar certificado del servidor.
#                  Recomendado para la mayoría de casos con RDS.
#                  Funciona out-of-the-box, no requiere descargar el CA.
#
#   "VERIFY_CA"  → SSL + valida que el certificado este firmado por un CA confiable.
#                  Requiere el bundle de CA de AWS RDS (se descarga automaticamente).
#
#   "VERIFY_IDENTITY" → SSL + valida CA + valida que el hostname coincide.
#                       Maxima seguridad. Recomendado para PRODUCCION.
#                       Requiere el bundle de CA de AWS RDS (se descarga automaticamente).
#
# Para SABER si tu RDS requiere SSL:
#   - Console RDS → tu instancia → Parameter Group → buscar "require_secure_transport"
#     - require_secure_transport=1 → SSL OBLIGATORIO
#     - require_secure_transport=0 → SSL OPCIONAL
#   - O conectarse y ejecutar: SHOW VARIABLES LIKE 'require_secure_transport';
###############################################################################
set -euo pipefail

# ======================== CONFIGURACION ========================
S3_BUCKET="${S3_BUCKET:-CHANGE_ME-dumps-short-term}"
AWS_REGION="${AWS_REGION:-us-east-1}"

# ----- SSL: Cambiar a "DISABLED" si la RDS NO usa SSL -----
SSL_MODE="${SSL_MODE:-REQUIRED}"
SSL_CA_CERT="${SSL_CA_CERT:-/etc/ssl/certs/rds-global-bundle.pem}"
# ===============================================================

# ---------- OPCION 1: Secrets Manager (por defecto) ------------
SECRET_NAME="${SECRET_NAME:-mysql/rds/credentials}"

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
DB_PORT=$(echo "${SECRET_JSON}" | jq -r '.port // "3306"')
DB_USER=$(echo "${SECRET_JSON}" | jq -r '.username')
DB_PASS=$(echo "${SECRET_JSON}" | jq -r '.password')
DB_NAME=$(echo "${SECRET_JSON}" | jq -r '.dbname // "ALL"')
# ---------------------------------------------------------------

# ---------- OPCION 2: Credenciales hardcodeadas ----------------
# DB_HOST="CHANGE_ME.rds.amazonaws.com"
# DB_PORT="3306"
# DB_USER="admin"
# DB_PASS='CHANGE_ME'
# DB_NAME="mydb"  # Usar "ALL" para todas las bases
# ---------------------------------------------------------------

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/backups/mysql/monthly"
LOG_FILE="/backups/mysql/logs/dump_mysql_monthly_${TIMESTAMP}.log"

mkdir -p "${BACKUP_DIR}" "/backups/mysql/logs"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOG_FILE}"
}

cleanup() {
  log "Limpiando archivos temporales..."
  if [[ -n "${DUMP_FILE:-}" && -f "${DUMP_FILE}" ]]; then
    rm -f "${DUMP_FILE}"
    log "Archivo temporal ${DUMP_FILE} eliminado"
  fi
  rm -f "${MYSQL_CNF:-/dev/null}" 2>/dev/null
}
trap cleanup EXIT

DUMP_FILE="${BACKUP_DIR}/${DB_NAME}_monthly_${TIMESTAMP}.sql.gz"
S3_KEY="mysql/${DB_NAME}/monthly/${DB_NAME}_monthly_${TIMESTAMP}.sql.gz"

# ============================================================
# Configuracion SSL
# ============================================================
# Validar SSL_MODE
case "${SSL_MODE}" in
  DISABLED|PREFERRED|REQUIRED|VERIFY_CA|VERIFY_IDENTITY)
    ;;
  *)
    echo "ERROR: SSL_MODE invalido: ${SSL_MODE}" >&2
    echo "Valores validos: DISABLED | PREFERRED | REQUIRED | VERIFY_CA | VERIFY_IDENTITY" >&2
    exit 1
    ;;
esac

# Si VERIFY_CA o VERIFY_IDENTITY, descargar CA bundle de RDS si no existe
if [[ "${SSL_MODE}" == "VERIFY_CA" || "${SSL_MODE}" == "VERIFY_IDENTITY" ]]; then
  if [[ ! -f "${SSL_CA_CERT}" ]]; then
    echo "Descargando certificado CA de AWS RDS..."
    sudo mkdir -p "$(dirname "${SSL_CA_CERT}")"
    sudo curl -fsSL -o "${SSL_CA_CERT}" \
      https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem || {
      echo "ERROR: No se pudo descargar el certificado CA de RDS" >&2
      exit 1
    }
    sudo chmod 644 "${SSL_CA_CERT}"
  fi
fi

# Crear archivo .my.cnf temporal para evitar warning de password en CLI
# y centralizar configuracion SSL
MYSQL_CNF=$(mktemp /tmp/mysql_XXXXXX.cnf)
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

log "=========================================="
log "Dump MENSUAL MySQL RDS → bucket short-term"
log "Host: ${DB_HOST}:${DB_PORT} | Database: ${DB_NAME}"
log "SSL Mode: ${SSL_MODE}"
log "=========================================="

log "Verificando conectividad..."
mysql --defaults-extra-file="${MYSQL_CNF}" \
  -e "SELECT 1;" > /dev/null 2>&1 || {
  log "ERROR: No se pudo conectar a MySQL RDS"
  log "Verifique la variable SSL_MODE (actual: ${SSL_MODE})"
  exit 1
}

log "Ejecutando mysqldump..."
if [[ "${DB_NAME}" == "ALL" ]]; then
  mysqldump --defaults-extra-file="${MYSQL_CNF}" \
    --all-databases --single-transaction --routines --triggers --events \
    --set-gtid-purged=OFF --column-statistics=0 --no-tablespaces \
    2>>"${LOG_FILE}" | gzip -9 > "${DUMP_FILE}" || {
    log "ERROR: Fallo el mysqldump"; exit 1
  }
else
  mysqldump --defaults-extra-file="${MYSQL_CNF}" \
    --databases "${DB_NAME}" --single-transaction --routines --triggers --events \
    --set-gtid-purged=OFF --column-statistics=0 --no-tablespaces \
    2>>"${LOG_FILE}" | gzip -9 > "${DUMP_FILE}" || {
    log "ERROR: Fallo el mysqldump"; exit 1
  }
fi

DUMP_SIZE=$(du -sh "${DUMP_FILE}" | cut -f1)
log "Dump generado: ${DUMP_FILE} (${DUMP_SIZE})"

log "Subiendo a s3://${S3_BUCKET}/${S3_KEY}..."
aws s3 cp "${DUMP_FILE}" "s3://${S3_BUCKET}/${S3_KEY}" --storage-class STANDARD --only-show-errors || {
  log "ERROR: Fallo la subida a S3"; exit 1
}

S3_SIZE=$(aws s3 ls "s3://${S3_BUCKET}/${S3_KEY}" | awk '{print $3}')
log "Subido exitosamente (${S3_SIZE} bytes)"
log "Dump mensual MySQL completado: s3://${S3_BUCKET}/${S3_KEY}"
