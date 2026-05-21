#!/bin/bash
###############################################################################
# dump_postgresql_monthly.sh - Dump mensual de PostgreSQL RDS → bucket short-term (1 año)
#
# Crontab: 0 2 5 * * /opt/scripts/monthly/dump_postgresql_monthly.sh
#
# Uso manual:
#   ./dump_postgresql_monthly.sh
#
# ==============================================================================
# MODO DE EXPORT
# ==============================================================================
# Variable DB_NAME determina que se respalda:
#
#   DB_NAME="mydb"     → Respalda UNA base de datos especifica.
#                         Genera: <mydb>_monthly_<timestamp>.sql.gz
#
#   DB_NAME="ALL"      → Respalda TODAS las bases de datos del usuario.
#                         (excluye plantillas: postgres, template0, template1, rdsadmin)
#                         Genera: <basename>_monthly_<timestamp>.sql.gz por cada base.
#                         Recomendado para garantizar backup completo de la RDS.
#
# La variable SCHEMAS solo aplica cuando DB_NAME es una base especifica:
#   SCHEMAS=""              → Toda la base
#   SCHEMAS="public,app"    → Solo schemas indicados
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
#
#   "verify-ca"   → CON SSL + valida que el certificado este firmado por un CA confiable.
#                   Requiere el bundle de CA de AWS RDS (se descarga automaticamente).
#
#   "verify-full" → CON SSL + valida CA + valida hostname.
#                   Maxima seguridad. Recomendado para PRODUCCION.
###############################################################################
set -euo pipefail

# ======================== CONFIGURACION ========================
SCHEMAS="${SCHEMAS:-}"  # Vacio=todo, "public,app"=especificos. Override con env var.
S3_BUCKET="${S3_BUCKET:-CHANGE_ME-dumps-short-term}"
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
DB_HOST="${DB_HOST:-$(echo "${SECRET_JSON}" | jq -r '.host // empty')}"
DB_PORT="${DB_PORT:-$(echo "${SECRET_JSON}" | jq -r '.port // "5432"')}"
DB_USER="${DB_USER:-$(echo "${SECRET_JSON}" | jq -r '.username // empty')}"
DB_PASS="${DB_PASS:-$(echo "${SECRET_JSON}" | jq -r '.password // empty')}"
# IMPORTANTE: Los secrets gestionados por AWS RDS NO incluyen 'dbname'.
# Use DB_NAME=ALL para respaldar TODAS las bases de la instancia.
DB_NAME="${DB_NAME:-$(echo "${SECRET_JSON}" | jq -r '.dbname // "ALL"')}"
# ---------------------------------------------------------------

# ---------- OPCION 2: Credenciales hardcodeadas ----------------
# DB_HOST="CHANGE_ME.rds.amazonaws.com"
# DB_PORT="5432"
# DB_USER="admin"
# DB_PASS='CHANGE_ME'
# DB_NAME="ALL"  # "ALL" para todas las bases, o nombre especifico
# ---------------------------------------------------------------

# Validar variables criticas
if [[ -z "${DB_HOST}" || -z "${DB_USER}" || -z "${DB_PASS}" || -z "${DB_NAME}" ]]; then
  echo "ERROR: Faltan credenciales requeridas." >&2
  [[ -z "${DB_HOST}" ]] && echo "  - DB_HOST esta vacio" >&2
  [[ -z "${DB_USER}" ]] && echo "  - DB_USER esta vacio" >&2
  [[ -z "${DB_PASS}" ]] && echo "  - DB_PASS esta vacio" >&2
  [[ -z "${DB_NAME}" ]] && echo "  - DB_NAME esta vacio. Use DB_NAME=ALL para todas." >&2
  exit 1
fi

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/backups/postgresql/monthly"
LOG_FILE="/backups/postgresql/logs/dump_postgresql_monthly_${TIMESTAMP}.log"

mkdir -p "${BACKUP_DIR}" "/backups/postgresql/logs"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${LOG_FILE}"
}

# Array para trackear archivos a limpiar
declare -a TEMP_FILES=()

cleanup() {
  log "Limpiando archivos temporales..."
  for f in "${TEMP_FILES[@]:-}"; do
    [[ -n "${f}" && -f "${f}" ]] && rm -f "${f}"
  done
  unset PGPASSWORD
}
trap cleanup EXIT

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

# ==============================================================================
# Funcion: dump_database
# Hace el pg_dump de UNA base de datos y la sube a S3
# ==============================================================================
dump_database() {
  local db="$1"
  local dump_file="${BACKUP_DIR}/${db}_monthly_${TIMESTAMP}.sql.gz"
  local s3_key="postgresql/${db}/monthly/${db}_monthly_${TIMESTAMP}.sql.gz"

  TEMP_FILES+=("${dump_file}")

  log "  → Dumping database: ${db}"

  local schema_opts=""
  if [[ -n "${SCHEMAS}" && "${DB_NAME}" != "ALL" ]]; then
    IFS=',' read -ra SCHEMA_ARRAY <<< "${SCHEMAS}"
    for schema in "${SCHEMA_ARRAY[@]}"; do
      schema_opts="${schema_opts} -n ${schema}"
    done
  fi

  pg_dump \
    -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${db}" \
    --no-owner --no-privileges --format=plain \
    ${schema_opts} \
    2>>"${LOG_FILE}" | gzip -9 > "${dump_file}" || {
    log "  ✗ ERROR: Fallo el pg_dump de ${db}"
    return 1
  }

  local dump_size
  dump_size=$(du -sh "${dump_file}" | cut -f1)
  log "  ✓ Dump generado: ${dump_file} (${dump_size})"

  log "  → Subiendo a s3://${S3_BUCKET}/${s3_key}..."
  aws s3 cp "${dump_file}" "s3://${S3_BUCKET}/${s3_key}" \
    --storage-class STANDARD --only-show-errors || {
    log "  ✗ ERROR: Fallo la subida a S3 de ${db}"
    return 1
  }

  log "  ✓ Subido exitosamente: s3://${S3_BUCKET}/${s3_key}"
  rm -f "${dump_file}"
  return 0
}

# ==============================================================================
# INICIO
# ==============================================================================
log "=========================================="
log "Dump MENSUAL PostgreSQL RDS → bucket short-term"
log "Host: ${DB_HOST}:${DB_PORT}"
log "Modo: ${DB_NAME}"
log "SSL Mode: ${SSL_MODE}"
log "=========================================="

log "Verificando conectividad..."
# Para validar conectividad nos conectamos a 'postgres' que siempre existe
psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d postgres \
  -c "SELECT 1;" > /dev/null 2>&1 || {
  log "ERROR: No se pudo conectar a PostgreSQL RDS"
  log "Verifique credenciales y SSL_MODE (actual: ${SSL_MODE})"
  exit 1
}
log "Conectividad OK"

# ============================================================
# Determinar lista de bases a respaldar
# ============================================================
if [[ "${DB_NAME}" == "ALL" ]]; then
  log "Modo ALL: descubriendo todas las bases de datos de usuario..."

  # Listar bases excluyendo:
  #  - template0, template1: plantillas internas
  #  - rdsadmin: base administrativa de RDS (no accesible al usuario)
  #  - bases con datistemplate=true (plantillas)
  #  - bases con datallowconn=false (deshabilitadas para conexion)
  DATABASES=$(psql -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d postgres -tAc \
    "SELECT datname FROM pg_database
     WHERE datistemplate = false
       AND datallowconn = true
       AND datname NOT IN ('rdsadmin')
     ORDER BY datname;" 2>>"${LOG_FILE}") || {
    log "ERROR: No se pudo listar las bases de datos"
    exit 1
  }

  if [[ -z "${DATABASES}" ]]; then
    log "ERROR: No se encontraron bases de datos para respaldar"
    exit 1
  fi

  DB_COUNT=$(echo "${DATABASES}" | wc -l | xargs)
  log "Bases encontradas (${DB_COUNT}):"
  echo "${DATABASES}" | while read -r db; do log "  - ${db}"; done
else
  DATABASES="${DB_NAME}"
  log "Modo individual: respaldando solo '${DB_NAME}'"
fi

# ============================================================
# Ejecutar dumps
# ============================================================
TOTAL=0
SUCCESS=0
FAILED=0
FAILED_DBS=""

while IFS= read -r db; do
  [[ -z "${db}" ]] && continue
  TOTAL=$((TOTAL + 1))

  if dump_database "${db}"; then
    SUCCESS=$((SUCCESS + 1))
  else
    FAILED=$((FAILED + 1))
    FAILED_DBS="${FAILED_DBS} ${db}"
  fi
done <<< "${DATABASES}"

# ============================================================
# Resumen
# ============================================================
log "=========================================="
log "RESUMEN"
log "  Total bases procesadas: ${TOTAL}"
log "  Exitosas: ${SUCCESS}"
log "  Fallidas: ${FAILED}"
if [[ ${FAILED} -gt 0 ]]; then
  log "  Bases fallidas:${FAILED_DBS}"
fi
log "=========================================="

if [[ ${FAILED} -gt 0 ]]; then
  exit 1
fi

log "Dump mensual PostgreSQL completado exitosamente"
