"""
Lambda handler para dump de Oracle RDS → S3.

Desplegado como container image Lambda (Oracle Instant Client no cabe en Layer).
Soporta dump mensual (short-term) y anual (long-term).

Variables de entorno requeridas:
  - DB_HOST, DB_PORT, DB_USER, DB_SERVICE
  - DB_SECRET_ARN (Secrets Manager ARN con la password)
  - S3_BUCKET_SHORT_TERM, S3_BUCKET_LONG_TERM
  - SCHEMAS (opcional, comma-separated)

El evento de EventBridge debe incluir: { "dump_type": "monthly" | "yearly" }
"""

import subprocess
import os
import json
import logging
import boto3
from datetime import datetime

logger = logging.getLogger()
logger.setLevel(logging.INFO)

secrets_client = boto3.client("secretsmanager")
s3_client = boto3.client("s3")


def get_db_password():
    secret_arn = os.environ["DB_SECRET_ARN"]
    response = secrets_client.get_secret_value(SecretId=secret_arn)
    secret = json.loads(response["SecretString"])
    return secret.get("password", secret.get("DB_PASS"))


def handler(event, context):
    dump_type = event.get("dump_type", "monthly")
    timestamp = datetime.utcnow().strftime("%Y%m%d_%H%M%S")

    db_host = os.environ["DB_HOST"]
    db_port = os.environ.get("DB_PORT", "1521")
    db_user = os.environ["DB_USER"]
    db_service = os.environ["DB_SERVICE"]
    db_pass = get_db_password()
    schemas = os.environ.get("SCHEMAS", "")

    if dump_type == "yearly":
        s3_bucket = os.environ["S3_BUCKET_LONG_TERM"]
    else:
        s3_bucket = os.environ["S3_BUCKET_SHORT_TERM"]

    s3_key = f"oracle/{db_service}/{dump_type}/{db_service}_{dump_type}_{timestamp}.dmp.gz"
    dump_file_raw = f"/tmp/{db_service}_{dump_type}_{timestamp}.dmp"
    dump_file = f"{dump_file_raw}.gz"

    conn_str = (
        f"{db_user}/{db_pass}@(DESCRIPTION="
        f"(ADDRESS=(PROTOCOL=TCP)(HOST={db_host})(PORT={db_port}))"
        f"(CONNECT_DATA=(SERVICE_NAME={db_service})))"
    )

    logger.info(f"Dump {dump_type} Oracle: {db_host}:{db_port}/{db_service} → s3://{s3_bucket}/{s3_key}")

    try:
        # Verificar conectividad
        logger.info("Verificando conectividad Oracle...")
        result = subprocess.run(
            ["sqlplus", "-S", conn_str],
            input="SELECT 'OK' FROM DUAL;\nEXIT;\n",
            capture_output=True, text=True, timeout=30,
        )
        if result.returncode != 0:
            logger.error(f"Conexión fallida: {result.stderr}")
            return {"statusCode": 500, "body": f"Conexión Oracle fallida: {result.stderr}"}

        # Ejecutar exp
        logger.info("Ejecutando exp (Oracle export)...")
        exp_cmd = ["exp", conn_str, f"FILE={dump_file_raw}", "COMPRESS=Y", "CONSISTENT=Y", "STATISTICS=NONE"]

        if schemas:
            exp_cmd.append(f"OWNER={schemas}")
        else:
            exp_cmd.append("FULL=Y")

        result = subprocess.run(exp_cmd, capture_output=True, text=True, timeout=780)  # 13 min
        if result.returncode != 0 and "EXP-00000" not in result.stdout:
            logger.error(f"exp falló: {result.stderr}\n{result.stdout}")
            return {"statusCode": 500, "body": f"Oracle exp error: {result.stderr}"}

        # Comprimir
        logger.info("Comprimiendo dump...")
        subprocess.run(["gzip", "-9", dump_file_raw], check=True, timeout=120)

        dump_size = os.path.getsize(dump_file)
        logger.info(f"Dump comprimido: {dump_size} bytes")

        # Subir a S3
        logger.info("Subiendo a S3...")
        s3_client.upload_file(dump_file, s3_bucket, s3_key)
        logger.info(f"Subido: s3://{s3_bucket}/{s3_key}")

        return {
            "statusCode": 200,
            "body": json.dumps({
                "message": f"Dump {dump_type} Oracle completado",
                "s3_path": f"s3://{s3_bucket}/{s3_key}",
                "size_bytes": dump_size,
            }),
        }

    except subprocess.TimeoutExpired:
        logger.error("Timeout: el dump excedió el límite")
        return {"statusCode": 504, "body": "Timeout en Oracle export"}

    except Exception as e:
        logger.error(f"Error: {str(e)}")
        return {"statusCode": 500, "body": str(e)}

    finally:
        for f in [dump_file_raw, dump_file]:
            if os.path.exists(f):
                os.remove(f)
