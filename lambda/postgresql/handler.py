"""
Lambda handler para dump de PostgreSQL RDS → S3.

Usa pg_dump empaquetado en un Lambda Layer.
Soporta dump mensual (short-term) y anual (long-term).

Variables de entorno requeridas:
  - DB_HOST, DB_PORT, DB_USER, DB_NAME
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
    db_port = os.environ.get("DB_PORT", "5432")
    db_user = os.environ["DB_USER"]
    db_name = os.environ["DB_NAME"]
    db_pass = get_db_password()
    schemas = os.environ.get("SCHEMAS", "")

    if dump_type == "yearly":
        s3_bucket = os.environ["S3_BUCKET_LONG_TERM"]
    else:
        s3_bucket = os.environ["S3_BUCKET_SHORT_TERM"]

    s3_key = f"postgresql/{db_name}/{dump_type}/{db_name}_{dump_type}_{timestamp}.sql.gz"
    dump_file = f"/tmp/{db_name}_{dump_type}_{timestamp}.sql.gz"

    logger.info(f"Dump {dump_type} PostgreSQL: {db_host}:{db_port}/{db_name} → s3://{s3_bucket}/{s3_key}")

    # Construir comando pg_dump
    cmd = [
        "/opt/bin/pg_dump",
        "-h", db_host,
        "-p", db_port,
        "-U", db_user,
        "-d", db_name,
        "--no-owner",
        "--no-privileges",
        "--format=plain",
    ]

    if schemas:
        for schema in schemas.split(","):
            cmd.extend(["-n", schema.strip()])

    env = os.environ.copy()
    env["PGPASSWORD"] = db_pass
    env["LD_LIBRARY_PATH"] = "/opt/lib:" + env.get("LD_LIBRARY_PATH", "")

    try:
        # pg_dump | gzip → archivo
        logger.info("Ejecutando pg_dump...")
        pg_proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        gz_proc = subprocess.Popen(
            ["gzip", "-9"],
            stdin=pg_proc.stdout,
            stdout=open(dump_file, "wb"),
            stderr=subprocess.PIPE,
        )
        pg_proc.stdout.close()
        gz_out, gz_err = gz_proc.communicate(timeout=840)  # 14 min timeout
        pg_stderr = pg_proc.stderr.read().decode()

        if pg_proc.wait() != 0:
            logger.error(f"pg_dump falló: {pg_stderr}")
            return {"statusCode": 500, "body": f"pg_dump error: {pg_stderr}"}

        dump_size = os.path.getsize(dump_file)
        logger.info(f"Dump generado: {dump_size} bytes")

        # Subir a S3
        logger.info(f"Subiendo a S3...")
        s3_client.upload_file(dump_file, s3_bucket, s3_key)
        logger.info(f"Subido: s3://{s3_bucket}/{s3_key}")

        return {
            "statusCode": 200,
            "body": json.dumps({
                "message": f"Dump {dump_type} PostgreSQL completado",
                "s3_path": f"s3://{s3_bucket}/{s3_key}",
                "size_bytes": dump_size,
            }),
        }

    except subprocess.TimeoutExpired:
        logger.error("Timeout: el dump excedió 14 minutos")
        return {"statusCode": 504, "body": "Timeout en pg_dump"}

    except Exception as e:
        logger.error(f"Error: {str(e)}")
        return {"statusCode": 500, "body": str(e)}

    finally:
        if os.path.exists(dump_file):
            os.remove(dump_file)
