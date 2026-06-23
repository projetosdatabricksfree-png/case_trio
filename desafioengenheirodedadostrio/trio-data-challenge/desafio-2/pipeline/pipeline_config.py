"""Configuração dos pipelines (sem credenciais hardcoded — tudo via env).

Dois destinos de origem:
  - TimescaleDB (pipeline principal, sync_ts_to_ch): PGHOST=timescaledb.
  - PostgreSQL legado (pipeline de referência, sync_pg_refs): PGHOST=postgres-legado.
O destino é sempre o ClickHouse (trio_analytics). O compose injeta as vars certas
por serviço, então o MESMO módulo serve aos dois pipelines.
"""
from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class PipelineConfig:
    # Origem PostgreSQL/TimescaleDB
    pg_host: str
    pg_port: int
    pg_db: str
    pg_user: str
    pg_password: str
    # Destino ClickHouse
    ch_host: str
    ch_port: int          # porta HTTP (clickhouse-connect)
    ch_db: str
    ch_user: str
    ch_password: str
    # Operação
    poll_s: float         # intervalo do loop contínuo (segundos)
    batch: int            # tamanho do micro-batch da passada de mutação (keyset)
    window_hours: int     # tamanho da janela de tempo da passada de inserção (created_at)
    max_retries: int      # tentativas em erro transitório antes da DLQ
    backoff_base_s: float # base do backoff exponencial (s): base * 2**tentativa

    @property
    def pg_conninfo(self) -> str:
        return (
            f"host={self.pg_host} port={self.pg_port} dbname={self.pg_db} "
            f"user={self.pg_user} password={self.pg_password}"
        )


def load_pipeline_config() -> PipelineConfig:
    return PipelineConfig(
        pg_host=os.getenv("PGHOST", "timescaledb"),
        pg_port=int(os.getenv("PGPORT", "5432")),
        pg_db=os.getenv("PGDATABASE", "trio_transactions"),
        pg_user=os.getenv("POSTGRES_USER", "trio"),
        pg_password=os.getenv("POSTGRES_PASSWORD", "trio2024"),
        ch_host=os.getenv("CH_HOST", "clickhouse"),
        ch_port=int(os.getenv("CH_HTTP_PORT", "8123")),
        ch_db=os.getenv("CH_DATABASE", "trio_analytics"),
        ch_user=os.getenv("CLICKHOUSE_USER", "trio"),
        ch_password=os.getenv("CLICKHOUSE_PASSWORD", "trio2024"),
        poll_s=float(os.getenv("PIPELINE_POLL_S", "10")),
        batch=int(os.getenv("PIPELINE_BATCH", "50000")),
        window_hours=int(os.getenv("PIPELINE_WINDOW_HOURS", "24")),
        max_retries=int(os.getenv("PIPELINE_MAX_RETRIES", "3")),
        backoff_base_s=float(os.getenv("PIPELINE_BACKOFF_BASE_S", "0.5")),
    )
