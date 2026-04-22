# Diagrama de Secuencia — Proceso de Dumps con EC2

```mermaid
sequenceDiagram
    autonumber
    participant Cron as Crontab (EC2)
    participant Script as Script Bash<br/>(dump_*.sh)
    participant EFS as EFS<br/>(/backups)
    participant RDS as RDS<br/>(Oracle/PG/MySQL)
    participant S3 as S3 Bucket<br/>(short-term / long-term)
    participant CW as CloudWatch Logs

    Note over Cron: Mensual: día 5, 02:00 UTC<br/>Anual: día 10 enero, 02:00 UTC

    Cron->>Script: Ejecuta script según schedule
    activate Script

    Script->>EFS: Crea directorios de trabajo<br/>mkdir -p /backups/{engine}/{period}/logs

    Script->>RDS: Verifica conectividad<br/>(SELECT 1 / SELECT 'OK' FROM DUAL)
    alt Conexión fallida
        RDS-->>Script: Error de conexión
        Script->>EFS: Escribe error en log
        Script->>CW: Log de error
        Note over Script: EXIT 1
    else Conexión exitosa
        RDS-->>Script: OK
    end

    Script->>RDS: Ejecuta dump<br/>(pg_dump / mysqldump / exp)
    activate RDS
    RDS-->>Script: Stream de datos del dump
    deactivate RDS

    Script->>EFS: Escribe dump raw en /backups/{engine}/{period}/<br/>{db}_{period}_{timestamp}.dmp|sql

    Script->>Script: Comprime con gzip -9<br/>{db}_{period}_{timestamp}.dmp.gz|sql.gz

    Script->>EFS: Dump comprimido en disco temporal

    Script->>S3: aws s3 cp → sube dump comprimido<br/>s3://{bucket}/{engine}/{db}/{period}/{archivo}.gz
    activate S3
    S3-->>Script: Upload confirmado
    deactivate S3

    Script->>S3: aws s3 ls → verifica tamaño subido
    S3-->>Script: Tamaño en bytes

    Script->>EFS: Elimina archivo temporal (cleanup trap)

    Script->>EFS: Escribe log final de éxito
    Script->>CW: Log de ejecución completa

    deactivate Script

    Note over S3: Lifecycle Policy:<br/>→ Glacier a los 30 días<br/>→ Expiración: 1 año (short) / 8 años (long)
```

## Descripción paso a paso

| Paso | Componente   | Acción                                                                     |
| ---- | ------------ | -------------------------------------------------------------------------- |
| 1    | Encender EC2 | Encender instancia el día  del Backup                                      |
| 2    | Crontab      | Dispara el script según el schedule configurado (mensual o anual)          |
| 3    | Script       | Crea/verifica directorios de trabajo en EFS (`/backups/{engine}/{period}`) |
| 4    | Script → RDS | Prueba de conectividad (`SELECT 1` o `SELECT 'OK' FROM DUAL`)              |
| 5    | Script → RDS | Ejecuta el dump: `pg_dump`, `mysqldump` o `exp` (Oracle)                   |
| 6    | Script → EFS | Escribe el dump raw en el filesystem temporal (EFS)                        |
| 7    | Script       | Comprime el dump con `gzip -9`                                             |
| 8    | Script → S3  | Sube el archivo comprimido con `aws s3 cp` al bucket correspondiente       |
| 9    | Script → S3  | Verifica el tamaño del archivo subido con `aws s3 ls`                      |
| 10   | Script → EFS | Elimina el archivo temporal (trap cleanup en EXIT)                         |
| 11   | S3           | Lifecycle policy mueve a Glacier a los 30 días y expira según retención    |
| 12   | Apagar EC2   | Apagar EC2                                                                 |
