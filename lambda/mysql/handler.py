"""
Lambda handler para dump de MySQL RDS → S3.

Usa mysqldump empaquetado en un Lambda Layer.
Soporta dump mensual (short-term) y anual (long-term).

Variables de entorno requeridas:
  - DB_HOST, DB_PORT, DB_USER, DB_NAME
  - DB_SECRET_ARN (Secrets Manager ARN con la password)
  - S3_BUCKET_SHORT_TERM, S3_BUCKET_LONG_TERM

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
    db_port = os.environ.get("DB_PORT", "3306")
    db_user = os.environ["DB_USER"]
    db_name = os.environ["DB_NAME"]
    db_pass = get_db_password()

    if dump_type == "yearly":
        s3_bucket = os.environ["S3_BUCKET_LONG_TERM"]
    else:
        s3_bucket = os.environ["S3_BUCKET_SHORT_TERM"]

    s3_key = f"mysql/{db_name}/{dump_type}/{db_name}_{dump_type}_{timestamp}.sql.gz"
    dump_file = f"/tmp/{db_name}_{dump_type}_{timestamp}.sql.gz"

    logger.info(f"Dump {dump_type} MySQL: {db_host}:{db_port}/{db_name} → s3://{s3_bucket}/{s3_key}")

    # Construir comando mysqldump
    cmd = [
        "/opt/bin/mysqldump",
        "-h", db_host,
        "-P", db_port,
        "-u", db_user,
        f"-p{db_pass}",
        "--single-transaction",
        "--routines",
        "--triggers",
        "--events",
        "--set-gtid-purged=OFF",
        "--column-statistics=0",
        "--no-tablespaces",
    ]

    if db_name == "ALL":
        cmd.append("--all-databases")
    else:
        cmd.extend(["--databases", db_name])

    env = os.environ.copy()
    env["LD_LIBRARY_PATH"] = "/opt/lib:" + env.get("LD_LIBRARY_PATH", "")

    try:
        logger.info("Ejecutando mysqldump...")
        dump_proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        gz_proc = subprocess.Popen(
            ["gzip", "-9"],
            stdin=dump_proc.stdout,
            stdout=open(dump_file, "wb"),
            stderr=subprocess.PIPE,
        )
        dump_proc.stdout.close()
        gz_out, gz_err = gz_proc.communicate(timeout=840)
        dump_stderr = dump_proc.stderr.read().decode()

        if dump_proc.wait() != 0:
            logger.error(f"mysqldump falló: {dump_stderr}")
            return {"statusCode": 500, "body": f"mysqldump error: {dump_stderr}"}

        dump_size = os.path.getsize(dump_file)
        logger.info(f"Dump generado: {dump_size} bytes")

        logger.info("Subiendo a S3...")
        s3_client.upload_file(dump_file, s3_bucket, s3_key)
        logger.info(f"Subido: s3://{s3_bucket}/{s3_key}")

        return {
            "statusCode": 200,
            "body": json.dumps({
                "message": f"Dump {dump_type} MySQL completado",
                "s3_path": f"s3://{s3_bucket}/{s3_key}",
                "size_bytes": dump_size,
            }),
        }

    except subprocess.TimeoutExpired:
        logger.error("Timeout: el dump excedió 14 minutos")
        return {"statusCode": 504, "body": "Timeout en mysqldump"}

    except Exception as e:
        logger.error(f"Error: {str(e)}")
        return {"statusCode": 500, "body": str(e)}

    finally:
        if os.path.exists(dump_file):
            os.remove(dump_file)
