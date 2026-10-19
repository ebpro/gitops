# slurm-runner-broker — GitHub queued-run poller + Slurm sbatch dispatcher (Phase 1).
# stdlib-only broker.py; needs openssh-client (ssh/sbatch transport) and curl (ops debugging).
FROM python:3.12-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends openssh-client curl \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd -g 10001 broker \
    && useradd -m -u 10001 -g 10001 -s /bin/sh broker

WORKDIR /app
COPY broker.py job-template.sh /app/
RUN chmod 0755 /app/broker.py /app/job-template.sh

ENV PYTHONUNBUFFERED=1 \
    HOME=/home/broker

USER 10001:10001

ENTRYPOINT ["python3", "/app/broker.py"]
