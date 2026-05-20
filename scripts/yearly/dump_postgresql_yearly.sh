#!/bin/bash
###############################################################################
# dump_postgresql_yearly.sh - Dump anual de PostgreSQL RDS → bucket long-term (8 años)
#
# Crontab: 0 2 10 1 * /opt/scripts/yearly/dump_postgresql_yearly.sh
#
# Uso manual:
#   ./dump_postgresql_yearly.sh
#
# ==============================================================================
# CONFIGURACION SSL
# ==============================================================================
# Variable SSL_MODE controla el comportamiento de SSL:
#
#   "disable"     → SIN SSL. Usar solo si la RDS NO tiene SSL forzado.
#                   Si la RDS tiene rds.force_ssl=1, este modo FALLARA.
#
#   "require"     → CON SSL pero sin validar certificado del servidor.
#                   Recomendado para la mayoría de casos con RDS.
#                   Funciona out-of-the-box, no requiere descargar el CA.
#
#   "verify-ca"   → CON SSL + valida que el certificado este firmado por un CA confiable.
#                   Requiere el bundle de CA de AWS RDS (se descarga automaticamente).
#
#   "verify-full" → CON SSL + valida CA + valida que el hostname coincide con el certificado.
#                   Maxima seguridad. Recomendado para PRODUCCION.
#                   Requiere el bundle de CA de AWS RDS (se descarga automaticamente).
#
# Para SABER si tu RDS requiere SSL:
#   - Console RDS → tu instancia → Parameter Group → buscar "rds.force_ssl"
#     - rds.force_ssl=1 → SSL OBLIGATORIO (usar require, verify-ca o verify-full)
#     - rds.force_ssl=0 → SSL OPCIONAL (puedes usar disable, require, etc.)
#   - O conectarse y ejecutar: SHOW rds.force_ssl;
###############################################################################
set -euo pipefail

# ======================== CONFIGURACION ========================
SCHEMAS=""  # Dejar vacio para full, o "public,app"
S3_BUCKET="${S3_BUCKET:-CHANGE_ME-dumps-long-term}"
AWS_REGION="${AWS_REGION:-us-east-1}"

# ----- SSL: Cambiar a "disable" si la RDS NO usa SSL -----
SSL_MODE="${SSL_MODE:-require}"
SSL_CA_CERT="${SSL_CA_CERT:-/etc/ssl/certs/rds-global-bundle.pem}"
# ===============================================================

# ---------- OPCION 1: Secrets Manager (por defecto) ------------
SECRET_NAME="${SECRET_NAME:-postgresql/rds/credentials}"

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
DB_PORT=$(echo "${SECRET_JSON}" | jq -r '.port // "5432"')
DB_USER=$(echo "${SECRET_JSON}" | jq -r '.username')
DB_PASS=$(echo "${SECRET_JSON}" | jq -r '.password')
DB_NAME=$(echo "${SECRET_JSON}" | jq -r '.dbname')
# ---------------------------------------------------------------

# ---------- OPCION 2: Credenciales hardcodeadas ----------------
# DB_HOST="CHANGE_ME.rds.amazonaws.com"
# DB_PORT="5432"
# DB_USER="admin"
# DB_PASS='CHANGE_ME'
# DB_NAME="mydb"
# ---------------------------------------------------------------

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/backups/postgresql/yearly"
LOG_FILE="/backups/postgresql/logs/dump_postgresql_yearly_${TIMESTAMP}.log"

mkdir -p "${BACKUP_DIR}" "/backups/postgresql/logs"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOG_FILE}"
}

cleanup() {
  log "Limpiando archivos temporales..."
  if [[ -n "${DUMP_FILE:-}" && -f "${DUMP_FILE}" ]]; then
    rm -f "${DUMP_FILE}"
    log "Archivo temporal ${DUMP_FILE} eliminado"
  fi
  unset PGPASSWORD
}
trap cleanup EXIT

DUMP_FILE="${BACKUP_DIR}/${DB_NAME}_yearly_${TIMESTAMP}.sql.gz"
S3_KEY="postgresql/${DB_NAME}/yearly/${DB_NAME}_yearly_${TIMESTAMP}.sql.gz"
export PGPASSWORD="${DB_PASS}"

# ============================================================
# Configuracion SSL
# ============================================================
case "${SSL_MODE}" in
  disable|require|verify-ca|verify-full)
    export PGSSLMODE="${SSL_MODE}"
    ;;
  *)
    echo "ERROR: SSL_MODE invalido: ${SSL_MODE}" >&2
    echo "Valores validos: disable | require | verify-ca | verify-full" >&2
    exit 1
    ;;
esac

if [[ "${SSL_MODE}" == "verify-ca" || "${SSL_MODE}" == "verify-full" ]]; then
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
  export PGSSLROOTCERT="${SSL_CA_CERT}"
fi

log "=========================================="
log "Dump ANUAL PostgreSQL RDS → bucket long-term (8 años)"
log "Host: ${DB_HOST}:${DB_PORT} | Database: ${DB_NAME}"
log "SSL Mode: ${SSL_MODE}"
log "=========================================="

log "Verificando conectividad..."
psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" \
  -c "SELECT 1;" > /dev/null 2>&1 || {
  log "ERROR: No se pudo conectar a PostgreSQL RDS"
  log "Verifique la variable SSL_MODE (actual: ${SSL_MODE})"
  exit 1
}

SCHEMA_OPTS=""
if [[ -n "${SCHEMAS}" ]]; then
  IFS=',' read -ra SCHEMA_ARRAY <<< "${SCHEMAS}"
  for schema in "${SCHEMA_ARRAY[@]}"; do
    SCHEMA_OPTS="${SCHEMA_OPTS} -n ${schema}"
  done
  log "Exportando schemas: ${SCHEMAS}"
else
  log "Exportando base de datos completa"
fi

log "Ejecutando pg_dump..."
pg_dump \
  -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" \
  -v --no-owner --no-privileges --format=plain \
  ${SCHEMA_OPTS} \
  2>>"${LOG_FILE}" | gzip -9 > "${DUMP_FILE}" || {
  log "ERROR: Fallo el pg_dump"; exit 1
}

DUMP_SIZE=$(du -sh "${DUMP_FILE}" | cut -f1)
log "Dump generado: ${DUMP_FILE} (${DUMP_SIZE})"

log "Subiendo a s3://${S3_BUCKET}/${S3_KEY}..."
aws s3 cp "${DUMP_FILE}" "s3://${S3_BUCKET}/${S3_KEY}" --storage-class STANDARD --only-show-errors || {
  log "ERROR: Fallo la subida a S3"; exit 1
}

S3_SIZE=$(aws s3 ls "s3://${S3_BUCKET}/${S3_KEY}" | awk '{print $3}')
log "Subido exitosamente (${S3_SIZE} bytes)"
log "Dump anual PostgreSQL completado: s3://${S3_BUCKET}/${S3_KEY}"
