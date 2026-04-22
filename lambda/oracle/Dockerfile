# Oracle requiere container image Lambda por el tamaño del Instant Client (~400MB+).
# No cabe en un Lambda Layer estándar (250MB descomprimido).

FROM public.ecr.aws/lambda/python:3.12

# Instalar dependencias del sistema para Oracle Instant Client
RUN dnf install -y libaio gzip && dnf clean all

# Instalar Oracle Instant Client 21c
ARG ORACLE_VERSION=21.15.0.0.0-1
RUN rpm -ivh https://yum.oracle.com/repo/OracleLinux/OL9/oracle/instantclient/x86_64/getPackage/oracle-instantclient-basic-${ORACLE_VERSION}.el9.x86_64.rpm && \
    rpm -ivh https://yum.oracle.com/repo/OracleLinux/OL9/oracle/instantclient/x86_64/getPackage/oracle-instantclient-sqlplus-${ORACLE_VERSION}.el9.x86_64.rpm && \
    rpm -ivh https://yum.oracle.com/repo/OracleLinux/OL9/oracle/instantclient/x86_64/getPackage/oracle-instantclient-tools-${ORACLE_VERSION}.el9.x86_64.rpm

ENV LD_LIBRARY_PATH=/usr/lib/oracle/21/client64/lib:${LD_LIBRARY_PATH}
ENV PATH=/usr/lib/oracle/21/client64/bin:${PATH}

# Copiar handler
COPY handler.py ${LAMBDA_TASK_ROOT}/

# Instalar boto3 (ya incluido en runtime, pero por si acaso)
RUN pip install --no-cache-dir boto3

CMD ["handler.handler"]
