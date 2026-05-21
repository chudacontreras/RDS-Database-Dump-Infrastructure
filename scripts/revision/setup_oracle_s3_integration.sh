#!/bin/bash
###############################################################################
# setup_oracle_s3_integration.sh
#
# Configura la integración S3 para Oracle RDS (necesaria para Data Pump exports).
# Este script crea el IAM Role, la política y asocia la opción S3_INTEGRATION
# al Option Group de la instancia RDS.
#
# NO requiere reinicio de la instancia RDS.
#
# Uso:
#   ./setup_oracle_s3_integration.sh
#
# Prerequisitos:
#   - AWS CLI configurado con permisos de IAM y RDS
#   - jq instalado
###############################################################################
set -euo pipefail

# ======================== CONFIGURACION ========================
# Modificar estos valores antes de ejecutar

AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-000000000000}"
AWS_REGION="${AWS_REGION:-us-east-1}"
RDS_INSTANCE_ID="${RDS_INSTANCE_ID:-CHANGE_ME}"           # DB instance identifier
OPTION_GROUP_NAME="${OPTION_GROUP_NAME:-CHANGE_ME}"       # Option group custom existente
S3_BUCKET_SHORT_TERM="${S3_BUCKET_SHORT_TERM:-CHANGE_ME-dumps-short-term}"
S3_BUCKET_LONG_TERM="${S3_BUCKET_LONG_TERM:-CHANGE_ME-dumps-long-term}"

# Nombres de los recursos IAM a crear
ROLE_NAME="${ROLE_NAME:-rds-oracle-s3-integration-role}"
POLICY_NAME="${POLICY_NAME:-rds-oracle-s3-integration-policy}"
# ===============================================================

echo "=============================================="
echo " Setup: Oracle RDS ↔ S3 Integration"
echo "=============================================="
echo "Account:        ${AWS_ACCOUNT_ID}"
echo "Region:         ${AWS_REGION}"
echo "RDS Instance:   ${RDS_INSTANCE_ID}"
echo "Option Group:   ${OPTION_GROUP_NAME}"
echo "S3 Buckets:     ${S3_BUCKET_SHORT_TERM}, ${S3_BUCKET_LONG_TERM}"
echo "IAM Role:       ${ROLE_NAME}"
echo "=============================================="
echo ""

# ---------- Paso 1: Crear la política IAM ----------
echo "[1/5] Creando política IAM: ${POLICY_NAME}..."

POLICY_DOCUMENT=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowS3ReadWrite",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:ListBucket",
        "s3:PutObject",
        "s3:DeleteObject"
      ],
      "Resource": [
        "arn:aws:s3:::${S3_BUCKET_SHORT_TERM}",
        "arn:aws:s3:::${S3_BUCKET_SHORT_TERM}/*",
        "arn:aws:s3:::${S3_BUCKET_LONG_TERM}",
        "arn:aws:s3:::${S3_BUCKET_LONG_TERM}/*"
      ]
    }
  ]
}
EOF
)

POLICY_ARN=$(aws iam create-policy \
  --policy-name "${POLICY_NAME}" \
  --policy-document "${POLICY_DOCUMENT}" \
  --query 'Policy.Arn' \
  --output text 2>/dev/null) || {
  # Si ya existe, obtener el ARN
  POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}"
  echo "  → Política ya existe: ${POLICY_ARN}"
}
echo "  → Política: ${POLICY_ARN}"

# ---------- Paso 2: Crear el IAM Role ----------
echo "[2/5] Creando IAM Role: ${ROLE_NAME}..."

TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "rds.amazonaws.com"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "aws:SourceAccount": "${AWS_ACCOUNT_ID}"
        }
      }
    }
  ]
}
EOF
)

aws iam create-role \
  --role-name "${ROLE_NAME}" \
  --assume-role-policy-document "${TRUST_POLICY}" \
  --description "Permite a Oracle RDS acceder a S3 para Data Pump exports" \
  > /dev/null 2>&1 || {
  echo "  → Role ya existe"
}

ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}"
echo "  → Role: ${ROLE_ARN}"

# ---------- Paso 3: Asociar política al role ----------
echo "[3/5] Asociando política al role..."

aws iam attach-role-policy \
  --role-name "${ROLE_NAME}" \
  --policy-arn "${POLICY_ARN}" 2>/dev/null || true
echo "  → Política asociada"

# ---------- Paso 4: Agregar opción S3_INTEGRATION al Option Group ----------
echo "[4/5] Agregando S3_INTEGRATION al option group: ${OPTION_GROUP_NAME}..."

aws rds add-option-to-option-group \
  --option-group-name "${OPTION_GROUP_NAME}" \
  --options "OptionName=S3_INTEGRATION,OptionVersion=1.0" \
  --region "${AWS_REGION}" > /dev/null 2>&1 || {
  echo "  → Opción ya existe en el option group"
}
echo "  → S3_INTEGRATION agregada"

# ---------- Paso 5: Asociar el role a la instancia RDS ----------
echo "[5/5] Asociando role a la instancia RDS: ${RDS_INSTANCE_ID}..."

aws rds add-role-to-db-instance \
  --db-instance-identifier "${RDS_INSTANCE_ID}" \
  --feature-name "S3_INTEGRATION" \
  --role-arn "${ROLE_ARN}" \
  --region "${AWS_REGION}" 2>/dev/null || {
  echo "  → Role ya está asociado a la instancia"
}
echo "  → Role asociado"

# ---------- Verificación ----------
echo ""
echo "=============================================="
echo " Verificando configuración..."
echo "=============================================="

echo ""
echo "Roles asociados a la instancia:"
aws rds describe-db-instances \
  --db-instance-identifier "${RDS_INSTANCE_ID}" \
  --region "${AWS_REGION}" \
  --query 'DBInstances[0].AssociatedRoles' \
  --output table 2>/dev/null || echo "  (no se pudo verificar)"

echo ""
echo "=============================================="
echo " Setup completado exitosamente"
echo "=============================================="
echo ""
echo "NOTA: El status del role puede tardar unos segundos en pasar de PENDING a ACTIVE."
echo ""
echo "Para verificar desde SQL*Plus:"
echo "  SELECT * FROM TABLE("
echo "    rdsadmin.rdsadmin_s3_tasks.upload_to_s3("
echo "      p_bucket_name    => '${S3_BUCKET_SHORT_TERM}',"
echo "      p_prefix         => 'test/',"
echo "      p_directory_name => 'DATA_PUMP_DIR'));"
echo ""
echo "Para verificar el status del role:"
echo "  aws rds describe-db-instances \\"
echo "    --db-instance-identifier ${RDS_INSTANCE_ID} \\"
echo "    --query 'DBInstances[0].AssociatedRoles'"
