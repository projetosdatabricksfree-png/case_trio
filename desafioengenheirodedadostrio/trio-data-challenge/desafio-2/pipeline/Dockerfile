# =============================================================================
#  Pipelines do Desafio 2 — micro-batch TimescaleDB/PostgreSQL -> ClickHouse.
#  Imagem usada por DOIS serviços (mesmo binário, entrypoints diferentes):
#    - pipeline        (default, loop contínuo):  python sync_ts_to_ch.py
#    - pipeline-refs   (tools, one-shot):         python sync_pg_refs.py --once
#  Containerizado p/ reprodutibilidade: o avaliador não precisa de Python no host.
# =============================================================================
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY . ./

# Default = pipeline principal em loop contínuo (poll). Sobrescrito por serviço/CLI.
CMD ["python", "sync_ts_to_ch.py"]
