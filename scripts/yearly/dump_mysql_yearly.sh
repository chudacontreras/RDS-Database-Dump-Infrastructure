#!/bin/bash
###############################################################################
# dump_mysql_yearly.sh - Dump anual de MySQL RDS → bucket long-term (8 años)
#
# Crontab: 0 2 10 1 * /opt/scripts/yearly/dump_mysql_yearly.sh
#
# Uso manual:
#   ./dump_mysql_yearly.sh
#
# ==============================================================================
# MODO DE EXPORT
# ==============================================================================
# Variable DB_NAME determina que se respalda:
#
#   DB_NAME="mydb"  → Respalda UNA base de datos especifica.
#
#   DB_NAME="ALL"   → Respalda TODAS las bases con --all-databases.
#                     Recomendado para garantizar backup completo de la RDS.
#                     Genera UN solo archivo con TODAS las bases.
#
# Si el secret de AWS RDS no incluye 'dbname', el default es ALL.
#
# ==============================================================================
# CONFIGURACION SSL
# ==============================================================================
# Variable SSL_MODE: DISABLED | PREFERRED | REQUIRED | VERIFY_CA | VERIFY_IDENTITY
# Default: REQUIRED
###############################################################################
set -euo pipefail

# ======================== CONFIGURACION ========================
S3_BUCKET="${S3_BUCKET:-CHANGE_ME-dumps-long-term}"
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
DB_HOST="${DB_HOST:-$(echo "${SECRET_JSON}" | jq -r '.host // empty')}"
DB_PORT="${DB_PORT:-$(echo "${SECRET_JSON}" | jq -r '.port // "3306"')}"
DB_USER="${DB_USER:-$(echo "${SECRET_JSON}" | jq -r '.username // empty')}"
DB_PASS="${DB_PASS:-$(echo "${SECRET_JSON}" | jq -r '.password // empty')}"
# Los secrets de AWS RDS NO incluyen 'dbname' por defecto.
# Defina DB_NAME aqui, exportala como env var, o use "ALL" para todas las bases:
#   DB_NAME=mydb ./dump_mysql_yearly.sh
#   DB_NAME=ALL ./dump_mysql_yearly.sh
DB_NAME="${DB_NAME:-$(echo "${SECRET_JSON}" | jq -r '.dbname // "ALL"')}"
# ---------------------------------------------------------------

# ---------- OPCION 2: Credenciales hardcodeadas ----------------
# DB_HOST="CHANGE_ME.rds.amazonaws.com"
# DB_PORT="3306"
# DB_USER="admin"
# DB_PASS='CHANGE_ME'
# DB_NAME="mydb"
# ---------------------------------------------------------------

# Validar que las variables criticas tengan valor
if [[ -z "${DB_HOST}" || -z "${DB_USER}" || -z "${DB_PASS}" || -z "${DB_NAME}" || "${DB_NAME}" == "null" ]]; then
  echo "ERROR: Faltan credenciales requeridas. Verifique:" >&2
  [[ -z "${DB_HOST}" ]] && echo "  - DB_HOST esta vacio" >&2
  [[ -z "${DB_USER}" ]] && echo "  - DB_USER esta vacio" >&2
  [[ -z "${DB_PASS}" ]] && echo "  - DB_PASS esta vacio" >&2
  if [[ -z "${DB_NAME}" || "${DB_NAME}" == "null" ]]; then
    echo "  - DB_NAME esta vacio. Defina DB_NAME como variable de entorno o use ALL para todas:" >&2
    echo "    DB_NAME=mydb ./script.sh    o    DB_NAME=ALL ./script.sh" >&2
  fi
  exit 1
fi

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/backups/mysql/yearly"
LOG_FILE="/backups/mysql/logs/dump_mysql_yearly_${TIMESTAMP}.log"

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

DUMP_FILE="${BACKUP_DIR}/${DB_NAME}_yearly_${TIMESTAMP}.sql.gz"
S3_KEY="mysql/${DB_NAME}/yearly/${DB_NAME}_yearly_${TIMESTAMP}.sql.gz"

# ============================================================
# Configuracion SSL
# ============================================================
case "${SSL_MODE}" in
  DISABLED|PREFERRED|REQUIRED|VERIFY_CA|VERIFY_IDENTITY)
    ;;
  *)
    echo "ERROR: SSL_MODE invalido: ${SSL_MODE}" >&2
    echo "Valores validos: DISABLED | PREFERRED | REQUIRED | VERIFY_CA | VERIFY_IDENTITY" >&2
    exit 1
    ;;
esac

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
log "Dump ANUAL MySQL RDS → bucket long-term (8 años)"
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
log "Dump anual MySQL completado: s3://${S3_BUCKET}/${S3_KEY}"
